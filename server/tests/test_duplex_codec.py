"""The duplex engine path at the line's real rate, with a fake pp-stream.

The fake echoes every 24 kHz frame it is given and records what it heard, so
two things can be measured without a GPU: what the MODEL is fed (was it
wideband?), and what comes back to his phone after the 24 kHz round trip.
`_transcribe` is stubbed: the real one loads Whisper onto the GPU.
"""

from __future__ import annotations

import socket
import sys
import threading
import time

import numpy as np
import pytest

from hotline_ios import duplexcall
from hotline_ios.media import codec, pcm, rtp, srtp

needs_opus = pytest.mark.skipif(codec.opus_library() is None, reason="no libopus")

FAKE_PP = r'''
import sys, numpy as np
out = open(sys.argv[1], "wb")
sys.stderr.write("READY\n"); sys.stderr.flush()
need = 1920 * 4
while True:
    buf = b""
    while len(buf) < need:
        chunk = sys.stdin.buffer.read(need - len(buf))
        if not chunk:
            sys.exit(0)
        buf += chunk
    out.write(buf); out.flush()
    sys.stdout.buffer.write(buf); sys.stdout.buffer.flush()
'''


def band_db(audio, rate, freq, ref=1000.0):
    spectrum = np.abs(np.fft.rfft(audio * np.hanning(audio.size))) ** 2
    freqs = np.fft.rfftfreq(audio.size, 1 / rate)

    def at(f):
        return float(spectrum[(freqs > f - 60) & (freqs < f + 60)].sum()) + 1e-20

    return 10 * np.log10(at(freq) / at(ref))


def tones(seconds, rate):
    t = np.arange(int(seconds * rate)) / rate
    return sum(0.12 * np.sin(2 * np.pi * f * t) for f in (1000, 6000, 10000)).astype(np.float32)


def run_call(tmp_path, monkeypatch, choice: codec.Choice):
    script = tmp_path / "fake_pp.py"
    script.write_text(FAKE_PP)
    heard_by_model = tmp_path / "model_in.f32"
    monkeypatch.setenv("HOTLINE_IOS_DUPLEX_CMD", sys.executable)
    monkeypatch.setattr(duplexcall, "DuplexEngine", _engine_with_args(script, heard_by_model))
    monkeypatch.setattr(duplexcall.DuplexCall, "_transcribe", lambda self, st, rate=8000: [])
    began = time.monotonic()
    dc = duplexcall.DuplexCall(note=lambda *a: None, deliver=lambda s: None,
                               hung_up=lambda: time.monotonic() - began > 4.0,
                               record_dir=tmp_path)
    assert dc.wait_ready(10)

    phone = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    phone.bind(("127.0.0.1", 0))
    ours = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ours.bind(("127.0.0.1", 0))
    pkey, psalt = srtp.new_key_salt()
    okey, osalt = srtp.new_key_salt()
    port = phone.getsockname()[1]
    attrs = "a=rtpmap:96 opus/48000/2\r\n" if choice.name == "opus" else ""
    reply = ("SIP/2.0 200 OK\r\n\r\nv=0\r\nc=IN IP4 127.0.0.1\r\n"
             f"m=audio {port} RTP/SAVP {choice.pt}\r\n{srtp.crypto_line(pkey, psalt)}\r\n{attrs}")
    peer = codec.open_codec(choice)
    received: list[bytes] = []

    def phone_side():
        send = srtp.SrtpSession(pkey, psalt)
        recv = srtp.SrtpSession(okey, osalt)
        wire = pcm.from_model(tones(2.5, 48000), 48000, peer.rate)
        n = peer.frame_samples * 2
        phone.settimeout(0.001)
        for seq, i in enumerate(range(0, len(wire) - n + 1, n)):
            pkt = rtp.build_packet(seq, seq * peer.ts_step, 0xFEED, peer.encode(wire[i:i + n]), peer.pt)
            phone.sendto(send.protect(pkt), ours.getsockname())
            deadline = time.monotonic() + 0.02
            while time.monotonic() < deadline:
                try:
                    data, _ = phone.recvfrom(4096)
                except (TimeoutError, BlockingIOError):
                    continue
                parsed = rtp.parse_packet(recv.unprotect(data))
                if parsed is not None:
                    received.append(peer.decode(parsed[3]))

    talker = threading.Thread(target=phone_side, daemon=True)
    talker.start()
    dc(reply, ours, okey, osalt)
    talker.join(5)
    model_in = np.fromfile(heard_by_model, dtype="<f4")
    back = np.frombuffer(b"".join(received), dtype="<i2").astype(np.float32) / 32768.0
    return dc, model_in, back, peer.rate


def _engine_with_args(script, out):
    real = duplexcall.DuplexEngine

    def make(cmd, **kw):
        return real([sys.executable, str(script), str(out)], **kw)

    return make


@needs_opus
def test_on_opus_the_model_hears_and_returns_the_top_end(tmp_path, monkeypatch):
    dc, model_in, back, rate = run_call(tmp_path, monkeypatch, codec.Choice("opus", 96, 48000))
    assert dc.engine.wire_rate == 48000
    assert dc.stats["codec"].startswith("Opus")
    tail = model_in[24000:]     # past the start; 24 kHz
    assert tail.size > 24000
    assert band_db(tail, 24000, 6000) > -6
    assert band_db(tail, 24000, 10000) > -6
    echoed = back[rate:]
    assert band_db(echoed, rate, 10000) > -6


def test_on_g711_the_model_gets_the_narrow_line_it_always_did(tmp_path, monkeypatch):
    dc, model_in, _back, _ = run_call(tmp_path, monkeypatch, codec.PCMU)
    assert dc.engine.wire_rate == 8000
    assert band_db(model_in[24000:], 24000, 6000) < -30
