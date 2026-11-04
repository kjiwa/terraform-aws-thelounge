import io
import json
import urllib.error
from unittest import mock

import plugin
import pytest

PAYLOAD = {
    "release": {
        "thelounge_version": "4.5.2",
        "node_version": "22.1.0",
        "sha256": "abc",
        "deployed_at": "2026-10-01T00:00:00+00:00",
        "artifact_built_at": "2026-09-30T00:00:00+00:00",
        "update_available": False,
        "plugins": ["thelounge-plugin-catchup"],
    },
    "service": {
        "active_state": "active",
        "sub_state": "running",
        "active_since": "Thu 2026-10-01 00:00:00 UTC",
        "restarts": 0,
        "converge_last_trigger": "Thu 2026-10-01 00:05:00 UTC",
    },
    "database": {
        "user_count": 2,
        "active_session_count": 3,
        "volume_used_bytes": 1_234_000_000,
        "volume_total_bytes": 7_800_000_000,
        "users": [
            {
                "message_count": 10,
                "size_bytes": 1_500_000,
                "text_log_bytes": 3_000_000,
                "oldest": "2026-01-01",
                "newest": "2026-10-01",
            },
            {
                "message_count": 5,
                "size_bytes": 500_000,
                "text_log_bytes": 1_000_000,
                "oldest": "2025-12-01",
                "newest": "2026-09-01",
            },
        ],
    },
}


def respond(body):
    resp = mock.MagicMock()
    resp.read.return_value = (
        body if isinstance(body, bytes) else json.dumps(body).encode()
    )
    resp.__enter__.return_value = resp
    return resp


def http_error(code):
    return urllib.error.HTTPError("u", code, "err", {}, io.BytesIO(b""))


def authenticate(token="tok", **urlopen):
    headers = {"x-lounge-token": token} if token is not None else {}
    with mock.patch.object(plugin.urllib.request, "urlopen", **urlopen) as m:
        return plugin.authenticate(headers), m


def rows(section):
    return {r["label"]: r["value"] for r in section["rows"]}


def test_live_session_is_role_user_and_sends_bearer_token():
    role, m = authenticate(return_value=respond(PAYLOAD))
    assert role == "user"
    req = m.call_args.args[0]
    assert req.full_url == "https://irc.example.org/status/api"
    assert req.get_header("Authorization") == "Bearer tok"


def test_missing_token_is_none_without_a_call():
    role, m = authenticate(token=None)
    assert role is None
    m.assert_not_called()


@pytest.mark.parametrize("code", [401, 403])
def test_rejected_token_is_none(code):
    role, _ = authenticate(side_effect=http_error(code))
    assert role is None


@pytest.mark.parametrize(
    "exc", [urllib.error.URLError("down"), TimeoutError(), OSError("x")]
)
def test_transport_errors_are_none(exc):
    role, _ = authenticate(side_effect=exc)
    assert role is None


@pytest.mark.parametrize("body", [b"not json", [1], 3])
def test_bad_payload_is_none(body):
    role, _ = authenticate(return_value=respond(body))
    assert role is None


def test_release_section():
    authenticate(return_value=respond(PAYLOAD))
    facts = rows(plugin.sections()["release"]())
    assert facts["The Lounge"] == "4.5.2"
    assert facts["Update waiting"] == "no"
    assert facts["Plugins"] == "thelounge-plugin-catchup"


def test_service_section():
    authenticate(return_value=respond(PAYLOAD))
    facts = rows(plugin.sections()["service"]())
    assert facts["thelounge.service"] == "active/running"
    assert facts["Restarts"] == 0


def test_database_section_totals_every_user():
    authenticate(return_value=respond(PAYLOAD))
    facts = rows(plugin.sections()["database"]())
    assert facts["Messages"] == 15
    assert facts["Size (MB)"] == 2.0
    assert facts["Text logs (MB)"] == 4.0
    assert facts["Data volume used"] == "1.2 of 7.8 GB"
    assert facts["Oldest message"] == "2025-12-01"
    assert facts["Newest message"] == "2026-10-01"


def test_database_section_tolerates_no_users():
    authenticate(
        return_value=respond({**PAYLOAD, "database": {"user_count": 0, "users": []}})
    )
    facts = rows(plugin.sections()["database"]())
    assert facts["Messages"] is None
    assert facts["Size (MB)"] is None
    assert facts["Text logs (MB)"] is None
    assert facts["Data volume used"] is None


def test_section_without_facts_raises_so_the_core_reports_a_panel_error():
    authenticate(return_value=respond({}))
    with pytest.raises(RuntimeError):
        plugin.sections()["service"]()


def test_failed_authentication_clears_the_previous_payload():
    authenticate(return_value=respond(PAYLOAD))
    authenticate(side_effect=http_error(401))
    with pytest.raises(RuntimeError):
        plugin.sections()["release"]()
