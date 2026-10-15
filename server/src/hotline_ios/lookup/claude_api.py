"""The Messages API client for mid-call lookups.

The key is Bogdan's, authorised for this use, read from ~/keys/claude.txt (mode 600) at
runtime and handed to the SDK in-process: never put in argv, the environment, a log or a
file. Every call's token usage and cost goes to a JSONL log (no key, no content).
"""
from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

KEY_FILE = Path(os.environ.get("HOTLINE_IOS_CLAUDE_KEY_FILE", str(Path.home() / "keys/claude.txt")))
USAGE_LOG = Path(os.environ.get("HOTLINE_IOS_CLAUDE_USAGE", str(Path.home() / ".local/state/hotline-ios/claude-usage.jsonl")))
PRICE = {"claude-haiku-4-5": (1.00, 5.00), "claude-sonnet-5": (2.00, 10.00)}  # $ per 1M input / output tokens

_client = None
_lock = threading.Lock()


def available() -> bool:
    return KEY_FILE.is_file()


def client():
    global _client
    with _lock:
        if _client is None:
            import anthropic

            key = KEY_FILE.read_text().strip()
            _client = anthropic.Anthropic(api_key=key, max_retries=1, timeout=20.0)
            del key
    return _client


def log_usage(kind: str, model: str, usage, seconds: float, **extra) -> dict:
    pin, pout = PRICE.get(model, (1.0, 5.0))
    u = {"input": usage.input_tokens, "output": usage.output_tokens,
         "cache_read": getattr(usage, "cache_read_input_tokens", 0) or 0,
         "cache_write": getattr(usage, "cache_creation_input_tokens", 0) or 0}
    usd = (u["input"] + 1.25 * u["cache_write"] + 0.1 * u["cache_read"]) * pin / 1e6 + u["output"] * pout / 1e6
    rec = {"t": round(time.time(), 3), "kind": kind, "model": model, **u, "usd": round(usd, 6),
           "seconds": round(seconds, 3), **extra}
    try:
        USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with USAGE_LOG.open("a") as f:
            f.write(json.dumps(rec) + "\n")
    except OSError:
        pass
    return rec
