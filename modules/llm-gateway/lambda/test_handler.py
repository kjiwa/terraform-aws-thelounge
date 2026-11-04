import handler
import pytest


class FakeBedrock:
    def __init__(self, content=None):
        self.calls = []
        self.content = content or [{"text": "summary"}]
        self.stop_reason = "end_turn"

    def converse(self, **kwargs):
        self.calls.append(kwargs)
        return {
            "output": {"message": {"content": self.content}},
            "stopReason": self.stop_reason,
            "usage": {"inputTokens": 3, "outputTokens": 1},
        }


@pytest.fixture
def bedrock(monkeypatch):
    fake = FakeBedrock()
    monkeypatch.setattr(handler, "_client", fake)
    monkeypatch.setenv("MODEL_ID", "us.amazon.nova-lite-v1:0")
    return fake


def test_converse_request_shape(bedrock):
    result = handler.handler({"system": "be brief", "prompt": "hello"}, None)

    assert result == {"text": "summary", "cut": False}
    (call,) = bedrock.calls
    assert call["modelId"] == "us.amazon.nova-lite-v1:0"
    assert call["system"] == [{"text": "be brief"}]
    assert call["messages"] == [{"role": "user", "content": [{"text": "hello"}]}]
    assert call["inferenceConfig"] == {"maxTokens": 1500, "temperature": 0}


def test_reports_a_reply_cut_at_the_output_cap(bedrock):
    bedrock.stop_reason = "max_tokens"

    assert handler.handler({"system": "s", "prompt": "p"}, None)["cut"] is True


def test_a_response_without_stop_reason_is_not_cut(bedrock):
    bedrock.stop_reason = None

    assert handler.handler({"system": "s", "prompt": "p"}, None)["cut"] is False


def test_model_is_not_caller_controlled(bedrock):
    handler.handler(
        {"system": "s", "prompt": "p", "modelId": "other", "model_id": "other"}, None
    )

    assert bedrock.calls[0]["modelId"] == "us.amazon.nova-lite-v1:0"


def test_joins_text_blocks(bedrock):
    bedrock.content = [{"text": "a"}, {"reasoning": "x"}, {"text": "b"}]

    assert handler.handler({"system": "s", "prompt": "p"}, None) == {
        "text": "ab",
        "cut": False,
    }


@pytest.mark.parametrize(
    "event",
    [
        None,
        {},
        {"system": "s"},
        {"prompt": "p"},
        {"system": "", "prompt": "p"},
        {"system": "s", "prompt": 1},
    ],
)
def test_rejects_malformed_input(bedrock, event):
    with pytest.raises(ValueError):
        handler.handler(event, None)
    assert bedrock.calls == []


def test_rejects_oversized_input(bedrock):
    with pytest.raises(ValueError):
        handler.handler({"system": "s", "prompt": "x" * handler.MAX_INPUT_CHARS}, None)
    assert bedrock.calls == []


def test_accepts_input_at_the_cap(bedrock):
    handler.handler(
        {"system": "s", "prompt": "x" * (handler.MAX_INPUT_CHARS - 1)}, None
    )

    assert len(bedrock.calls) == 1


def test_never_logs_payload(bedrock, capsys):
    handler.handler({"system": "SECRET-SYSTEM", "prompt": "SECRET-PROMPT"}, None)

    out = capsys.readouterr()
    assert "SECRET" not in out.out + out.err
