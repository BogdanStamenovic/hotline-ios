# The redesign — decisions and what they cost

His verdict on the first version: *"its absolutely ugly with bugs."* Fair. It
was built to prove the toolchain, and it did.

## What he decided

| Question | His answer |
|---|---|
| Structure | **Channels per agent** — a list, tap in for that agent's own thread |
| Blocked questions | **Pinned to the top of the channel list** |
| Landing screen | **Whichever needs you most** — a blocked agent if one is waiting |
| Agent control | **Everything**: stop, kill, retask, resume, start a new agent |
| History | **Cached locally and synced** |
| Motion | **Expressive springs** — physical, interruptible |
| Haptics | **Sparingly.** No sound |
| Channel row | Live / busy / dead state |
| Map | A **timeline of phases** with tool calls nested under each |

## The visual direction, in his words

> "Start fresh i want to be suprised. It should not feel like a cli tool. But
> polished full of animations and insanely good to look like. Modern futuristic
> full of random features that say DAMM THATS GOOD."

He first pointed at `~/data/uxonews` for density and then explicitly overrode
it: *"Nah its not about the principal. Start fresh."* So uxonews is **not** the
template. What is worth carrying over is only the evidence that he thinks about
motion carefully — that project's own CSS carries reasoning like *"on a page you
sit and read, a 2.2s pulse nags"*.

**One contradiction, resolved openly.** He described a per-agent tools/mind-map
tab in detail, then later selected only `Chat` when asked which tabs he wanted.
Too specific to be a misclick, so the map survives as a view pushed into from an
agent rather than a tab. Flagged to him rather than silently decided.

## The three bugs, diagnosed

**"Messages on this channel are still there when I click hotline-ios."** The
chip's action is `store.chosen = agent.name` and nothing else. It changes where
the *next* message goes; it never swaps the transcript. Underneath that: **there
are no channels.** `Store` holds one `moments` array belonging to whatever
conversation was last opened.

**"Appearing and disappearing really slow."** Three causes, all client-side —
the server is not at fault, `EventLog.wait` wakes immediately on
`_arrived.set()` rather than sitting out its timeout:

1. The feed only starts inside `send()` and `answer()`. Open a channel and say
   nothing, and **nothing streams at all**.
2. `refresh()` runs only on appear and pull-to-refresh, so the agent list and
   the waiting banner go stale and stay stale.
3. `apply()` drops any `.you` moment whose text matches one already shown.
   **Send "yes" twice and the second disappears.** That is the disappearing
   message, and it is a real bug rather than a symptom of the architecture.

Nothing is persisted either, so a relaunch is an empty transcript.

## The gap this opens on the server

Channels-per-agent needs something the daemon does not have:

- **Conversations are not tagged with an agent.** `self.calls` is
  `dict[str, EventLog]` and `conversations()` returns no agent field, so there
  is no way to ask "what has `hotline-ios` and I said to each other".
- **History is in memory and reaped.** Closed conversations are dropped after an
  hour, and everything dies with the process.

His choice of a local cache as the primary history softens the second — the
phone keeps the record and the server reconciles — but "synced" needs the server
to have *something* to sync, and the first point is required either way.

**This is the real work of the redesign, and it is behind the UI rather than in
it.** A beautiful channel list on top of a server that cannot say which
conversations belong to an agent would be a facade.
