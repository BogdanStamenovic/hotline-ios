"""The two pieces of Claude Code configuration the map needs, and their installer.

Both of these run inside **every turn of every session on this box**, including
Bogdan's own work. That is the whole design constraint. Everything else here
follows from it:

* **Always exit 0.** A non-zero hook can block a tool call. Nothing this daemon
  wants is worth failing a real turn for.
* **A ~300 ms timeout and a blanket `except`.** A daemon that is down, hung, or
  mid-restart must cost a fraction of a second, once.
* **A 30 s backoff after a failure.** §2 asks for it in-process, which means
  nothing here: a hook is a fresh process per invocation. The honest equivalent
  is a marker file under the same `/run` spool `hotline.stops` already uses, so
  the backoff survives between invocations and is cleared by a reboot.
* **The statusline is wrapped, never replaced.** `statusLine` is a single
  per-session slot (§9.7), so consuming it means becoming whatever was there.
  The wrapper runs the previous command with the same stdin, passes its stdout
  through byte for byte, and keeps its exit code. His terminal has to look
  identical afterwards.

Registration is additive and idempotent in the same shape `hotline.stops` and
`hotline.guard` already use: read the settings file, append if absent, never
clobber a hook that is already there.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .endpoint import local_url

HOOK_PATH = "/api/v1/hook"
DEFAULT_URL = local_url(HOOK_PATH)
"""Derived, never written out again. `endpoint.py` explains why: this constant
and the daemon's bind address disagreed silently for as long as both existed."""

HOOK_EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop")
"""Which events get a nudge.

`PreToolUse` is what makes the map live: the assistant's `tool_use` record is
already in the transcript when the tool is *about* to run, so nudging before
means the phone shows "running Bash" while it runs rather than after it
finished.

`PostToolUse` is here for exactly one field. It carries `duration_ms`, which is
the only place a per-tool duration exists anywhere -- the transcript's own
`durationMs` records are whole turns, and there is nothing per-call in the file
at all. It deliberately does **not** make the daemon re-read the transcript;
that would double every read to fill in a column.

`SubagentStop` is deliberately absent -- a subagent finishing does not end the
parent's turn, and treating it as one would close the phase early."""

BACKOFF_SECONDS = 30.0
TIMEOUT_SECONDS = 0.3

SCRIPT = '''#!/usr/bin/env python3
"""hotline-ios map hook -- nudges the daemon to re-read this session's transcript.

Installed by `hotline_ios.hooks.install`. Fire-and-forget: it never blocks, never
fails a tool call, and always exits 0. See hotline_ios/hooks.py for why.
"""
import json, os, sys, time, urllib.request

URL = {url!r}
API_KEY = {api_key!r}
TIMEOUT = {timeout!r}
BACKOFF = {backoff!r}
KIND = {kind!r}


def spool():
    root = os.environ.get("HOTLINE_RUNTIME") or os.path.join(
        os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid(), "hotline")
    return os.path.join(root, "ios-hook-backoff")


def backing_off(path):
    try:
        return (time.time() - float(open(path).read())) < BACKOFF
    except Exception:
        return False


def note_failure(path):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(str(time.time()))
    except Exception:
        pass


def send(payload):
    """Returns the daemon's answer, or None. Never raises."""
    marker = spool()
    if backing_off(marker):
        return None
    headers = {{"Content-Type": "application/json"}}
    if API_KEY:
        headers["X-Hotline-Key"] = API_KEY
    request = urllib.request.Request(
        URL, data=json.dumps(payload).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            body = response.read()
        try:
            os.unlink(marker)
        except OSError:
            pass
        return body
    except Exception:
        note_failure(marker)
        return None
{body}
'''

NUDGE_BODY = '''

try:
    payload = json.load(sys.stdin)
    nudge = {
        "session_id": payload.get("session_id"),
        "cwd": payload.get("cwd"),
        "transcript_path": payload.get("transcript_path"),
        "event": payload.get("hook_event_name") or KIND,
    }
    # The two extra fields PostToolUse carries and nothing else does. Still no
    # model output and no tool arguments on the wire: an id and a number.
    if nudge["event"] == "PostToolUse":
        nudge["tool_use_id"] = payload.get("tool_use_id")
        nudge["duration_ms"] = payload.get("duration_ms")
    send(nudge)
except Exception:
    pass
sys.exit(0)
'''

STATUSLINE_BODY = '''

WRAPPED = {wrapped!r}


def passthrough(raw):
    """Run whatever statusLine was configured before and hand its output on.

    Byte for byte, including the exit code. `statusLine` is one slot per session
    and consuming it means becoming what was there; his terminal has to look
    identical afterwards.
    """
    if not WRAPPED:
        return 0
    import subprocess
    try:
        done = subprocess.run(WRAPPED, shell=True, input=raw, capture_output=True,
                              timeout=5)
    except Exception:
        return 0
    sys.stdout.buffer.write(done.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(done.stderr)
    return done.returncode


raw = b""
code = 0
try:
    raw = sys.stdin.buffer.read()
    code = passthrough(raw)
except Exception:
    pass

try:
    payload = json.loads(raw)
    used = (payload.get("context_window") or {{}}).get("used_percentage")
    report = {{
        "session_id": payload.get("session_id"),
        "cwd": payload.get("cwd"),
        "transcript_path": payload.get("transcript_path"),
        "event": "StatusLine",
    }}
    # `used_percentage` is null before a session's first turn (§9.7), and the
    # field is simply left out then -- reporting it as zero would draw an empty
    # gauge on a session whose usage is unknown.
    #
    # The report itself is still sent. That is what tells the daemon this
    # session HAS a statusline wrapper, which is a different fact from how full
    # its context is: without it, "no first turn yet" and "no wrapper here" both
    # arrive as silence, and the app has to render them differently.
    if isinstance(used, (int, float)):
        report["context_used_percentage"] = used
    send(report)
except Exception:
    pass
sys.exit(code)
'''


def _render(*, url: str, api_key: str, kind: str, body: str) -> str:
    return SCRIPT.format(
        url=url, api_key=api_key, timeout=TIMEOUT_SECONDS, backoff=BACKOFF_SECONDS,
        kind=kind, body=body,
    )


def nudge_script(*, url: str = DEFAULT_URL, api_key: str = "") -> str:
    return _render(url=url, api_key=api_key, kind="", body=NUDGE_BODY)


def statusline_script(*, url: str = DEFAULT_URL, api_key: str = "", wrapped: str = "") -> str:
    return _render(
        url=url, api_key=api_key, kind="StatusLine",
        body=STATUSLINE_BODY.format(wrapped=wrapped),
    )


def _load(path: Path) -> dict[str, Any]:
    try:
        loaded = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def _register(settings: dict[str, Any], event: str, command: str) -> bool:
    """Add one hook entry if it is not already there. Additive, never clobbering.

    He may well have his own hooks on these events -- `hotline-stop.py` and
    `hotline-guard.py` are already on Stop and PreToolUse -- and replacing them
    would be unforgivable.
    """
    entries = settings.setdefault("hooks", {}).setdefault(event, [])
    for entry in entries:
        for hook in entry.get("hooks", []):
            if hook.get("command") == command:
                return False
    entries.append(
        {"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 5}]}
    )
    return True


def existing_statusline(settings: dict[str, Any], ours: str) -> str:
    """Whatever statusLine command was configured, or "" for none.

    Returns "" when the configured command is already ours, so that a second
    install does not wrap the wrapper and run it twice.
    """
    configured = settings.get("statusLine")
    if isinstance(configured, str):
        command = configured
    elif isinstance(configured, dict):
        command = str(configured.get("command") or "")
    else:
        return ""
    return "" if ours and ours in command else command


def install(
    *,
    settings_file: str | os.PathLike[str] | None = None,
    scripts_dir: str | os.PathLike[str] | None = None,
    url: str = DEFAULT_URL,
    api_key: str = "",
    statusline: bool = True,
) -> dict[str, Any]:
    """Write both scripts and register them. Idempotent; reports what it changed.

    `settings_file` defaults to `~/.claude/settings.json` and `scripts_dir` to
    `~/.claude/hooks`. Both are parameters so this can be pointed at a
    directory-scoped `.claude/settings.json` in a throwaway project, which is
    how it gets tested against a real session without touching the config every
    agent on the box runs through.
    """
    from hotline.config import claude_home, settings_path

    settings_target = Path(settings_file) if settings_file else Path(settings_path())
    directory = Path(scripts_dir) if scripts_dir else Path(claude_home()) / "hooks"
    directory.mkdir(parents=True, exist_ok=True)
    settings_target.parent.mkdir(parents=True, exist_ok=True)

    settings = _load(settings_target)
    changed: list[str] = []

    nudge = directory / "hotline-ios-map.py"
    nudge.write_text(nudge_script(url=url, api_key=api_key))
    nudge.chmod(0o755)
    for event in HOOK_EVENTS:
        if _register(settings, event, str(nudge)):
            changed.append(event)

    line = directory / "hotline-ios-statusline.py"
    wrapped = ""
    if statusline:
        wrapped = existing_statusline(settings, str(line))
        line.write_text(statusline_script(url=url, api_key=api_key, wrapped=wrapped))
        line.chmod(0o755)
        configured = settings.get("statusLine")
        command = configured.get("command") if isinstance(configured, dict) else configured
        if command != str(line):
            settings["statusLine"] = {"type": "command", "command": str(line)}
            changed.append("statusLine")

    if changed:
        settings_target.write_text(json.dumps(settings, indent=2) + "\n")
    return {
        "settings": str(settings_target),
        "hook": str(nudge),
        "statusline": str(line) if statusline else None,
        "wrapped": wrapped,
        "changed": changed,
    }


def main(argv: Any = None) -> int:
    """`hotline-ios-hooks` -- install the map's hook and statusline wrapper.

    Defaults to the global `~/.claude/settings.json`. `--settings` and
    `--hooks-dir` point it at a directory-scoped file instead, which is how it
    is exercised against a real session without touching the configuration
    every agent on this box runs through.
    """
    import argparse

    parser = argparse.ArgumentParser(prog="hotline-ios-hooks")
    parser.add_argument("--url", default=os.environ.get("HOTLINE_IOS_HOOK_URL", DEFAULT_URL))
    parser.add_argument("--api-key", default=os.environ.get("HOTLINE_API_KEY", ""))
    parser.add_argument("--settings", default=None)
    parser.add_argument("--hooks-dir", default=None)
    parser.add_argument("--no-statusline", action="store_true",
                        help="skip the statusLine wrapper; contextUsed then stays null")
    parser.add_argument("--dry-run", action="store_true",
                        help="print what would be installed and change nothing")
    args = parser.parse_args(argv)

    if args.dry_run:
        from hotline.config import claude_home, settings_path

        target = args.settings or str(settings_path())
        settings = _load(Path(target))
        line = Path(args.hooks_dir or (Path(claude_home()) / "hooks")) / "hotline-ios-statusline.py"
        print(json.dumps({
            "settings": target,
            "would_register": list(HOOK_EVENTS),
            "would_wrap_statusline": existing_statusline(settings, str(line)) or None,
            "url": args.url,
        }, indent=2))
        return 0

    result = install(
        settings_file=args.settings, scripts_dir=args.hooks_dir,
        url=args.url, api_key=args.api_key, statusline=not args.no_statusline,
    )
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
