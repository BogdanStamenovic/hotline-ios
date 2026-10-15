"""Listens to HIS side of a duplex call and decides when a question needs Claude.

energy endpoint (500 ms of silence ends an utterance) -> faster-whisper small on the CPU
(the GPU belongs to PersonaPlex) -> Claude Haiku over the API: LOOKUP or NONE.

Runs on its own thread with a queue, so a slow transcription never stalls the 20 ms media
loop that feeds it. Times are call time: seconds of his audio fed so far.

Measured in duplex-lab (2026-10-16, G.711): his question end -> decision median ~2.2 s
(0.5 endpoint + 1.1 ASR + 0.6 Haiku); 0 false lookups on 15 utterances of his real voice
and 0/24 on scripted non-questions; 12/12 lookups caught. Without the "fragments are NONE"
rule his real voice drew 3/15 false lookups.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from . import claude_api

log = logging.getLogger(__name__)

MODEL = "claude-haiku-4-5"
DECIDE_SYSTEM = (
    "You watch a live phone call between Bogdan and his voice assistant. The assistant knows nothing about Bogdan's own "
    "computers, servers, builds, tests, files, projects, accounts or calendar; Claude, an agent on his workstation, can look "
    "those up. Each message is one thing speech recognition heard Bogdan say. Reply LOOKUP only if he clearly and completely "
    "asks for that kind of information about HIS OWN things. Reply NONE for everything else, including greetings, small talk, "
    "opinions, general knowledge, weather, prices, requests to repeat, goodbyes, and any fragment, half sentence, garbled or "
    "unclear recognition (when in doubt, NONE). Reply with the single word only.")


@dataclass
class Utterance:
    text: str
    t_end: float        # call time his speech ended
    t_decided: float    # call time the decision was made
    lookup: bool


class CallWatch:
    RATE = 16000

    def __init__(self, on_lookup: Callable[[Utterance], None], thr: float = 0.012, hang: float = 0.5,
                 min_speech: float = 0.3, model: str = "small") -> None:
        self.on_lookup = on_lookup
        self.thr, self.hang, self.min_speech, self.model_name = thr, hang, min_speech, model
        self.utterances: list[Utterance] = []
        self._q: queue.Queue = queue.Queue()
        self._whisper = None
        self._resamplers: dict[int, object] = {}
        self._carry = np.zeros(0, np.float32)
        self._t = 0.0
        self._buf: list[np.ndarray] = []
        self._in_speech = False
        self._silence = self._speech = 0.0
        self._thread: threading.Thread | None = None

    # -- ring time --------------------------------------------------------------------
    def warm(self) -> None:
        from faster_whisper import WhisperModel

        self._whisper = WhisperModel(self.model_name, device="cpu", compute_type="int8", cpu_threads=4)
        self._whisper.transcribe(np.zeros(self.RATE, np.float32), language="en")
        self._decide("hello")   # TCP/TLS + first-request latency paid now, not on his first question

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True, name="callwatch")
        self._thread.start()

    def stop(self) -> None:
        self._q.put(None)
        if self._thread:
            self._thread.join(5)
        self._whisper = None

    # -- the media loop calls this every 20 ms ------------------------------------------
    def feed(self, pcm16: bytes, rate: int) -> None:
        self._q.put((pcm16, rate))

    # -- worker -------------------------------------------------------------------------
    def _decide(self, text: str) -> bool:
        t0 = time.monotonic()
        r = claude_api.client().messages.create(model=MODEL, max_tokens=5, system=DECIDE_SYSTEM,
                                                messages=[{"role": "user", "content": f'Bogdan said: "{text}"'}])
        claude_api.log_usage("decide", MODEL, r.usage, time.monotonic() - t0)
        out = "".join(b.text for b in r.content if b.type == "text").strip().upper()
        return out.startswith("LOOKUP")

    def _run(self) -> None:
        import soxr

        F = int(self.RATE * 0.02)
        while True:
            item = self._q.get()
            if item is None:
                return
            pcm16, rate = item
            x = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
            if rate != self.RATE:
                rs = self._resamplers.setdefault(rate, soxr.ResampleStream(rate, self.RATE, 1, dtype="float32"))
                x = rs.resample_chunk(x)
            # soxr's output per chunk is not a whole number of frames (a 960-sample Opus
            # chunk at 48 kHz comes out as 0, 490, 0, 489 ... samples): the remainder is carried, never
            # dropped. Dropping it lost 35% of his audio on the 01:34 Opus call.
            x = np.concatenate([self._carry, x])
            whole = x.size - x.size % F
            self._carry = x[whole:]
            for i in range(0, whole, F):
                f = x[i:i + F]
                self._t += 0.02
                loud = float(np.sqrt(np.mean(f ** 2))) > self.thr
                if loud:
                    if not self._in_speech:
                        self._in_speech, self._speech, self._buf = True, 0.0, []
                    self._silence = 0.0
                    self._speech += 0.02
                elif self._in_speech:
                    self._silence += 0.02
                if self._in_speech:
                    self._buf.append(f)
                    if self._silence >= self.hang:
                        self._in_speech = False
                        if self._speech >= self.min_speech:
                            self._utterance(np.concatenate(self._buf), self._t - self.hang)

    def _utterance(self, audio: np.ndarray, t_end: float) -> None:
        try:
            segs, _ = self._whisper.transcribe(audio, language="en", beam_size=1, vad_filter=False,
                                               condition_on_previous_text=False)
            text = " ".join(s.text.strip() for s in segs).strip()
            if not text:
                return
            lookup = self._decide(text)
        except Exception:
            log.exception("watcher failed on an utterance")
            return
        u = Utterance(text, round(t_end, 2), round(self._t, 2), lookup)
        self.utterances.append(u)
        log.info("watch: %r -> %s", text, "LOOKUP" if lookup else "NONE")
        if lookup:
            try:
                self.on_lookup(u)
            except Exception:
                log.exception("lookup handler failed")
