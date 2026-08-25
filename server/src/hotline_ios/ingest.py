"""Turning a slice of transcript into phases and events.

The hook is a nudge and the transcript is the content (§2). This module is the
part in between: given what `hotline.transcript.events_since` read, decide what
belongs in the store and what a phase is.

**Phase boundaries come from the transcript's own structure**, not from hook
fields. A real user turn opens one; the assistant's `tool_use` blocks are its
tool list; it closes on the next real user turn or on Stop. Nothing here asks
the hook what happened, which is why a daemon that was down for an hour catches
up by reading rather than by having missed the events.

**The title is frozen at open.** It is a truncation of the prompt, because no
hook payload carries a human-written summary -- verified against Claude Code
2.1.241, whose `UserPromptSubmit` gives `prompt` and nothing else. A title that
rewrote itself as the turn progressed would move under his finger mid-scroll.
The thing that arrives later is the `outcome`, a separate field.

**Subagents nest, they do not get a channel.** They have no `Registry` entry and
no identity hotline treats as channel-worthy, so their tool calls are filed
under the parent's open phase with `via_subagent` set. Their own prompts and
their own prose are dropped: a subagent's internal report is not the parent's
answer, which is the exact trap `transcript.read_since` was written to avoid.
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger("hotline-iosd.ingest")

PHASE_TITLE_MAX = 80
PHASE_TITLE_MIN = 60
"""§2's ~60-80 characters. The window is what lets the cut land on a word
boundary instead of mid-word, without ever getting so short it says nothing."""

TOOL_SUMMARY_MAX = 200
"""§2's storage policy: the tool name plus a ~200-char one-line summary of the
primary argument. The authoritative full record stays on disk in the transcript,
untouched -- this is a label for a row on a phone, not a copy of the data."""

OUTCOME_MAX = 240
"""Longer than a title because it is read once, at the end of a phase, rather
than scanned down a list."""

FIRST_SLICE_BYTES = 256 << 10
"""How far back first contact with an unwatched session reads.

A session that has been running all day has a transcript measured in megabytes,
and replaying it would write tens of thousands of rows into the map at once,
all stamped with old timestamps, for a channel he has never looked at. The map
starts when the daemon starts watching; what came before is still on disk."""

# Which argument actually identifies the call. Everything else in `tool_input`
# is either noise on a phone row (`limit`, `offset`, `replace_all`) or the whole
# file being written.
PRIMARY_ARGUMENT = {
    "Bash": ("command",),
    "BashOutput": ("bash_id",),
    "Read": ("file_path",),
    "Write": ("file_path",),
    "Edit": ("file_path",),
    "NotebookEdit": ("notebook_path",),
    "Grep": ("pattern",),
    "Glob": ("pattern",),
    "Agent": ("description", "prompt"),
    "Task": ("description", "prompt"),
    "WebFetch": ("url",),
    "WebSearch": ("query",),
    "ToolSearch": ("query",),
    "Skill": ("skill",),
    "Artifact": ("file_path", "url"),
    "SendMessage": ("message",),
}
GENERIC_ARGUMENT = (
    "description", "command", "file_path", "path", "pattern",
    "query", "url", "prompt", "text", "name",
)

_WHITESPACE = re.compile(r"\s+")


def _one_line(value: Any, limit: int) -> str:
    text = _WHITESPACE.sub(" ", str(value)).strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def summarise(tool: str, arguments: dict[str, Any]) -> str:
    """A one-line label for a tool call, from its primary argument."""
    if not isinstance(arguments, dict):
        return ""
    for key in PRIMARY_ARGUMENT.get(tool, ()) + GENERIC_ARGUMENT:
        value = arguments.get(key)
        if isinstance(value, str) and value.strip():
            return _one_line(value, TOOL_SUMMARY_MAX)
    # Unknown tool with an unfamiliar argument list -- a plugin, or an MCP
    # server nobody has seen. The first string is a guess, but a labelled row
    # beats a blank one and the tool name beside it is still exact.
    for value in arguments.values():
        if isinstance(value, str) and value.strip():
            return _one_line(value, TOOL_SUMMARY_MAX)
    return ""


def phase_title(prompt: str) -> str:
    """~60-80 characters of the prompt, cut on a word boundary where one is near."""
    text = _WHITESPACE.sub(" ", prompt).strip()
    if len(text) <= PHASE_TITLE_MAX:
        return text
    head = text[:PHASE_TITLE_MAX]
    space = head.rfind(" ")
    if space >= PHASE_TITLE_MIN:
        head = head[:space]
    return head.rstrip(" ,.;:-") + "…"


def describe_compaction(detail: dict[str, Any]) -> str:
    """The compact_boundary record's real numbers, as one readable line.

    §9.1: every quantity shown has to encode a real one. `preTokens`,
    `postTokens` and `durationMs` are computed by the CLI itself, so this row
    says "48027 -> 4070 tokens in 71.1s" rather than "compacted".
    """
    pre, post = detail.get("pre_tokens"), detail.get("post_tokens")
    duration = detail.get("duration_ms")
    parts: list[str] = []
    if isinstance(pre, int | float) and isinstance(post, int | float):
        parts.append(f"{int(pre)} → {int(post)} tokens")
    if isinstance(duration, int | float):
        parts.append(f"in {float(duration) / 1000:.1f}s")
    trigger = detail.get("trigger")
    if trigger:
        parts.append(f"({trigger})")
    return "compacted " + " ".join(parts) if parts else "compacted"


@dataclass
class Ingested:
    """What one absorb() actually wrote. Every field is counted, not assumed."""

    events: int = 0
    tools: int = 0
    phases_opened: int = 0
    phases_closed: int = 0
    compactions: int = 0
    last_tool_at: float | None = None
    last_compaction: dict[str, Any] = field(default_factory=dict)
    # `(at, characters)` for each piece of assistant prose in this slice, at the
    # transcript's own timestamps. The only source there is for an output rate:
    # §2 keeps the authoritative text on disk and stores only a phase outcome,
    # so the characters have to be counted as they go past rather than queried
    # back later. Subagent prose is excluded, the same as everywhere else here
    # -- it is not the parent's answer.
    text_samples: list[tuple[float, int]] = field(default_factory=list)


def absorb(
    store: Any,
    agent: str,
    events: list[Any],
    *,
    turn_ended: bool = False,
    now: float | None = None,
) -> Ingested:
    """Write one slice of transcript events into the store as phases and events.

    `turn_ended` is the Stop nudge. It is the only thing the hook contributes
    beyond "go and look": the transcript's own end-of-turn marker lands *after*
    Stop fires, so a phase would otherwise stay open until the next prompt.

    The outcome is taken from the last assistant prose in the slice rather than
    from `Stop.last_assistant_message`. Same value, and it keeps the hook
    payload at four small fields with no model output crossing the wire, which
    is the whole reason §2 chose a nudge over a content channel.
    """
    now = time.time() if now is None else now
    result = Ingested()
    open_phase = store.open_phase_of(agent)
    phase_id = str(open_phase["id"]) if open_phase else None
    pending_outcome = ""

    def covering(at: float) -> str | None:
        """Which phase a step belongs to when none is currently open.

        Measured end to end: a subagent's tool calls are never in the store
        while the phase that spawned them is still open. Its file is written
        after the parent's Stop, and a background subagent outlives the parent's
        turn entirely -- so with no fallback every `via_subagent` row would land
        unphased, which is the thing §2 asked for nesting to avoid.
        """
        found = store.phase_at(agent, at)
        return str(found["id"]) if found else None

    def close(at: float | None) -> None:
        nonlocal phase_id, pending_outcome
        if phase_id is None:
            return
        outcome = _one_line(pending_outcome, OUTCOME_MAX) if pending_outcome else None
        if store.close_phase(phase_id, outcome=outcome, ended_at=at or now):
            result.phases_closed += 1
            store.append_event(agent, "outcome", outcome or "",
                               phase_id=phase_id, at=at or now)
            result.events += 1
        phase_id, pending_outcome = None, ""

    for event in events:
        at = event.at if event.at is not None else now
        if event.is_sidechain and event.kind in ("user", "assistant"):
            # A subagent's own prompt is not a turn of the parent, and its prose
            # is not the parent's answer. Only its tool calls are the parent's
            # business, and those nest below.
            continue
        if event.kind == "user":
            close(at)
            phase_id = uuid.uuid4().hex[:12]
            title = phase_title(event.text)
            store.open_phase(phase_id, agent, title, started_at=at)
            store.append_event(agent, "phase", title, phase_id=phase_id, at=at)
            result.phases_opened += 1
            result.events += 1
        elif event.kind == "assistant":
            if event.text.strip():
                pending_outcome = event.text
                result.text_samples.append((at, len(event.text)))
        elif event.kind == "tool":
            store.append_event(
                agent, "tool", summarise(str(event.tool or ""), event.detail),
                tool=str(event.tool or ""), phase_id=phase_id or covering(at),
                via_subagent=event.is_sidechain, at=at,
                # Kept so the `PostToolUse` nudge, which arrives after this row
                # exists, can find it and fill in how long the call took.
                tool_use_id=event.tool_use_id,
            )
            result.events += 1
            result.tools += 1
            result.last_tool_at = at
        elif event.kind == "compact":
            store.append_event(agent, "compact", describe_compaction(event.detail),
                               tool="compact", phase_id=phase_id or covering(at), at=at)
            result.events += 1
            result.compactions += 1
            result.last_compaction = dict(event.detail)

    if turn_ended:
        close(None)
    return result
