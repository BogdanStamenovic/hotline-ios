"""Labels for the duplex-call transcript returned to the calling agent.

Bogdan's rule (2026-10-16): PersonaPlex may answer on its own before a lookup lands (he
knows the lookup has engaged when it goes silent and says "let me check"), but the calling
agent must not be misled by it. So the model's speech is labelled by when it was said:

- between the end of his question and the HOLD: "unverified, spoken before lookup"
- from the end of the injected answer until he next speaks: "from Claude"
- anything else: unlabelled (PersonaPlex talking on its own, as on any duplex call)

All times are call time (seconds since the model was first fed).
"""
from __future__ import annotations

from dataclasses import dataclass

UNVERIFIED = "unverified, spoken before lookup"
FROM_CLAUDE = "from Claude"


@dataclass
class Lookup:
    question: str
    t_question_end: float
    t_hold: float
    t_injected: float | None = None   # when the injection finished (None: never sent)
    abstained: bool = False


def label_for(t: float, lookups: list[Lookup], his_starts: list[float]) -> str:
    """The label for a model segment starting at call time t."""
    for lk in lookups:
        if lk.t_question_end - 0.2 <= t < lk.t_hold:
            return UNVERIFIED
        if lk.t_injected is not None and t >= lk.t_injected - 0.3:
            nxt = [h for h in his_starts if h > lk.t_injected]
            if t < (min(nxt) if nxt else lk.t_injected + 20.0):
                return FROM_CLAUDE
    return ""


def labelled_turns(turns: list[tuple[float, str, str]], lookups: list[Lookup]) -> list[tuple[float, str, str]]:
    """turns: (call time, "you"|"claude", text), one per transcript segment, time-ordered.
    Returns the same with the model's text prefixed by its label, consecutive segments of
    the same speaker and label merged."""
    his_starts = [t for t, who, _ in turns if who == "you"]
    out: list[tuple[float, str, str, str]] = []
    for t, who, text in turns:
        lab = label_for(t, lookups, his_starts) if who == "claude" else ""
        if out and out[-1][1] == who and out[-1][3] == lab:
            out[-1] = (out[-1][0], who, out[-1][2] + " " + text, lab)
        else:
            out.append((t, who, text, lab))
    return [(t, who, f"[{lab}] {text}" if lab else text) for t, who, text, lab in out]
