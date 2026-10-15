"""Mid-call lookups: labels, answerer protocol, sandbox, watcher endpointing, context file.

No GPU, no network: the Claude client, Whisper and the decision are faked. The sandbox
tests run the real bwrap when it is installed, because the sandbox IS the security
boundary and a mocked one proves nothing.
"""
from __future__ import annotations

import os
import shutil
import types
from pathlib import Path

import numpy as np
import pytest

from hotline_ios.lookup import answerer as ans_mod
from hotline_ios.lookup import labels, sandbox
from hotline_ios.lookup.answerer import ABSTAIN_LINE, Answerer, is_abstention, spoken
from hotline_ios.lookup.callwatch import CallWatch


# ---- labels -----------------------------------------------------------------------
def test_speech_before_the_hold_is_unverified_and_after_the_injection_is_from_claude():
    lk = labels.Lookup("disk?", t_question_end=10.0, t_hold=12.0, t_injected=15.0)
    turns = [(9.0, "claude", "Hi."), (10.5, "claude", "It's 40 percent."), (12.5, "claude", "Let me check."),
             (15.2, "claude", "85 percent full."), (16.0, "claude", "11 gigs free."), (20.0, "you", "thanks"),
             (21.0, "claude", "Anything else?")]
    out = labelled_turns = labels.labelled_turns(turns, [lk])
    texts = [t for _, _, t in out]
    assert texts[0] == "Hi."
    assert texts[1] == f"[{labels.UNVERIFIED}] It's 40 percent."
    assert texts[2] == "Let me check."                       # the filler: neither
    assert texts[3] == f"[{labels.FROM_CLAUDE}] 85 percent full. 11 gigs free."   # merged
    assert texts[5] == "Anything else?"                      # after he spoke again: plain
    assert labelled_turns[4][1] == "you"


def test_no_lookups_means_plain_merged_turns():
    out = labels.labelled_turns([(1.0, "claude", "a"), (2.0, "claude", "b"), (3.0, "you", "c")], [])
    assert out == [(1.0, "claude", "a b"), (3.0, "you", "c")]


# ---- answerer -----------------------------------------------------------------------
def test_spoken_strips_markdown_and_narration_and_keeps_one_sentence():
    assert spoken("Perfect! **The disk** is 85% full. 11 GB free. Also more.") == "The disk is 85% full."


@pytest.mark.parametrize("text,want", [("ABSTAIN", True), ("abstain.", True), ("", True),
                                       ("Let me look at what information I have.", True),
                                       ("I don't have that information. I'll pass the question on.", True),
                                       ("There is no information about a dentist appointment.", True),
                                       ("You have 2 gigabytes free, and I don't have the swap figure.", False),  # a partial answer is an answer
                                       ("The build took 14 minutes.", False)])
def test_abstention_detection(text, want):
    assert is_abstention(text) is want


class _FakeAPI:
    """Replays scripted responses; records what was sent."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.sent = []
        self.messages = self

    def create(self, **kw):
        self.sent.append(kw)
        return self.responses.pop(0)


def _resp(text=None, tool=None):
    content = []
    if text is not None:
        content.append(types.SimpleNamespace(type="text", text=text))
    if tool is not None:
        content.append(types.SimpleNamespace(type="tool_use", id="t1", name="bash", input={"command": tool}))
    usage = types.SimpleNamespace(input_tokens=10, output_tokens=2, cache_read_input_tokens=0, cache_creation_input_tokens=0)
    return types.SimpleNamespace(content=content, usage=usage, stop_reason="tool_use" if tool else "end_turn")


def test_an_abstention_is_passed_on_never_spoken_as_a_fact(monkeypatch, tmp_path):
    api = _FakeAPI([_resp("ABSTAIN")])
    monkeypatch.setattr(ans_mod.claude_api, "client", lambda: api)
    monkeypatch.setattr(ans_mod.claude_api, "USAGE_LOG", tmp_path / "u.jsonl")
    a = Answerer("CONTEXT", bash=False)
    assert a.ask("When is my dentist appointment?") == (ABSTAIN_LINE, True)
    assert a.passed_on == ["When is my dentist appointment?"]
    # the context is one cached system block
    assert api.sent[0]["system"][0]["cache_control"] == {"type": "ephemeral"}


def test_a_tool_round_trip_runs_in_the_sandbox_and_caps_commands(monkeypatch, tmp_path):
    api = _FakeAPI([_resp(tool="df -h /"), _resp(tool="free"), _resp(tool="uptime"), _resp(tool="ls"),
                    _resp("About 85 percent full.")])
    ran = []
    monkeypatch.setattr(ans_mod.claude_api, "client", lambda: api)
    monkeypatch.setattr(ans_mod.claude_api, "USAGE_LOG", tmp_path / "u.jsonl")
    monkeypatch.setattr(ans_mod.sandbox, "run", lambda c: ran.append(c) or "[exit 0]")
    a = Answerer("CONTEXT")
    assert a.ask("how full is the disk") == ("About 85 percent full.", False)
    assert ran == ["df -h /", "free", "uptime"]          # the 4th command is refused
    assert "limit of 3" in str(api.sent[-1]["messages"][-1]["content"][0]["content"])


# ---- sandbox (real bwrap) ------------------------------------------------------------
def test_sandbox_argv_has_the_isolation_flags():
    a = sandbox.argv("true")
    for flag in ("--clearenv", "--unshare-net", "--unshare-pid", "--die-with-parent", "--new-session"):
        assert flag in a
    assert a[a.index("--tmpfs") + 1] == str(Path.home())           # $HOME starts empty
    assert "/run" in [a[i + 1] for i, x in enumerate(a) if x == "--tmpfs"]


needs_bwrap = pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap not installed")


@needs_bwrap
def test_sandbox_blocks_writes_network_and_inherited_env(tmp_path, monkeypatch):
    monkeypatch.setenv("HOTLINE_API_KEY", "should-never-be-visible")
    out = sandbox.run("env; touch ~/data/.sandbox-probe 2>&1; getent hosts example.com || echo NO-DNS")
    assert "should-never-be-visible" not in out
    assert "Read-only file system" in out or "No such file" in out
    assert "NO-DNS" in out
    assert not (Path.home() / "data/.sandbox-probe").exists()


@needs_bwrap
def test_sandbox_hides_home_outside_data():
    out = sandbox.run("ls -a ~ ; cat ~/.ssh/id_ed25519 2>&1 | head -1")
    assert ".ssh" not in out.split("cat")[0]
    assert "BEGIN" not in out


@needs_bwrap
def test_sandbox_times_out():
    assert "timed out" in sandbox.run("sleep 30")


# ---- watcher ------------------------------------------------------------------------
def test_watcher_endpoints_one_utterance_and_calls_back_on_lookup(monkeypatch):
    seen = []
    w = CallWatch(on_lookup=seen.append)
    w._whisper = types.SimpleNamespace(transcribe=lambda audio, **kw: ([types.SimpleNamespace(text="how full is the disk")], None))
    monkeypatch.setattr(w, "_decide", lambda text: True)
    rate = 16000
    speech = (0.3 * np.sin(np.arange(int(1.0 * rate)) / 5)).astype(np.float32)
    x = np.concatenate([np.zeros(rate // 2, np.float32), speech, np.zeros(rate, np.float32)])
    w.start()
    for i in range(0, x.size, 320):
        w.feed((x[i:i + 320] * 32767).astype("<i2").tobytes(), rate)
    w.stop()
    assert len(seen) == 1 and seen[0].lookup
    assert 1.4 <= seen[0].t_end <= 1.6          # speech ended at 1.5 s of call time


def test_watcher_ignores_quiet_line_noise(monkeypatch):
    seen = []
    w = CallWatch(on_lookup=seen.append)
    monkeypatch.setattr(w, "_decide", lambda text: pytest.fail("decided on noise"))
    w.start()
    noise = (0.002 * np.random.default_rng(0).standard_normal(16000 * 2)).astype(np.float32)
    for i in range(0, noise.size, 320):
        w.feed((noise[i:i + 320] * 32767).astype("<i2").tobytes(), 16000)
    w.stop()
    assert seen == []


# ---- context file ---------------------------------------------------------------------
def test_context_file_rules(tmp_path):
    from hotline_ios.daemon import CONTEXT_FILE_MAX_BYTES, _read_context_file

    assert _read_context_file("") == (None, "")
    assert "absolute" in _read_context_file("ctx.md")[1]
    assert "cannot read" in _read_context_file(str(tmp_path / "missing.md"))[1]
    big = tmp_path / "big.md"
    big.write_bytes(b"x" * (CONTEXT_FILE_MAX_BYTES + 1))
    assert "limit" in _read_context_file(str(big))[1]
    ok = tmp_path / "ctx.md"
    ok.write_text("## FOR THIS CALL\n- the build failed\n")
    assert _read_context_file(str(ok)) == ("## FOR THIS CALL\n- the build failed\n", "")


def test_engine_command_is_refused_before_start():
    from hotline_ios.media.duplex import DuplexEngine

    assert DuplexEngine(["true"]).command("HOLD") is False
    assert not os.environ.get("NO_SUCH_THING")
