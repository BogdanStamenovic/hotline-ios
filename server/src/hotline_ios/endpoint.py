"""Where this daemon listens, and where local tooling reaches it. One answer.

These used to be two independent constants that happened to disagree, and the
disagreement was invisible. `hooks.DEFAULT_URL` pointed the map hook at
`http://127.0.0.1:8789`; `daemon.main` bound the tailnet address alone, because
binding loopback alone had previously meant his phone could not reach it at all.
So the hook fired into a closed port on every tool call of every session on the
box -- and the hook is *designed* to fail silently, so nothing said a word. The
map would simply have been empty apart from whatever the safety poll caught.

That is the loopback-doorbell failure shape: a component reporting success while
doing nothing. The fix is not to make the hook noisy -- it cannot be, that is the
whole point of it -- it is to make the address reachable and to keep the two
facts in one place so they cannot drift apart again.

**Two explicit binds, not `0.0.0.0`.** The wildcard would also expose the daemon
to whatever LAN or cafe wifi this machine is on, which is a security posture
change and not one to make as a side effect of fixing a hook.
"""

from __future__ import annotations

import os

DEFAULT_PORT = 8789
"""One past hotlined's 8788, so the two are obviously siblings."""

LOOPBACK = "127.0.0.1"
"""What everything on this box uses: the hook, the statusline wrapper, any CLI.

Always bound, never the only bind."""

DEFAULT_HOST = "100.72.2.62"
"""The tailnet address his phone dials. Overridable; loopback is not."""


def port() -> int:
    try:
        return int(os.environ.get("HOTLINE_IOS_PORT") or DEFAULT_PORT)
    except ValueError:
        return DEFAULT_PORT


def bind_hosts(host: str | None = None) -> list[str]:
    """Every address the daemon listens on, loopback included, deduplicated.

    Loopback is appended rather than offered as a choice. A daemon whose own
    machine cannot reach it is broken for the hook, the statusline wrapper and
    every local CLI, and that has already happened once.
    """
    wanted = [host or os.environ.get("HOTLINE_IOS_HOST") or DEFAULT_HOST, LOOPBACK]
    out: list[str] = []
    for address in wanted:
        if address and address not in out:
            out.append(address)
    return out


def local_url(path: str = "", port_number: int | None = None) -> str:
    """The URL local tooling should use. The single source of the hook's target."""
    return f"http://{LOOPBACK}:{port_number or port()}{path}"
