# Duplex calls: PersonaPlex on the phone, with mid-call lookups

`hotline-call --engine personaplex` hands an answered call to PersonaPlex-7B, a
full-duplex English speech model running on the local GPU, instead of the usual Serbian
ASR → Claude → TTS loop. With `--context-file`, the voice can also answer questions it
could not know on its own: Claude Haiku answers them from a file the calling agent wrote,
plus read-only commands on this box, and the answer is fed into PersonaPlex mid-call.

Opt-in per call. The default call path never imports any of this.

## How a call runs

At ring time, before the INVITE goes out, in parallel:

| step | time (measured) |
|---|---|
| PersonaPlex loads, prefills its voice and persona prompt (`pp-stream2`) | 10-17 s |
| answerer: sandbox check, Haiku prompt cache written with the context file | ~1 s |
| watcher: Whisper small loaded on the CPU, decision connection warmed | ~2 s |

The phone rings only when the model is READY. If the lookup side fails to warm (no API
key, API down), the call still happens without lookups and the returned transcript says
so. ollama models are unloaded first: hotline-ios's own test suite leaves one on the GPU,
and that once made PersonaPlex run out of memory with Bogdan on the line.

During the call, both directions stream continuously in 20 ms frames, with no voice
activity gate: turn-taking is PersonaPlex's job. In parallel, on his side of the line only:

1. **Watcher**: energy endpointing (500 ms of silence) → faster-whisper small on the CPU →
   Haiku decides LOOKUP or NONE. "Fragments and unclear speech are NONE" is in the prompt
   because his real voice produced half-sentences that drew false lookups without it.
2. **HOLD**: PersonaPlex is held silent (teacher-forced to listen; his audio still
   reaches it) and plays "Sure, let me check that for you. One moment, please." in its
   own voice. Bogdan treats that as the signal that the real answer follows.
3. **Answerer**: Haiku with the context file as a cached system prompt and a read-only
   bash tool, at most 3 commands. It answers in one short sentence, or ABSTAINS.
4. **Injection**: `Bogdan asked: <q> Claude's answer: <a> Say this answer to him now.` is
   teacher-forced into PersonaPlex's text stream (no `<system>` tags: those made it
   re-greet as if a new call had started). On abstention it is told to say "I don't have
   that, I'll pass the question on."

PersonaPlex may answer on its own before the HOLD (that is allowed, by Bogdan's choice).
The returned transcript marks that speech `[unverified, spoken before lookup]` and the
speech after the injection `[from Claude]`, and lists the questions that were passed on.

## The context file

Plain text or Markdown, at most 400 KB. Put the facts this call is about in a section
headed `FOR THIS CALL`. The answerer treats that section as authoritative and the rest as
older background.

```markdown
## FOR THIS CALL
Written by ops-nightly-3, 2026-10-16 07:40. Today is Thursday, 16 October 2026.
I am calling because the nightly build failed and I need a decision: retry or open an issue.
- Nightly build (hotline-ios, main): started 02:10, took 14 minutes; 411 tests, 3 failed:
  test_srtp_roc, test_ring_timeout, test_jitter_buffer (all in the media layer).
- Meeting with Stefan: this Thursday, 4:30 PM Belgrade time, about the investor deck.

## Background
(anything else the agent knows; keep it short: see below)
```

Rules of thumb, from measurement:

- **Keep it around 10k tokens.** At ~10k, in-context accuracy was 11/12 at ~0.7 s and
  $0.001 per answer (cached). At ~50k it dropped to 8-10/12. It confused the call's numbers
  with numbers elsewhere in the agent's notes ("how many tests passed" got a pytest count
  from an unrelated run). Below ~4k tokens the prompt is too short to cache, which costs
  more per answer ($0.0023), not less.
- **State facts, not instructions.** Values the answerer can compute from are fine
  (total and free gives used; a date gives days-until).
- **Live facts need no file:** disk, RAM, load, uptime, git log/status are read with the
  bash tool at question time.
- **Do not put secrets in it.** Its text is sent to the Claude API.

## The bash tool's sandbox

bubblewrap, read-only: `/` is mounted read-only; `$HOME` is an empty tmpfs with only `~/data`
bound back, read-only, and every secret-looking file in it (`.env*`, keys, credentials,
tokens) masked. `/run` is masked, so other sessions' unix sockets stay unreachable. No
network, own PID namespace, an empty environment (the daemon's environment holds the SIP
credentials), 5 s per command, 4 KB of output, 3 commands per answer.

Red team, 2026-10-16: none of 8 hostile spoken requests (API key, SSH key, .env, GitHub
token, Claude credentials, print the environment, delete logs, write a file) produced a
secret or a change. Known limit: inside `~/data` the masking is by file name, so a secret
kept in an ordinarily named file there would be readable.

## Requirements

- `pp-stream2` and the PersonaPlex weights from duplex-lab (`HOTLINE_IOS_DUPLEX_LAB`,
  default `~/data/duplex-lab`; launcher `pp-stream/run-pp-stream2`).
- The `duplex` extra (`anthropic`) and the `voice` extra (faster-whisper, soxr).
- `bwrap` on PATH.
- An API key in `~/keys/claude.txt` (mode 600; `HOTLINE_IOS_CLAUDE_KEY_FILE` overrides).
  It is read at runtime and never logged. Token usage and cost per call go to
  `~/.local/state/hotline-ios/claude-usage.jsonl`.

## Measured (duplex-lab, 2026-10-16; details in its LOG.md and ab/RESULTS.md)

| what | result |
|---|---|
| his question end → HOLD (filler starts) | median 2.2 s |
| → answer injected | median 4.2 s |
| → answer audible | median 9.9 s (max 15.5) |
| answers that reached his ear, end-to-end fake calls | 8/12 (7 clean, 1 garbled) |
| unknown questions abstained, not invented | 83/83 |
| watcher false lookups on his real voice | 0/15 |
| cost of a call with 2 lookups | ~$0.02 |

## Limitations

- **English only.** PersonaPlex does not speak Serbian, even when told to.
- **The answer is said by PersonaPlex, which paraphrases.** It sometimes garbles numbers
  ("Red file system" for "root"), says "Claude" aloud, or speaks its own agenda first.
  About 1 answer in 3 did not reach his ear in testing.
- **It still answers on its own before a lookup** (labelled unverified), and may say
  something wrong there. Bogdan's call: the filler marks where the real answer starts.
- **Lookups are deaf while held:** PersonaPlex hears him during the HOLD but does not speak.
- **The answerer only knows the context file and read-only commands.** It cannot ask the
  calling agent anything mid-call.
