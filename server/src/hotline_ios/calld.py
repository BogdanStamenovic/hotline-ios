"""The way from hotline-iosd to hotline-calld, which owns phone calls.

Calls moved out of this daemon on 2026-10-31 (Bogdan, Discord
1566035363657420962: "hotline-ios is not the right place for call semantics").
What this daemon still does about calls is all here, and all of it is HTTP to
hotline-calld on loopback:

- **`/api/v1/call` is forwarded**, unchanged in both directions, so every agent
  and script that rang him through 8789 keeps working while callers move to
  hotline-calld's own port. Removing the forward is the end of the transition.
- **`/health` reports hotline-calld's ring state** (`ok`, `ring_ready`, `fake`,
  `transport`, ...), because the iPhone app and the `call-bogdan` skill read the
  doorbell's health off this endpoint and have no other way to learn it.
- **His typed answer and his dismissal are forwarded** to `/api/v1/call/reply`
  and `/api/v1/call/hangup`, so a `hotline-call` blocked on him returns when he
  types into the conversation the call opened here.

The conversations themselves stay here: hotline-calld writes each call into this
daemon's store through `/api/v1/conversations/{open,append,close}`.

Standard library only, like `hotline-call`'s own client, and synchronous: the
daemon runs these in an executor.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any

log = logging.getLogger("hotline-iosd.calld")

DEFAULT_URL = "http://127.0.0.1:8792"

CALL_FIELDS = ("ok", "fake", "ring_ready", "transport", "rings_when_closed",
               "transports_available", "inbound", "can_talk", "default_engine")
"""What /health takes from hotline-calld's own /health, under the same names it
always had here, so the app's `Health` decoder sees no change."""


class CalldUnreachable(Exception):
    """hotline-calld did not answer at all: refused, timed out, or not running."""


class CallDaemon:
    def __init__(self, url: str | None = None, api_key: str | None = None) -> None:
        self.url = (url or os.environ.get("HOTLINE_IOS_CALLD_URL", "") or DEFAULT_URL).rstrip("/")
        self.api_key = os.environ.get("HOTLINE_API_KEY", "") if api_key is None else api_key
        self.forward_failures = 0
        self.last_forward_error = ""

    def _request(self, method: str, path: str, body: dict[str, Any] | None,
                 timeout: float) -> tuple[int, dict[str, Any]]:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.url}{path}", data=data, method=method,
                                         headers={"Content-Type": "application/json"})
        if self.api_key:
            request.add_header("X-Hotline-Key", self.api_key)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, dict(json.loads(response.read() or b"{}"))
        except urllib.error.HTTPError as exc:
            # hotline's httpd answers errors as {"error": "..."}; keep the shape.
            raw = exc.read()
            try:
                payload = dict(json.loads(raw or b"{}"))
            except ValueError:
                payload = {"error": raw.decode(errors="replace")[:400]}
            return exc.code, payload
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise CalldUnreachable(f"hotline-calld at {self.url}: {exc}") from exc

    def place(self, body: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        """Forward one `/api/v1/call` and hand back exactly what it answered.

        The deadline outlives the call: a ring (`ring_timeout`) plus his answer
        (`timeout`, 900 s by default, the same default hotline-calld applies)
        plus slack, or a long conversation would look like a dead daemon.
        """
        ring = float(body.get("ring_timeout", 45.0) or 45.0)
        answer = float(body.get("timeout", 900.0) or 900.0)
        return self._request("POST", "/api/v1/call", body, ring + answer + 60.0)

    def health(self, timeout: float = 2.0) -> dict[str, Any]:
        status, payload = self._request("GET", "/health", None, timeout)
        if status != 200:
            raise CalldUnreachable(f"hotline-calld /health answered {status}")
        return payload

    def forward(self, path: str, body: dict[str, Any]) -> bool:
        """Best effort: a reply he typed is already stored here either way."""
        try:
            status, payload = self._request("POST", path, body, 3.0)
        except CalldUnreachable as exc:
            self.forward_failures += 1
            self.last_forward_error = str(exc)
            log.warning("could not forward %s: %s", path, exc)
            return False
        if status != 200:
            self.forward_failures += 1
            self.last_forward_error = f"{path} answered {status}: {payload}"
            log.warning("%s", self.last_forward_error)
            return False
        return True
