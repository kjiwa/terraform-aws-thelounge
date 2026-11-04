"""The Lounge plugin for the status-page core.

authenticate() asks the instance's own /status/api whether the token is a live
Lounge session, so the gated routes work only while The Lounge is up. The token
arrives in X-Lounge-Token, not Authorization: CloudFront's OAC overwrites
Authorization with its SigV4 signature on the way to the Function URL. The
sections reuse the JSON authenticate() fetched, within the same invocation.
"""

import json
import os
import urllib.error
import urllib.request

SITE_URL = os.environ["SITE_URL"]
AUTH_TIMEOUT_S = 8

_payload = None


def fetch_payload(token):
    """The /status/api JSON for token, or None on any failure."""
    if not token:
        return None
    req = urllib.request.Request(
        f"{SITE_URL}/status/api",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=AUTH_TIMEOUT_S) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
        ValueError,
        OSError,
    ) as e:
        print(json.dumps({"auth_failed": f"{type(e).__name__}: {e}"}))
        return None
    if not isinstance(body, dict):
        print(json.dumps({"auth_failed": "non-object /status/api response"}))
        return None
    return body


def authenticate(headers):
    global _payload
    _payload = fetch_payload(headers.get("x-lounge-token"))
    return "user" if _payload is not None else None


def section(name):
    if _payload is None or not isinstance(_payload.get(name), dict):
        raise RuntimeError(f"/status/api returned no {name} facts")
    return _payload[name]


def join(values):
    return ", ".join(values) if values else None


def yes_no(flag):
    return None if flag is None else ("yes" if flag else "no")


def release():
    r = section("release")
    return {
        "title": "Release",
        "rows": [
            {"label": "The Lounge", "value": r.get("thelounge_version")},
            {"label": "Node.js", "value": r.get("node_version")},
            {
                "label": "Artifact",
                "value": r.get("sha256"),
                "caption": "SHA-256 of the release directory the instance runs.",
            },
            {"label": "Deployed at", "value": r.get("deployed_at")},
            {"label": "Built at", "value": r.get("artifact_built_at")},
            {
                "label": "Update waiting",
                "value": yes_no(r.get("update_available")),
                "caption": "Whether the pipeline's latest artifact differs from the running one.",
            },
            {"label": "Plugins", "value": join(r.get("plugins"))},
        ],
    }


def service():
    s = section("service")
    state = "/".join(p for p in (s.get("active_state"), s.get("sub_state")) if p)
    return {
        "title": "Service",
        "rows": [
            {"label": "thelounge.service", "value": state or None},
            {"label": "Active since", "value": s.get("active_since")},
            {"label": "Restarts", "value": s.get("restarts")},
            {
                "label": "Last converge",
                "value": s.get("converge_last_trigger"),
                "caption": "When thelounge-converge.timer last fired.",
            },
        ],
    }


def total(users, key):
    values = [u[key] for u in users if u.get(key) is not None]
    return sum(values) if values else None


def volume_usage(d):
    used, size = d.get("volume_used_bytes"), d.get("volume_total_bytes")
    if used is None or size is None:
        return None
    return f"{used / 1e9:.1f} of {size / 1e9:.1f} GB"


def database():
    d = section("database")
    users = d.get("users") or []
    size_bytes = total(users, "size_bytes")
    text_log_bytes = total(users, "text_log_bytes")
    return {
        "title": "Database",
        "rows": [
            {"label": "Users", "value": d.get("user_count")},
            {
                "label": "Sessions",
                "value": d.get("active_session_count"),
                "caption": "Session records on disk, not open connections.",
            },
            {"label": "Messages", "value": total(users, "message_count")},
            {
                "label": "Size (MB)",
                "value": None if size_bytes is None else round(size_bytes / 1e6, 1),
                "caption": "Message stores of every user.",
            },
            {
                "label": "Text logs (MB)",
                "value": None
                if text_log_bytes is None
                else round(text_log_bytes / 1e6, 1),
                "caption": "Plain-text channel logs of every user; never pruned.",
            },
            {
                "label": "Data volume used",
                "value": volume_usage(d),
                "caption": "Whole data volume, including everything not counted above.",
            },
            {
                "label": "Oldest message",
                "value": min(
                    (u["oldest"] for u in users if u.get("oldest")), default=None
                ),
            },
            {
                "label": "Newest message",
                "value": max(
                    (u["newest"] for u in users if u.get("newest")), default=None
                ),
            },
        ],
    }


def sections():
    return {"release": release, "service": service, "database": database}
