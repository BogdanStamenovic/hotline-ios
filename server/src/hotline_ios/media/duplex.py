"""Full-duplex bridge between a telephone leg and a streaming speech model process.

The leg's rate is the negotiated codec's: 48 kHz on Opus, 8 kHz on G.711, set by
`use_wire_rate` once the call is answered. On G.711 the model hears nothing above
4 kHz -- which is how both engines' first test calls went.

No VAD, no turn gate: caller audio is pushed continuously and the model's audio is
pulled continuously. The engine process (pp-stream, PersonaPlex on Mimi 24 kHz)
takes float32 frames on stdin and writes float32 audio on stdout, one 80 ms frame
out per frame in, with events on stderr. EngineSpec keeps the rates as data so a
second engine would be configuration; Nemotron VoiceChat was one, and was cut
(duplex-lab/SHELVED.md).

The caller side must keep pushing -- silence included -- or the model stops
hearing time pass.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass

import numpy as np
import soxr

WIRE_RATE = 8_000   # until use_wire_rate() says otherwise


@dataclass(frozen=True)
class EngineSpec:
    name: str
    in_rate: int
    in_frame: int      # samples per 80 ms input frame at in_rate
    out_rate: int
    prime_s: float     # playout buffer before the first sample goes out


PERSONAPLEX = EngineSpec("personaplex", 24_000, 1920, 24_000, 0.12)
# Kept for callers written against the PersonaPlex-only version.
MODEL_RATE = PERSONAPLEX.in_rate
FRAME_24K = PERSONAPLEX.in_frame


class DuplexEngine:
    def __init__(self, cmd: list[str], env: dict[str, str] | None = None, log=None,
                 spec: EngineSpec = PERSONAPLEX) -> None:
        self.cmd = cmd
        self.spec = spec
        self.env = {**os.environ, **(env or {})}
        self.log = log or (lambda line: None)
        self.text: list[tuple[int, str]] = []  # (frame index, piece)
        self.stats: list[tuple[int, float, float]] = []  # pp-stream's STAT lines
        self.stat_lines: list[str] = []
        self.ready = threading.Event()
        self.dead = threading.Event()
        self.wire_rate = WIRE_RATE
        self._up = soxr.ResampleStream(WIRE_RATE, spec.in_rate, 1, dtype="float32")
        self._down = soxr.ResampleStream(spec.out_rate, WIRE_RATE, 1, dtype="float32")
        self._in = np.zeros(0, dtype=np.float32)
        self._out8: deque[np.ndarray] = deque()
        self._out8_len = 0
        self._lock = threading.Lock()
        self.frames_out = 0
        self.underruns = 0
        self._primed = False
        self.prime = int(WIRE_RATE * spec.prime_s)
        self.proc: subprocess.Popen | None = None
        self._ctl_w: int | None = None
        # pp-stream2's control events: ("INJECT"|"INJECTED"|"HOLD"|..., model frame index)
        self.events: list[tuple[str, int]] = []

    def use_wire_rate(self, rate: int) -> None:
        """Set the telephone leg's rate once the call is answered.

        The engine is built when the phone starts ringing, before the answer
        says which codec won, so the resamplers are rebuilt here, before the
        first push. Anything the model already produced at the old rate is
        dropped: it was never going to be played to anyone.
        """
        if rate == self.wire_rate:
            return
        with self._lock:
            self.wire_rate = rate
            self._up = soxr.ResampleStream(rate, self.spec.in_rate, 1, dtype="float32")
            self._down = soxr.ResampleStream(self.spec.out_rate, rate, 1, dtype="float32")
            self.prime = int(rate * self.spec.prime_s)
            self._in = np.zeros(0, dtype=np.float32)
            self._out8.clear()
            self._out8_len = 0

    def start(self, timeout: float = 120.0) -> float:
        t0 = time.monotonic()
        # Commands (HOLD, INJECTRAW ...) go to the engine on fd 3, one per line. A child
        # that never reads fd 3 (plain pp-stream) is unaffected.
        ctl_r, self._ctl_w = os.pipe()

        def child() -> None:
            os.dup2(ctl_r, 3)

        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=self.env, bufsize=0,
                                     # 3 as well: close_fds runs after preexec_fn
                                     pass_fds=(ctl_r, 3), preexec_fn=child)
        os.close(ctl_r)
        threading.Thread(target=self._stderr_loop, daemon=True).start()
        threading.Thread(target=self._stdout_loop, daemon=True).start()
        if not self.ready.wait(timeout) or self.dead.is_set():
            self.close()
            raise RuntimeError(f"{self.spec.name} did not become ready")
        return time.monotonic() - t0

    def _stderr_loop(self) -> None:
        assert self.proc and self.proc.stderr
        for raw in self.proc.stderr:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("READY"):
                self.ready.set()
            elif line.startswith("TXT "):
                _, idx, *rest = line.split(" ", 2)
                self.text.append((int(idx), rest[0] if rest else ""))
            elif line.split(" ", 1)[0] in ("INJECT", "INJECTED", "HOLD", "MUTE", "RELEASE"):
                parts = line.split()
                if len(parts) > 1 and parts[1].isdigit():
                    self.events.append((parts[0], int(parts[1])))
            elif line.startswith("STAT "):
                self.stat_lines.append(line)
                parts = line.split()
                if len(parts) == 4 and parts[1].isdigit():
                    self.stats.append((int(parts[1]), float(parts[2]), float(parts[3])))
            self.log(line)
        self.dead.set()
        self.ready.set()

    def _stdout_loop(self) -> None:
        assert self.proc and self.proc.stdout
        pending = b""
        while True:
            chunk = self.proc.stdout.read(16384)
            if not chunk:
                self.dead.set()
                return
            pending += chunk
            usable = len(pending) - len(pending) % 4
            if not usable:
                continue
            block, pending = pending[:usable], pending[usable:]
            with self._lock:
                out = self._down.resample_chunk(np.frombuffer(block, dtype="<f4"))
                self._out8.append(out)
                self._out8_len += out.size
                self.frames_out += 1

    def push(self, pcm16: bytes) -> None:
        """Caller audio at `wire_rate`, mono LE int16, any chunk size."""
        if self.dead.is_set() or not self.proc or not self.proc.stdin:
            return
        x = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        self._in = np.concatenate([self._in, self._up.resample_chunk(x)])
        n = self.spec.in_frame
        while self._in.size >= n:
            frame, self._in = self._in[:n], self._in[n:]
            try:
                self.proc.stdin.write(frame.astype("<f4").tobytes())
            except (BrokenPipeError, OSError):
                self.dead.set()
                return

    def _take(self, q: deque, samples: int) -> tuple[np.ndarray, int]:
        got: list[np.ndarray] = []
        n = 0
        while q and n < samples:
            head = q[0]
            take = min(samples - n, head.size)
            got.append(head[:take])
            n += take
            if take == head.size:
                q.popleft()
            else:
                q[0] = head[take:]
        if n < samples:
            got.append(np.zeros(samples - n, dtype=np.float32))
        return np.concatenate(got), n

    def pull(self, samples: int) -> bytes:
        """Model audio at `wire_rate`, mono LE int16; zero-padded when the model is behind."""
        with self._lock:
            if not self._primed and self._out8_len >= self.prime:
                self._primed = True
            if not self._primed:
                x = np.zeros(samples, dtype=np.float32)
            else:
                if self._out8_len < samples:
                    self.underruns += 1
                    self._primed = False
                x, n = self._take(self._out8, samples)
                self._out8_len -= n
        return (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()

    def command(self, line: str) -> bool:
        """Send one control line to the engine (pp-stream2: HOLD, MUTE, RELEASE, INJECT, INJECTRAW)."""
        if self._ctl_w is None or "\n" in line:
            return False
        try:
            os.write(self._ctl_w, (line + "\n").encode())
            return True
        except OSError:
            return False

    def buffered(self) -> int:
        with self._lock:
            return self._out8_len

    def close(self) -> None:
        if self.proc:
            try:
                if self.proc.stdin:
                    self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self._ctl_w is not None:
            try:
                os.close(self._ctl_w)
            except OSError:
                pass
            self._ctl_w = None
