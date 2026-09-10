# The units in this directory, and how they relate to the live ones

`hotline-iosd.service` here is **not** what runs. The live unit is
`~/.config/systemd/user/hotline-ios.service` — different name, different
content — and the two have drifted:

| | tracked `hotline-iosd.service` | live `hotline-ios.service` |
|---|---|---|
| ring transports | `telegram,sip` | `sip` |
| `.env` | `EnvironmentFile=` | loaded by `daemon.py` at startup |
| `KillMode=process` | present, commented "not optional" | **absent** |
| `StartLimitIntervalSec=0` | absent | present |

Believe the live one. It is what has been restarted, rung and debugged. The
`KillMode=process` note warns that restarting this unit could take the tmux
server — and every live Claude session — down with it; two restarts on
2026-09-10 did no such thing, so either the hazard is gone or it never applied
to this unit. Nobody has reconciled the two files, and this note exists so the
next reader does not edit the one that is not running.

## `wait-for-cvoiced` and the drop-in

`hotline-ios.service` starts one second **before** `cvoiced.service` on a cold
boot (measured 15:03:57 vs 15:03:58, 2026-09-10), and cvoiced then spends ~30 s
loading its model. `build_voice()` health-probes cvoiced exactly once, at
construction; the probe fails, `speaker` stays `None`, `can_talk` is False for
the life of the process, and the phone **rings him and cannot talk**. `/health`
reports it (`answered calls carry no audio`) and nothing retries.

The drop-in gates the start on `wait-for-cvoiced`, which polls
`http://100.72.2.62:8760/status` for `model_loaded:true`. Two deliberate
choices:

- **The wait is bounded (90 s) and the script always exits 0.** A hard
  `Requires=`/`After=` on cvoiced would mean *no doorbell at all* whenever TTS
  is broken. A silent doorbell is strictly worse than a mute one — the same
  reasoning as the live unit's `Restart=always` comment.
- **It probes the tailnet address, not loopback.** `ss -lntp` shows cvoiced
  listening on `100.72.2.62:8760` only, and that is the base URL `Voice()`
  itself uses. A loopback probe reports "not ready" against a healthy cvoiced.

Install:

    install -m755 systemd/wait-for-cvoiced ~/.claude/bin/wait-for-cvoiced
    mkdir -p ~/.config/systemd/user/hotline-ios.service.d
    cp systemd/hotline-ios.service.d/wait-for-cvoiced.conf ~/.config/systemd/user/hotline-ios.service.d/
    systemctl --user daemon-reload && systemctl --user restart hotline-ios

**What is verified and what is not.** Ready case returns in 0 s; a dead port
exits 0 after its budget without blocking the start; a restart through the gate
gives `ExecStartPre status=0` and `degradations: []`. The **actual cold boot** —
tailscale still coming up, cvoiced mid-load — has not been exercised. It needs a
reboot, or it verifies itself at the next scheduled 08:00 wake.
