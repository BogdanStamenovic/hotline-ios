"""Losing the phone's address must be fatal, not a degradation.

The daemon binds two addresses: the tailnet IP his phone dials, and loopback for
the hook and local CLIs. `asyncio.start_server` over that list binds whatever it
can and raises only if *every* address fails -- and loopback effectively cannot
fail. So at boot, before tailscaled is up, the daemon bound loopback alone,
logged that it was listening on the tailnet address anyway, and served a phone
that could not reach it while every local probe passed.

That is the same shape as the hook firing into a closed port (see
`endpoint.py`), and it was introduced *by* the fix for it: adding loopback is
what made "could not bind on any address" unreachable.
"""

from __future__ import annotations

from hotline_ios.endpoint import LOOPBACK, bind_hosts, unreachable

TAILNET = "100.72.2.62"


def test_missing_tailnet_address_is_reported() -> None:
    requested = bind_hosts(TAILNET)
    assert unreachable(requested, [LOOPBACK]) == [TAILNET]


def test_nothing_missing_when_both_bound() -> None:
    requested = bind_hosts(TAILNET)
    assert unreachable(requested, [TAILNET, LOOPBACK]) == []


def test_loopback_alone_is_never_reported_missing() -> None:
    """A loopback-only deployment is a legitimate configuration, not a fault."""
    assert unreachable([LOOPBACK], [LOOPBACK]) == []


def test_the_guard_covers_every_address_bind_hosts_adds() -> None:
    """Pinned to `bind_hosts` rather than a literal pair.

    If a third address is ever added there, this fails until the guard is
    considered for it -- rather than silently not covering it.
    """
    requested = bind_hosts(TAILNET)
    assert unreachable(requested, []) == [h for h in requested if h != LOOPBACK]
