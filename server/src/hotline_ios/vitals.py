"""The live numbers on an agent's channel, and where each one comes from.

§9.1 is the rule these exist under and it is worth restating, because it is the
thing that would be easiest to quietly break: **every animated quantity has to
encode a real number.** A readout that cannot be sourced from something the
daemon actually observed does not ship. A pulse that means nothing is a failure
mode this project has already rejected once.

So each field here names its source, and the ones that cannot be honest are
`None` rather than zero:

| field | source | exact? |
|---|---|---|
| `tokensPerSec` | assistant text length over wall time, from the transcript reads | approximate -- **characters, not tokens** |
| `toolsPerMin` | `tool` rows in the window, counted in SQL | exact |
| `lastToolAt` | `agents.last_tool_at`, only ever set from an observed tool call | exact |
| `blockedFor` | `conversations.waiting_since` | exact |
| `contextUsed` | the statusLine payload's `used_percentage / 100` | exact, computed by the CLI |

**`tokensPerSec` is characters and must never be presented as a billing figure.**
The app labels the cell `ch/s` for exactly this reason. There is no tokenizer
here and inventing one would make the number worse, not better.

**The character samples are in memory and the tool counts are not.** That
asymmetry is deliberate rather than an oversight: a tool call is a row in the
store already, so counting them is a `WHERE`; assistant prose is not stored at
all -- §2 keeps the authoritative text on disk in the transcript and stores only
a phase outcome -- so a rate over it has to be accumulated as the reads happen.
The cost is that a daemon restart reports `0.0` until the agent next produces
something, which is true: nothing has been observed yet.

**A dead agent is flat and still.** That is a correctness requirement on the
data, not a styling note, and it falls out here rather than being enforced in
the app: no samples in the window is a rate of zero, and nothing decays into a
number on its own.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Iterable
from typing import Any

WINDOW = 90.0
"""The rolling window, matching the sparkline's own 90 s default (§5.5)."""

MIN_SPAN = 5.0
"""Floor on the denominator of the character rate.

The window is what samples are kept for; the divisor is how long output has
actually been observed for, so a burst that started three seconds ago is not
divided by ninety and reported as nearly idle. Without a floor the first sample
of a burst would divide by something close to zero and print a rate in the
thousands, which is the opposite lie."""

MAX_SAMPLES = 4096
"""A bound on one agent's deque, so a session that never stops talking cannot
grow this without limit between window trims."""


class Rates:
    """Assistant output per agent, sampled at the transcript's own timestamps.

    Not a store: this is live state about right now, it is cheap to rebuild, and
    persisting it would mean a restart replaying an hour-old burst as if it were
    happening. `forget()` exists so a purge can drop an agent's samples along
    with its rows.
    """

    def __init__(self, window: float = WINDOW) -> None:
        self.window = window
        self._samples: dict[str, deque[tuple[float, int]]] = {}

    def observe(self, agent: str, samples: Iterable[tuple[float, int]]) -> None:
        """Record `(at, characters)` pairs, timestamped by the transcript itself.

        The transcript's timestamps rather than the read's: a read that catches
        up on a minute of output has not just seen a minute of output happen,
        and stamping it with `now` would draw a spike where there was a steady
        line.
        """
        bucket = self._samples.get(agent)
        if bucket is None:
            bucket = self._samples[agent] = deque(maxlen=MAX_SAMPLES)
        for at, chars in samples:
            if chars > 0:
                bucket.append((float(at), int(chars)))

    def chars_per_sec(self, agent: str, now: float) -> float:
        bucket = self._samples.get(agent)
        if not bucket:
            return 0.0
        cutoff = now - self.window
        while bucket and bucket[0][0] < cutoff:
            bucket.popleft()
        if not bucket:
            return 0.0
        total = sum(chars for _at, chars in bucket)
        span = min(self.window, max(MIN_SPAN, now - bucket[0][0]))
        return round(total / span, 2)

    def forget(self, agent: str) -> None:
        self._samples.pop(agent, None)


def project(
    *,
    agent: str,
    annotation: dict[str, Any],
    tools_in_window: int,
    blocked_since: float | None,
    rates: Rates,
    now: float,
    window: float = WINDOW,
) -> dict[str, Any]:
    """The `Vitals` block for one roster row. A projection, not a new ingest.

    Everything here is already being collected for another reason -- §2's
    transcript tailing writes the tool rows, the statusline wrapper writes the
    context sample, a ring writes `waiting_since`. This only reads them.
    """
    context = annotation.get("context_used")
    return {
        "tokensPerSec": rates.chars_per_sec(agent, now),
        "toolsPerMin": round(tools_in_window * 60.0 / window, 2),
        "lastToolAt": (
            float(annotation["last_tool_at"]) if annotation.get("last_tool_at") else None
        ),
        # nil when not blocked, rather than zero: "not waiting" and "has been
        # waiting no time at all" are different and the app renders a pin for
        # one of them.
        "blockedFor": round(now - blocked_since, 1) if blocked_since is not None else None,
        # nil until a real sample arrives. The CLI reports null before a
        # session's first turn and storing that as zero would draw an empty
        # gauge on a session whose usage is simply unknown.
        "contextUsed": float(context) if context is not None else None,
    }
