"""LLM gateway for the catch-up plugin.

The instance has no IPv4 egress and bedrock-runtime has no IPv6 endpoint, so
the instance invokes this function (Lambda has a dual-stack endpoint) and the
function calls Bedrock. The model is fixed by MODEL_ID; callers choose only
the text. The payload is chat content and is never logged.
"""

import os

MAX_INPUT_CHARS = 250_000
MAX_OUTPUT_TOKENS = 1500

_client = None


def _bedrock():
    global _client
    if _client is None:
        import boto3

        _client = boto3.client(
            "bedrock-runtime", region_name=os.environ["BEDROCK_REGION"]
        )
    return _client


def _text_field(event, name):
    value = event.get(name) if isinstance(event, dict) else None
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a non-empty string")
    return value


def handler(event, context):
    system = _text_field(event, "system")
    prompt = _text_field(event, "prompt")
    if len(system) + len(prompt) > MAX_INPUT_CHARS:
        raise ValueError(f"input exceeds {MAX_INPUT_CHARS} characters")

    response = _bedrock().converse(
        modelId=os.environ["MODEL_ID"],
        system=[{"text": system}],
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": MAX_OUTPUT_TOKENS, "temperature": 0},
    )
    text = "".join(
        block.get("text", "") for block in response["output"]["message"]["content"]
    )
    print(
        f"input_chars={len(system) + len(prompt)} usage={response.get('usage')} stop={response.get('stopReason')}"
    )
    return {"text": text, "cut": response.get("stopReason") == "max_tokens"}
