#!/usr/bin/env python3
"""Read-only JSON facts endpoint for The Lounge, served on :9001 behind
CloudFront's /status/api cache behavior (modules/edge/cloudfront.tf).
The status page itself (shell, panels, history) is the status-page core
(modules/status); its plugin calls this endpoint with the caller's
token and renders the release, service and database facts below. There is no
reverse proxy in this stack, so a second path on the same hostname means a
second origin, not a second route on an existing server -- see the module
docstring in edge/lambda/repoint.py for how the two origins are kept
following the same Spot instance.

Gate: "signed in to The Lounge" is defined exactly the way The Lounge itself
defines it (server/client.ts, server/server.ts upstream) -- a request must
carry `Authorization: Bearer <token>` where sha512(token) matches a key in
the `sessions` object of some <THELOUNGE_HOME>/users/<name>.json. There is no
second credential: this file only ever reads what The Lounge already wrote,
so a user's existing browser session (its token already sits in
localStorage["token"]) is also a valid session here with no extra login.

Route shape:
  GET /status/api     Bearer-gated JSON payload. Everything else 404s.

Installed by thelounge-converge.sh / user_data.sh.tftpl to
/usr/local/bin/thelounge-status (the .py suffix is stripped on install, the
same convention the .sh scripts in this directory use). Run by
thelounge-status.service as User=thelounge -- the same user that owns
users/*.json and logs/*.sqlite3, so this reads them with no privilege
escalation and no elevated capability of its own.

Stdlib only: AL2023 ships python3, but not boto3 for it (only the bundled
awscli v2 binary has its own vendored copy). AWS reads shell out to `aws`,
same as every other script in this directory.
"""

import hashlib
import json
import os
import platform
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 9001

THELOUNGE_HOME = Path("/srv/thelounge/data")
USERS_DIR = THELOUNGE_HOME / "users"
LOGS_DIR = THELOUNGE_HOME / "logs"
PACKAGES_MANIFEST = THELOUNGE_HOME / "packages" / "package.json"
CURRENT_RELEASE = Path("/opt/thelounge/current")
INSTANCE_ENV = Path("/etc/thelounge/instance.env")

AWS_TIMEOUT_S = 8


def log(msg):
    print(f"[status] {msg}", file=sys.stderr, flush=True)


# --- tiny TTL cache ----------------------------------------------------------
#
# Every sqlite scan and every `aws` invocation below is expensive relative to
# a page load on a t4g.nano sharing 512MB with node, and this process may
# serve several near-simultaneous requests for the same page. A miss computes
# outside the lock, so two concurrent misses can race and both fetch -- an
# acceptable, self-correcting duplication given the read-only, idempotent
# nature of everything cached here.


class TTLCache:
    def __init__(self):
        self._lock = threading.Lock()
        self._store = {}

    def get(self, key, ttl, fetch):
        now = time.monotonic()
        with self._lock:
            hit = self._store.get(key)
            if hit is not None and hit[0] > now:
                return hit[1]
        value = fetch()
        with self._lock:
            self._store[key] = (now + ttl, value)
        return value


cache = TTLCache()


# --- small helpers -----------------------------------------------------------


def iso_from_epoch_seconds(sec):
    return datetime.fromtimestamp(sec, tz=timezone.utc).isoformat()


def iso_from_message_time(ts):
    """messages.time's unit isn't pinned by anything this script can inspect
    directly; JS internals overwhelmingly use milliseconds-since-epoch. A
    seconds-epoch value for "now" is ~1.7e9; a milliseconds one is ~1.7e12,
    three orders of magnitude apart, so this threshold is not a coin flip.
    """
    if ts is None:
        return None
    if ts > 1e11:
        ts = ts / 1000
    return iso_from_epoch_seconds(ts)


def resolve_arch():
    # Mirrors thelounge-converge.sh's resolve_arch(): the artifact pointer
    # this reads (current-$ARCH.json) is keyed by that same convention, not
    # by uname's raw machine name.
    return {"aarch64": "arm64", "x86_64": "x86_64"}.get(
        platform.machine(), platform.machine()
    )


def read_instance_env():
    # Same file, same "export KEY=VALUE" shape every shell script in this
    # suite sources with `. "$INSTANCE_ENV"` -- parsed by hand here since
    # this process has no shell to source it into. Absent (early boot, before
    # user_data's write_instance_env runs) is not an error: callers that need
    # REGION/CONFIG_BUCKET degrade to "unavailable" until it appears, and
    # this is re-read (behind a short TTL below) rather than only at start,
    # so the AWS-backed panels come alive on their own once boot glue
    # finishes -- no restart required.
    env = {}
    try:
        for line in INSTANCE_ENV.read_text().splitlines():
            line = line.strip()
            if not line.startswith("export ") or "=" not in line:
                continue
            key, _, value = line[len("export ") :].partition("=")
            env[key] = value.strip().strip('"')
    except FileNotFoundError:
        pass
    return env


def instance_env():
    return cache.get("instance_env", 60, read_instance_env)


def aws_region():
    return instance_env().get("REGION")


def run_aws_s3_get(key, timeout=AWS_TIMEOUT_S):
    bucket = instance_env().get("CONFIG_BUCKET")
    region = aws_region()
    if not bucket or not region:
        return None
    env = os.environ.copy()
    env["AWS_USE_DUALSTACK_ENDPOINT"] = "true"
    try:
        proc = subprocess.run(
            ["aws", "s3", "cp", f"s3://{bucket}/{key}", "-", "--region", region],
            capture_output=True,
            timeout=timeout,
            env=env,
            text=True,
            check=True,
        )
        return json.loads(proc.stdout) if proc.stdout.strip() else None
    except Exception as exc:  # noqa: BLE001
        log(f"s3 cp {key} failed: {exc}")
        return None


# --- release / service ---------------------------------------------------------


def fetch_release_facts():
    facts = {
        "sha256": None,
        "deployed_at": None,
        "thelounge_version": None,
        "node_version": None,
        "plugins": [],
        "artifact_built_at": None,
        "update_available": None,
    }
    try:
        if CURRENT_RELEASE.is_symlink():
            target = CURRENT_RELEASE.resolve()
            facts["sha256"] = target.name
            # The symlink's own mtime, not the release directory's: converge
            # writes the release directory once, then `ln -sfn`s this symlink
            # at deploy time (thelounge-converge.sh's sync_release), so this
            # timestamp is exactly the moment this instance switched to it.
            facts["deployed_at"] = iso_from_epoch_seconds(
                CURRENT_RELEASE.lstat().st_mtime
            )

            pkg_json = target / "app" / "node_modules" / "thelounge" / "package.json"
            if pkg_json.exists():
                facts["thelounge_version"] = json.loads(pkg_json.read_text()).get(
                    "version"
                )

            node_bin = target / "node" / "bin" / "node"
            if node_bin.exists():
                out = subprocess.run(
                    [str(node_bin), "--version"],
                    capture_output=True,
                    timeout=3,
                    text=True,
                    check=True,
                )
                facts["node_version"] = out.stdout.strip().lstrip("v")
    except Exception as exc:  # noqa: BLE001
        log(f"release facts failed: {exc}")

    try:
        if PACKAGES_MANIFEST.exists():
            manifest = json.loads(PACKAGES_MANIFEST.read_text())
            facts["plugins"] = sorted(manifest.get("dependencies", {}).keys())
    except Exception as exc:  # noqa: BLE001
        log(f"plugin manifest read failed: {exc}")

    # What the delivery pipeline most recently built, per architecture --
    # confirms build time authoritatively (build/app/buildspec.yml writes it)
    # rather than inferring it, and doubles as an "is a newer release waiting
    # for the next converge tick" signal.
    pointer = run_aws_s3_get(f"artifacts/current-{resolve_arch()}.json")
    if pointer:
        facts["artifact_built_at"] = pointer.get("built_at")
        if facts["sha256"] and pointer.get("sha256"):
            facts["update_available"] = pointer["sha256"] != facts["sha256"]

    return facts


def release_facts():
    return cache.get("release_facts", 60, fetch_release_facts)


def systemctl_show(unit, properties):
    try:
        out = subprocess.run(
            ["systemctl", "show", unit, f"--property={','.join(properties)}"],
            capture_output=True,
            timeout=5,
            text=True,
            check=True,
        )
        result = {}
        for line in out.stdout.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                result[key] = value
        return result
    except Exception as exc:  # noqa: BLE001
        log(f"systemctl show {unit} failed: {exc}")
        return {}


def fetch_service_facts():
    svc = systemctl_show(
        "thelounge.service",
        ["ActiveState", "SubState", "ActiveEnterTimestamp", "NRestarts"],
    )
    timer = systemctl_show("thelounge-converge.timer", ["LastTriggerUSec"])
    return {
        # systemd's own timestamp strings (e.g. "Wed 2026-08-02 09:15:00
        # UTC") are passed through as-is rather than reparsed: they're
        # already human-readable, and systemd's own format has changed
        # across versions before -- reformatting it here is a second place
        # that assumption could go stale.
        "active_state": svc.get("ActiveState"),
        "sub_state": svc.get("SubState"),
        "active_since": svc.get("ActiveEnterTimestamp") or None,
        "restarts": int(svc["NRestarts"])
        if svc.get("NRestarts", "").isdigit()
        else None,
        "converge_last_trigger": timer.get("LastTriggerUSec") or None,
    }


def service_facts():
    return cache.get("service_facts", 15, fetch_service_facts)


# --- database ------------------------------------------------------------------


def read_users():
    """Every users/*.json, parsed once. Returns {username: parsed_dict}.
    Deliberately uncached (or nearly so, see USERS_TTL below): this backs the
    auth check, and a user who just signed in should show up on the very
    page they signed in to see, not up to a minute later.
    """
    users = {}
    try:
        for path in sorted(USERS_DIR.glob("*.json")):
            try:
                users[path.stem] = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                log(f"skipping unreadable user file {path.name}: {exc}")
    except FileNotFoundError:
        pass
    return users


# Short enough that a fresh login is recognized almost immediately, long
# enough that a page hammering /status/api doesn't reread every user file on
# every request.
USERS_TTL = 5


def cached_users():
    return cache.get("users", USERS_TTL, read_users)


def authenticated_user(auth_header):
    if not auth_header or not auth_header.startswith("Bearer "):
        return None
    token = auth_header[len("Bearer ") :].strip()
    if not token:
        return None
    token_hash = hashlib.sha512(token.encode()).hexdigest()
    for name, data in cached_users().items():
        if token_hash in data.get("sessions", {}):
            return name
    return None


def dir_bytes(path):
    """Total size of the regular files under path; 0 if it does not exist."""
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def volume_usage():
    st = os.statvfs(THELOUNGE_HOME)
    return {
        "volume_used_bytes": (st.f_blocks - st.f_bfree) * st.f_frsize,
        "volume_total_bytes": st.f_blocks * st.f_frsize,
    }


def fetch_db_stats():
    users = cached_users()
    per_user = []
    for name in users:
        entry = {
            "name": name,
            "message_count": None,
            "networks": None,
            "channels": None,
            "oldest": None,
            "newest": None,
            "size_bytes": None,
            "text_log_bytes": None,
        }
        db_path = LOGS_DIR / f"{name}.sqlite3"
        wal_path = LOGS_DIR / f"{name}.sqlite3-wal"
        try:
            entry["text_log_bytes"] = dir_bytes(LOGS_DIR / name)
        except OSError as exc:
            log(f"text log size failed for {name}: {exc}")
        if db_path.exists():
            entry["size_bytes"] = db_path.stat().st_size + (
                wal_path.stat().st_size if wal_path.exists() else 0
            )
            try:
                # mode=ro: this process never writes to a user's message
                # store, and a read-only open can't contend with The
                # Lounge's own writer for a lock.
                con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=2)
                try:
                    row = con.execute(
                        "SELECT COUNT(*), COUNT(DISTINCT network), "
                        "COUNT(DISTINCT channel), MIN(time), MAX(time) FROM messages"
                    ).fetchone()
                finally:
                    con.close()
                entry["message_count"], entry["networks"], entry["channels"] = (
                    row[0],
                    row[1],
                    row[2],
                )
                entry["oldest"] = iso_from_message_time(row[3])
                entry["newest"] = iso_from_message_time(row[4])
            except sqlite3.Error as exc:
                log(f"sqlite stats failed for {name}: {exc}")
        per_user.append(entry)

    session_count = sum(len(data.get("sessions", {})) for data in users.values())
    return {
        "user_count": len(users),
        # Counts session records on disk, not live socket connections -- The
        # Lounge doesn't expire these entries on its own, so this is "how
        # many browser logins have signed in", not "how many are open now".
        "active_session_count": session_count,
        "users": per_user,
        **volume_usage(),
    }


def db_stats():
    return cache.get("db_stats", 60, fetch_db_stats)


def build_payload(user):
    return {
        "generated_at": iso_from_epoch_seconds(time.time()),
        "auth": {"user": user},
        "release": release_facts(),
        "service": service_facts(),
        "database": db_stats(),
    }


# --- HTTP --------------------------------------------------------------------

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "Cache-Control": "no-store",
}


class DualStackHTTPServer(ThreadingHTTPServer):
    """Binds :: with IPV6_V6ONLY disabled.

    CloudFront's VPC origin ENI reaches this instance over IPv4 (same
    security_groups.tf rule this port reuses); the instance itself is
    otherwise IPv6-only. A dual-stack bind accepts both on one listener
    instead of running two.
    """

    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


class Handler(BaseHTTPRequestHandler):
    server_version = "thelounge-status/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Overridden only to route through this file's own log() (journald
        # either way); the default formatting never includes header values,
        # so the Authorization token is not at risk of being logged here.
        log(f"{self.address_string()} - {fmt % args}")

    def _send(self, status, content_type, body):
        self.send_response(status)
        for key, value in SECURITY_HEADERS.items():
            self.send_header(key, value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _error(self, status, message):
        self._send(status, "application/json", json.dumps({"error": message}).encode())

    def do_OPTIONS(self):
        self._send(HTTPStatus.NO_CONTENT, "text/plain", b"")

    def do_GET(self):
        try:
            if self.path == "/status/api":
                user = authenticated_user(self.headers.get("Authorization"))
                if user is None:
                    self._error(HTTPStatus.UNAUTHORIZED, "not signed in")
                    return
                payload = build_payload(user)
                self._send(
                    HTTPStatus.OK, "application/json", json.dumps(payload).encode()
                )
            else:
                self._error(HTTPStatus.NOT_FOUND, "not found")
        except Exception:  # noqa: BLE001 -- one request must never take the server down
            log(traceback.format_exc())
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal error")


def main():
    server = DualStackHTTPServer(("::", PORT), Handler)
    log(f"listening on [::]:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
