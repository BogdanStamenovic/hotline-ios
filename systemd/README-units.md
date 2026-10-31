# The unit, and how it relates to the live one

`hotline-ios.service.in` is the template `ownbox.sh setup` renders into
`~/.config/systemd/user/hotline-ios.service`. A rendered unit starts with the
line `# Rendered by hotline-ios ownbox.sh`; `setup` and `update` rewrite only a
unit that carries it.

**On archserver the live unit is hand-written** and predates the template. It
has been restarted, rung and debugged, so `setup` leaves it alone and says so.
To hand it over to the template: compare the two, delete the live one, run
`./ownbox.sh setup`.

What changed on 2026-10-31, when phone calls moved to hotline-call:

| | before | after |
|---|---|---|
| `HOTLINE_IOS_RING=` | `sip` | gone: hotline-iosd rings nothing |
| `wait-for-cvoiced` drop-in | gated the start on cvoiced | gone with the voice; it lives in hotline-call's `hotline-calld` unit now |
| SIP_* in `.env` | read at startup | read by hotline-calld from `~/.config/hotline-call/env` |

The old tracked `hotline-iosd.service` was deleted: it had drifted from the live
unit (`telegram,sip`, `KillMode=process`, no `StartLimitIntervalSec=0`) and
nothing ran it.

`KillMode=process` is not in the template. The note that came with it warned
that restarting the unit could take the tmux server -- and every live Claude
session -- down with it; two restarts of the live unit, which lacks it, on
2026-09-10 did no such thing, so either the hazard is gone or it never applied
to this unit.
