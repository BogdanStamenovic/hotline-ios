import Foundation

// The only executable verification available on this box. `Wire.swift` and
// `Rules.swift` import Foundation and nothing else, so they compile and run
// natively here with the same toolchain that builds the app. Two things are
// checked: the bytes the OLD daemon really sends today, and the FULL contract
// the new one is about to send.

var failures = 0
var checks = 0

@MainActor func check(_ ok: Bool, _ what: String) {
    checks += 1
    if ok { print("  ok    \(what)") } else { failures += 1; print("  FAIL  \(what)") }
}

@MainActor func section(_ title: String) { print("\n== \(title)") }

func load(_ name: String) -> Data {
    let here = URL(fileURLWithPath: CommandLine.arguments.count > 1
                   ? CommandLine.arguments[1] : ".")
    return (try? Data(contentsOf: here.appending(path: name))) ?? Data()
}

let decoder = JSONDecoder()

// ---------------------------------------------------------------------------
section("the live daemon's real bytes (old code: no state, no vitals, no controls)")

do {
    let page = try decoder.decode(AgentsPage.self, from: load("live-agents.json"))
    check(page.agents.count == 4, "four agents decode")
    let live = page.agents.first { $0.name == "hotline-80" }
    check(live != nil, "hotline-80 is there")
    check(live?.vitals == nil, "no Vitals -> nil, so the strip renders no cell")
    check(live?.controls == nil, "no controls -> nil")
    check(live?.capabilities.isEmpty == true, "and capabilities is an empty list, never a guess")
    check(live?.contextAvailable == nil, "no contextAvailable -> nil, so no context cell at all")
    check(live?.declaredAt == nil, "no declaredAt -> no ELAPSED cell")
    check(live?.state == nil, "no state field")
    check(live?.generation == 0, "generation defaults to 0, so nothing is ever invalidated")
    check(live?.presence == .live, "live+!busy with no state -> .live (the narrower answer)")
    let dead = page.agents.first { $0.name == "data-75" }
    check(dead?.presence == .dead, "!live+!busy with no state -> .dead")
    check(live?.stamp == nil, "no timestamp anywhere -> no relative time, not a fabricated 'now'")
} catch {
    check(false, "live roster decodes: \(error)")
}

do {
    let health = try decoder.decode(Health.self, from: load("live-health.json"))
    check(health.ok == true, "health decodes")
    check(health.globalControls == nil, "no globalControls -> the brief pull says so")
    check(health.dbBytes == nil, "no db_bytes yet")
} catch {
    check(false, "live health decodes: \(error)")
}

do {
    let page = try decoder.decode(ConversationsPage.self, from: load("live-conversations.json"))
    check(page.conversations.isEmpty, "no open conversations -> composer starts a new one")
} catch {
    check(false, "live conversations decode: \(error)")
}

// ---------------------------------------------------------------------------
section("the full contract the server is landing now")

let fullRoster = """
{"agents":[
 {"name":"hotline-80","task":"t","cwd":"/w","live":true,"busy":true,
  "state":"working","blocked":false,"stalled":false,"retired":false,
  "historyGeneration":7,"declaredAt":1756000000.0,"lastToolAt":1756000900.5,
  "contextAvailable":true,
  "vitals":{"tokensPerSec":46.2,"toolsPerMin":4.2,"lastToolAt":1756000900.5,
            "blockedFor":null,"contextUsed":0.32},
  "controls":[{"id":"stop","label":"Stop","enabled":true,"reason":null},
              {"id":"kill","label":"Kill","enabled":true,"reason":null},
              {"id":"compact","label":"Compact","enabled":false,
               "reason":"running headless — its turn can't be interrupted, only killed"},
              {"id":"teleport","label":"Teleport","enabled":true,"reason":null}]},
 {"name":"blocked-1","task":"t","cwd":"/w","live":true,"busy":false,
  "state":"idle","blocked":true,"blockedSince":1756000500.0,
  "contextAvailable":true,
  "vitals":{"tokensPerSec":0,"toolsPerMin":0,"lastToolAt":null,
            "blockedFor":252.0,"contextUsed":null}},
 {"name":"finished-1","task":"t","cwd":"/w","live":false,"busy":false,
  "state":"done","contextAvailable":false,
  "vitals":{"tokensPerSec":0,"toolsPerMin":0,"lastToolAt":null,
            "blockedFor":null,"contextUsed":null}},
 {"name":"gone-1","task":"t","cwd":"/w","live":false,"busy":false,
  "state":"dead","deadReason":"process exited 137"},
 {"name":"future-1","task":"t","cwd":"/w","live":true,"busy":false,
  "state":"hibernating"}
]}
""".data(using: .utf8)!

do {
    let page = try decoder.decode(AgentsPage.self, from: fullRoster)
    check(page.agents.count == 5, "five agents decode")

    let busy = page.agents[0]
    check(busy.presence == .busy, "state=working -> .busy")
    check(busy.vitals?.tokensPerSec == 46.2, "tokensPerSec")
    check(busy.vitals?.contextUsed == 0.32, "contextUsed 0.32 -> the CONTEXT cell reads 32 %")
    check(busy.generation == 7, "historyGeneration 7 reaches the invalidation check")
    check(busy.declaredDate != nil, "declaredAt -> the ELAPSED cell has a clock to tick")
    check(busy.capabilities.count == 4, "four capabilities, in the server's order")
    check(busy.capabilities[0].id == "stop", "order preserved, not re-sorted by the app")

    let compact = busy.capabilities.first { $0.id == "compact" }!
    check(compact.enabled == false, "compact disabled")
    check(compact.usable == false, "and therefore not usable")
    check(compact.refusal?.contains("headless") == true,
          "tapping it surfaces the server's own reason, verbatim")

    let unknown = busy.capabilities.first { $0.id == "teleport" }!
    check(unknown.known == false, "an id this build cannot dispatch is not 'known'")
    check(unknown.usable == false, "so it renders disabled")
    check(unknown.refusal == "this build can't do that yet.",
          "with the app's own words -- shown, never hidden")

    let blocked = page.agents[1]
    check(blocked.presence == .blocked, "blocked outranks state=idle")
    check(blocked.blockedAt != nil, "blockedSince -> the BLOCKED cell ticks locally")
    check(blocked.vitals?.contextUsed == nil && blocked.contextAvailable == true,
          "contextUsed null + available true == the 'not yet' state")

    let done = page.agents[2]
    check(done.presence == .done, "state=done -> .done, NOT .dead (APP-PLAN 12.5)")
    check(done.contextAvailable == false,
          "contextAvailable false == 'unavailable': no cell, no bar, not a dash")

    let gone = page.agents[3]
    check(gone.presence == .dead, "state=dead -> .dead")
    check(gone.presence != done.presence, "done and dead are distinguishable, which is the point")
    check(gone.deadReason == "process exited 137", "deadReason survives")

    let future = page.agents[4]
    check(future.state == .unrecognised,
          "an unknown state string decodes as .unrecognised instead of failing the roster")
    check(future.presence == .live, "and falls back to the live/busy derivation")
} catch {
    check(false, "full roster decodes: \(error)")
}

// ---------------------------------------------------------------------------
section("feed and history pages")

let feed = """
{"agent":"hotline-80","cursor":412,"closed":false,"historyGeneration":7,"events":[
 {"seq":409,"kind":"you","text":"yes","at":1756000801.0,"client_token":"tok-a"},
 {"seq":410,"kind":"tool","tool":"Edit","text":"ChannelStore.swift · +41 −18",
  "at":1756000802.0,"duration_ms":1840.0,"viaSubagent":true,"phase":"ph-2"},
 {"seq":411,"kind":"tool","tool":"Read","text":"Wire.swift","at":1756000803.0},
 {"seq":412,"kind":"claude","text":"done","at":1756000804.0,"conversation":"c-9"}
]}
""".data(using: .utf8)!

do {
    let page = try decoder.decode(FeedPage.self, from: feed)
    check(page.agent == "hotline-80", "the page names its agent -- Channel.apply traps if it is not ours")
    check(page.events.count == 4, "four events")
    check(page.events[0].clientToken == "tok-a", "client_token decodes from snake_case")
    check(page.events[1].durationMs == 1840, "duration_ms decodes from snake_case")
    check(page.events[1].duration == 1.84, "and converts to seconds")
    check(page.events[1].viaSubagent, "viaSubagent -> dimmed and indented")
    check(page.events[1].phase == "ph-2", "phase id survives for the map")
    check(page.events[2].durationMs == nil,
          "a tool row with no duration renders NO bar, never a guessed one")
    check(page.events[3].conversation == "c-9", "conversation id survives")
} catch {
    check(false, "feed decodes: \(error)")
}

let history = """
{"agent":"hotline-80","oldest_seq":210,"newest_seq":412,"has_more":true,
 "historyGeneration":7,
 "events":[{"seq":210,"kind":"claude","text":"hi","at":1756000000.0}],
 "phases":[{"id":"ph-1","title":"Wire it up","outcome":"done",
            "started_at":1756000000.0,"ended_at":1756000400.0},
           {"id":"ph-2","title":"Channels","outcome":null,
            "started_at":1756000400.0,"ended_at":null}]}
""".data(using: .utf8)!

do {
    let page = try decoder.decode(HistoryPage.self, from: history)
    check(page.oldestSeq == 210 && page.newestSeq == 412, "snake_case seq bounds decode")
    check(page.hasMore, "has_more -> the thread offers a pull for older")
    check(page.phases?.count == 2, "phase records decode")
    check(page.phases?[1].endedAt == nil, "an open phase has no end, and is not defaulted to one")
} catch {
    check(false, "history decodes: \(error)")
}

// A history page with no phases key at all, which is every server before step 7.
do {
    let page = try decoder.decode(HistoryPage.self, from: """
    {"agent":"a","events":[],"has_more":false}
    """.data(using: .utf8)!)
    check(page.phases == nil, "an absent phases key is nil, not an empty route claimed as fact")
    check(page.oldestSeq == nil && page.newestSeq == nil, "absent bounds stay absent")
} catch {
    check(false, "minimal history decodes: \(error)")
}

// ---------------------------------------------------------------------------
section("bug 3: which bubble an arriving `you` event resolves")

// Two identical sends. This is the exact reproduction from APP-PLAN 1.1.
let twoYeses = [
    PendingSlot(token: nil, sinceSeq: 100, inFlight: true),
    PendingSlot(token: nil, sinceSeq: 100, inFlight: true),
]
let echo1 = Moment(seq: 101, kind: .you, text: "yes", at: .now)
let echo2 = Moment(seq: 102, kind: .you, text: "yes", at: .now)
check(reconciled(echo1, in: twoYeses) == 0, "the first echo resolves the first bubble")
var afterFirst = twoYeses
afterFirst.remove(at: 0)
check(reconciled(echo2, in: afterFirst) == 0,
      "the second echo resolves the second -- both 'yes' survive, which is the whole bug")

// A history replace full of old `you` events must not resolve a new bubble.
let oneNew = [PendingSlot(token: nil, sinceSeq: 400, inFlight: true)]
check(reconciled(Moment(seq: 12, kind: .you, text: "old", at: .now), in: oneNew) == nil,
      "an OLD you event (seq 12 < sinceSeq 400) resolves nothing")
check(reconciled(Moment(seq: 401, kind: .you, text: "new", at: .now), in: oneNew) == 0,
      "the real echo (seq 401 > 400) resolves it")

// A retask's tokened echo must not eat the composer's untokened bubble.
let composerBubble = [PendingSlot(token: nil, sinceSeq: 100, inFlight: true)]
let retaskEcho = Moment(seq: 101, kind: .you, text: "do the other thing", at: .now,
                        clientToken: "retask-1")
check(reconciled(retaskEcho, in: composerBubble) == nil,
      "a tokened echo with no matching bubble resolves NOTHING (plain FIFO would have eaten it)")

let tokened = [PendingSlot(token: "retask-1", sinceSeq: 100, inFlight: true)]
check(reconciled(retaskEcho, in: tokened) == 0, "and resolves its own bubble exactly")

// A failed bubble is skipped, so an unrelated echo cannot clear a retry.
let failedThenLive = [
    PendingSlot(token: nil, sinceSeq: 100, inFlight: false),
    PendingSlot(token: nil, sinceSeq: 100, inFlight: true),
]
check(reconciled(echo1, in: failedThenLive) == 1,
      "a failed bubble is skipped -- the retry affordance survives its neighbour's echo")

// Nothing but `you` reconciles anything.
check(reconciled(Moment(seq: 500, kind: .claude, text: "hi", at: .now), in: oneNew) == nil,
      "a claude event resolves nothing")
check(reconciled(Moment(seq: 500, kind: .tool, text: "x", at: .now), in: oneNew) == nil,
      "a tool event resolves nothing")
check(reconciled(echo1, in: []) == nil, "no bubbles, nothing to resolve")

// ---------------------------------------------------------------------------
section("readouts")

check(hotlineClock(252) == "4:12", "4:12 blocked")
check(hotlineClock(0) == "0:00", "zero is zero, not blank")
check(hotlineClock(-5) == "0:00", "a negative clock cannot happen and does not render one")
check(hotlineClock(3661) == "1:01:01", "past an hour it grows a column")

check(abs(durationBarWidth(0) - 3) < 0.001, "a zero-length call still draws its 3 pt stub")
check(abs(durationBarWidth(60) - 47) < 0.05, "60 s fills the 44 pt column")
check(durationBarWidth(600) <= 47.001, "and it clamps beyond the ceiling")
check(durationBarWidth(1.84) > 3 && durationBarWidth(1.84) < 20,
      "1.84 s lands in the low-middle of the log scale")
check(durationLabel(0.04) == "40ms" && durationLabel(1.84) == "1.8s" && durationLabel(120) == "2m",
      "duration labels")

@MainActor func compact(_ json: String) -> CompactResult {
    try! decoder.decode(CompactResult.self, from: json.data(using: .utf8)!)
}

check(compactSentence(compact("""
{"agent":"a","interrupted":true,"compacted":true,"resumed":true,
 "preTokens":48027,"postTokens":4070,"durationMs":71104}
""")) == "Compacted — 48k → 4.1k in 71s",
      "the real numbers from the transcript's compact_boundary record")

check(compactSentence(compact("""
{"agent":"a","interrupted":true,"compacted":true,"resumed":false,
 "preTokens":48027,"postTokens":4070,"durationMs":71104}
""")) == "Compacted — 48k → 4.1k in 71s — not resumed",
      "resumed:false is an honest outcome, said out loud")

check(compactSentence(compact("""
{"agent":"a","interrupted":true,"compacted":true,"resumed":true}
""")) == "Compacted",
      "a server that sent no numbers gets no invented ones -- not 'in 0s'")

check(compactSentence(compact("""
{"agent":"a","interrupted":true,"compacted":false,"resumed":false,
 "detail":"no pty for this session"}
""")) == "no pty for this session",
      "compacted:false renders whatever the server said went wrong, verbatim")

check(tokenCount(4070) == "4.1k" && tokenCount(48027) == "48k",
      "one decimal below 10 k, integer above")

// ---------------------------------------------------------------------------
section("sample ring")

var ring = SampleRing()
let t0 = Date(timeIntervalSince1970: 1_756_000_000)
for i in 0..<400 {
    ring.append(Sample(at: t0.addingTimeInterval(Double(i) * 5),
                       charsPerSec: Double(i), toolsPerMin: 0, blockedFor: nil))
}
check(ring.samples.count == SampleRing.capacity, "the ring caps at 360")
check(ring.samples.first?.charsPerSec == 40, "and it trimmed from the front in one go")
ring.append(Sample(at: t0, charsPerSec: 999, toolsPerMin: 0, blockedFor: nil))
check(ring.samples.last?.charsPerSec != 999, "an out-of-order wake is dropped, not plotted as a kink")
// APP-PLAN 5.4: "at a 5 s cadence a 90-second window is about 18 points -- the
// mark is styled for what it actually is rather than for the 360-point curve
// the prototype drew against a fabricated 250 ms model."
check(ring.window(90, now: t0.addingTimeInterval(2000)).count == 18,
      "a 90 s window at a 5 s cadence is 18 points, which is what the mark is styled for")

let reconstructed = rebuiltSamples(from: [
    Moment(seq: 1, kind: .claude, text: String(repeating: "x", count: 100),
           at: t0),
    Moment(seq: 2, kind: .tool, text: "t", at: t0.addingTimeInterval(5)),
    Moment(seq: 3, kind: .claude, text: String(repeating: "x", count: 200),
           at: t0.addingTimeInterval(10)),
])
check(reconstructed.count == 1, "one interval between two assistant events -> one sample")
check(reconstructed[0].charsPerSec == 20, "200 chars over 10 s == 20 ch/s, the same measure as Vitals")
check(reconstructed[0].toolsPerMin == 1, "and the tool call in that minute is counted")

let sameInstant = rebuiltSamples(from: [
    Moment(seq: 1, kind: .claude, text: "a", at: t0),
    Moment(seq: 2, kind: .claude, text: "b", at: t0),
])
check(sameInstant.isEmpty, "two events in the same instant carry no rate and produce no spike")

// ---------------------------------------------------------------------------
section("moment round-trips through the cache's JSONL")

let encoder = JSONEncoder()
let original = Moment(seq: 410, kind: .tool, text: "Edit x", tool: "Edit", at: t0,
                      conversation: "c-1", viaSubagent: true, phase: "ph-2",
                      durationMs: 1840, clientToken: "tok-a")
do {
    let line = try encoder.encode(original)
    let back = try decoder.decode(Moment.self, from: line)
    check(back == original, "a Moment survives the cache round-trip with every field")
    check(String(data: line, encoding: .utf8)?.contains("duration_ms") == true,
          "and it writes the same snake_case keys the wire uses, so one decoder serves both")
} catch {
    check(false, "round-trip: \(error)")
}

// A torn last line is what a crash mid-append leaves behind.
let torn = "\(String(data: try! encoder.encode(original), encoding: .utf8)!)\n{\"seq\":411,\"kin"
let lines = torn.split(separator: "\n").compactMap {
    try? decoder.decode(Moment.self, from: Data($0.utf8))
}
check(lines.count == 1, "a torn last line is dropped and the rest of the segment still reads")

// ---------------------------------------------------------------------------
section("the motion scalars (Theme/Scalars.swift)")

check(win(0, 0.3, 0.4) == 0 && win(1, 0.3, 0.4) == 1, "a window is closed before its start and open after its span")
check(abs(win(0.5, 0.3, 0.4) - 0.5) < 1e-12, "and smoothstep is symmetric about its midpoint")
check(win(0.31, 0.3, 0.4) < 0.01, "it eases in rather than starting linearly")
check(project(1000) == 499, "the fling projection is the system's own exponential decay")

// The one that fails silently: a drag beginning on an already-banded surface
// resumes from the finger-space value, and a step under the thumb is the bug.
for over in [12.0, 90.0, 300.0] {
    let banded = rubber(over, 800, 0.62)
    check(abs(unrubber(banded, 800, 0.62) - over) < 1e-6,
          "rubber/unrubber round-trips at \(Int(over)) pt over, so a re-grab has no step")
    check(banded < over, "and the band always resists (\(Int(over)) pt in, \(Int(banded)) pt out)")
}
check(rubber(1e9, 800, 0.62) < 800, "no finger travel can pull the surface off the screen")

check(focusBand(top: 170) == 1, "a phase sitting in the focus band is fully open")
check(focusBand(top: 170 + 210) == 0 && focusBand(top: -1000) == 0,
      "and one 210 pt away, either side, is fully closed")
check(abs(focusBand(top: 275) - 0.5) < 1e-12, "halfway out is half open")
check(toolStagger(0.5, 0) > toolStagger(0.5, 4), "tool rows stagger outward from the first")
// APP-PLAN 6.2's `clamp((on - k*0.055)/0.6, 0, 1)` reaches 1 only up to k = 7.
// That is the spec's own arithmetic, and it is recorded rather than "fixed":
// past the eighth row a phase's tail stays slightly indented and slightly faded
// even at full focus, which reads as depth rather than as a bug.
check((0...7).allSatisfy { toolStagger(1, $0) == 1 }, "a fully open phase resolves the first eight rows")
check(toolStagger(1, 8) < 1 && toolStagger(1, 8) > 0.8,
      "and leaves the ninth and beyond fractionally short, by the spec's own numbers")
check(toolStagger(0, 0) == 0, "a closed phase opens none of them")

// ---------------------------------------------------------------------------
section("the route, rebuilt from the events the daemon really sends")

// Captured from 100.72.2.62:8789 on 2026-08-26. The point of asserting against
// the real bytes rather than a hand-written page: the contract in SERVER-PLAN
// §6 and APP-PLAN §6.2 says phases arrive as records on the history page, and
// this daemon does not send that key at all.
do {
    let page = try decoder.decode(HistoryPage.self, from: load("live-history.json"))
    check(page.agent == "hotline-80", "the live history page names its agent")
    check(page.phases == nil,
          "**the deployed daemon sends NO `phases` key** -- the route has to come from the events")
    check(!page.events.isEmpty, "and it does send events")

    let kinds = Set(page.events.map(\.kind))
    check(kinds.contains(.phase), "which include `phase` rows, decoded rather than swallowed as .summary")
    check(kinds.contains(.outcome), "and `outcome` rows")
    check(kinds.contains(.tool), "and tool rows")

    let built = route(from: page.events)
    check(!built.phases.isEmpty, "the route reconstructs \(built.phases.count) legs out of them")

    // Nothing may be lost or duplicated: every tool row lands in exactly one
    // place, a leg or the named unattributed bucket.
    let toolRows = page.events.filter { $0.kind == .tool || $0.kind == .compact }
    let placed = built.phases.flatMap(\.tools).count + built.unphased.count
    check(placed == toolRows.count,
          "every one of the \(toolRows.count) tool rows is placed exactly once, none invented")

    let opened = Set(page.events.filter { $0.kind == .phase }.compactMap(\.phase))
    let titled = built.phases.filter { $0.title != nil }.map(\.id)
    check(Set(titled) == opened,
          "a leg has a title exactly when its opening event was in the loaded page")
    check(built.phases.allSatisfy { $0.title != nil || $0.startInferred },
          "and an untitled leg is marked as inferred rather than pretending to a start time")

    check(built.phases == built.phases.sorted { $0.startedAt < $1.startedAt },
          "legs come back in time order whatever order the ids appeared in")

    let closed = Set(page.events.filter { $0.kind == .outcome }.compactMap(\.phase))
    check(Set(built.phases.filter { !$0.isOpen }.map(\.id)) == closed,
          "a leg is closed exactly when an outcome row closed it -- an open one is not given an end")
    check(built.phases.filter(\.isOpen).allSatisfy { $0.duration == nil },
          "and an open leg has no duration, rather than one measured to 'now'")
} catch {
    check(false, "live history decodes: \(error)")
}

// The reconstruction's own edges, on bytes chosen to hit them.
do {
    let t = Date(timeIntervalSince1970: 1_787_000_000)
    func at(_ offset: Double) -> Date { t.addingTimeInterval(offset) }
    let events = [
        // A page that begins mid-leg: tools whose opening event was never loaded.
        Moment(seq: 1, kind: .tool, text: "a", tool: "Read", at: at(0), phase: "p0"),
        Moment(seq: 2, kind: .phase, text: "Do the thing", at: at(10), phase: "p1"),
        Moment(seq: 3, kind: .tool, text: "b", tool: "Bash", at: at(11), phase: "p1"),
        Moment(seq: 4, kind: .tool, text: "c", tool: "Grep", at: at(12), viaSubagent: true, phase: "p1"),
        Moment(seq: 5, kind: .compact, text: "compacted 48027 → 4070 tokens in 71.1s",
               tool: "compact", at: at(13), phase: "p1"),
        Moment(seq: 6, kind: .outcome, text: "Did the thing", at: at(20), phase: "p1"),
        Moment(seq: 7, kind: .phase, text: "Next leg", at: at(21), phase: "p2"),
        // Unattributable: the server could not place it.
        Moment(seq: 8, kind: .tool, text: "d", tool: "Read", at: at(22)),
    ]
    let built = route(from: events)
    check(built.phases.count == 3, "three legs: one inferred, two opened")
    check(built.phases[0].id == "p0" && built.phases[0].title == nil,
          "the leg the page begins inside has no title, because there is no honest one")
    check(built.phases[0].startInferred, "and its start is marked inferred")
    check(built.phases[1].title == "Do the thing", "the opening event's text is the title")
    check(built.phases[1].outcome == "Did the thing", "the closing event's text is the outcome")
    check(built.phases[1].duration == 10, "and the leg's duration is real, both ends measured")
    check(built.phases[1].tools.count == 3, "its three rows nest under it, compaction included")
    check(built.phases[1].tools.map(\.seq) == [3, 4, 5], "in the order the store handed them out")
    check(built.phases[2].isOpen && built.phases[2].outcome == nil,
          "the last leg is still open -- 'Route continues when you answer'")
    check(built.unphased.map(\.seq) == [8],
          "the row the server could not attribute is named, not filed into a phantom leg")
    check(built.compactions.count == 1, "the compaction is listed for the waveform marker")
    check(built.compactions[0].text.contains("48027"),
          "carrying the transcript's own numbers, which the app never recomputes")

    check(built.boundaries(since: t) == [0, 10, 20, 21],
          "every boundary, sorted, is what a throw can snap to")
    check(built.phase(at: at(15))?.id == "p1", "an instant inside a leg finds it")
    check(built.phase(at: at(20.5)) == nil,
          "and one in the gap between legs finds nothing, because that gap is real")
    check(built.phase(at: at(5))?.id == "p0",
          "the leg with no opening event still covers its own span")
    check(built.end(of: 0) == at(10),
          "**a leg that lost its outcome row stops where the next one starts**, not at the end of time")
    check(built.end(of: 2) == nil, "and only the last leg is genuinely open-ended")
    check(built.phase(at: at(3600))?.id == "p2", "which is why an instant long after it still lands there")

    // A leg whose tools arrive before its opening event -- a page boundary
    // landing between them, which is the case that quietly loses the title.
    let outOfOrder = route(from: [
        Moment(seq: 3, kind: .tool, text: "b", tool: "Bash", at: at(11), phase: "p1"),
        Moment(seq: 2, kind: .phase, text: "Do the thing", at: at(10), phase: "p1"),
    ])
    check(outOfOrder.phases.count == 1 && outOfOrder.phases[0].title == "Do the thing",
          "events are sorted by seq first, so the opening event still wins on the title")
    check(outOfOrder.phases[0].startInferred == false,
          "and the leg's start stops being inferred once its opening event lands")

    // A daemon that DOES send phase records: they win, the nesting still comes
    // from the events.
    let declared = [Phase(id: "p1", title: "From the store", outcome: "stored",
                          startedAt: t.timeIntervalSince1970 + 5, endedAt: nil)]
    let merged = route(from: events, declared: declared)
    check(merged.phases.first(where: { $0.id == "p1" })?.title == "Do the thing",
          "an event-borne title still wins, because it is the same row the record was written from")
    check(merged.phases.first(where: { $0.id == "p1" })?.tools.count == 3,
          "and a phase record carries no tool calls, so the nesting is still the events'")

    check(route(from: []).isEmpty, "no events is an empty route, not a fabricated one")
}

// ---------------------------------------------------------------------------
section("scrub <-> timeline: the Driver enum makes the oscillation unspellable")

var head = Playhead()
check(head.driver == .neither && head.cursor == 0, "it starts owned by nobody")

head.scrub(to: 40)
check(head.driver == .strip && head.cursor == 40, "the strip's gesture takes the cursor")
head.follow(90)
check(head.cursor == 40, "**the timeline's write is refused while the strip owns it** -- no feedback loop")
head.place(5)
check(head.cursor == 40, "and so is a passive write")
head.release()
check(head.driver == .neither, "the gesture ending hands it back")

head.follow(90)
check(head.driver == .timeline && head.cursor == 90, "now the timeline owns it")
head.scrub(to: 12)
check(head.cursor == 90, "and the strip's write is refused, symmetrically -- 'and vice versa'")
head.release()
head.place(7)
check(head.cursor == 7, "with nobody driving, a passive write lands")

let bounds: [TimeInterval] = [0, 100, 260, 600]
check(snapped(258, to: bounds, span: 600) == 260, "a throw ending 2 s from a boundary snaps to it")
check(snapped(200, to: bounds, span: 600) == nil,
      "one ending 60 s away does not -- the strip has to be parkable mid-phase")
check(snapped(110, to: [0, 100, 118, 600], span: 600) == 118,
      "and with two boundaries inside the tolerance, the nearer wins")
check(snapped(258, to: [], span: 600) == nil, "no boundaries, no snap")
check(snapped(258, to: bounds, span: 0) == nil, "a zero-length session cannot snap")

check(toolTick(Moment(seq: 1, kind: .tool, text: "", tool: "Read", at: .now)) == .read, "Read -> read")
check(toolTick(Moment(seq: 1, kind: .tool, text: "", tool: "Edit", at: .now)) == .edit, "Edit -> write")
check(toolTick(Moment(seq: 1, kind: .tool, text: "", tool: "Bash", at: .now)) == .shell, "Bash -> shell")
check(toolTick(Moment(seq: 1, kind: .tool, text: "", tool: "Task", at: .now)) == .signal, "Task -> delegate")
check(toolTick(Moment(seq: 1, kind: .claude, text: "?", at: .now)) == .signal,
      "and a block event shares that colour, because both are the agent leaving its thread")
check(toolTick(Moment(seq: 1, kind: .tool, text: "", tool: "mcp__chrome__navigate", at: .now)) == .other,
      "**an MCP tool lands in `other` rather than being silently mislabelled**")
check(toolTick(Moment(seq: 1, kind: .tool, text: "", at: .now)) == .other, "and so does a tool with no name")

// ---------------------------------------------------------------------------
section("what the daemon sends TODAY (captured live, 2026-08-26)")

do {
    let page = try decoder.decode(AgentsPage.self, from: load("today-agents.json"))
    check(!page.agents.isEmpty, "today's roster decodes: \(page.agents.count) agents")
    check(page.agents.allSatisfy { !$0.capabilities.isEmpty },
          "every row now declares controls, so the swipe and the sheet have something real to render")
    check(page.agents.contains { $0.vitals != nil }, "and Vitals are on the wire")
    check(page.agents.contains { $0.contextAvailable == true },
          "with contextAvailable true somewhere -- the gauge's 'known'/'not yet' states are reachable")
    check(page.agents.contains { $0.contextAvailable == false },
          "and false somewhere -- so is 'unavailable', which renders no cell at all")
    check(page.agents.contains { $0.presence == .done },
          "the daemon reports `done` distinctly from `dead` (APP-PLAN 12.5), which is why the dot has five states")
    check(page.agents.allSatisfy { $0.declaredAt != nil }, "declaredAt landed: the ELAPSED cell has a clock")
    check(page.agents.allSatisfy { $0.generation == 0 },
          "historyGeneration is 0 everywhere -- nothing has been purged, so nothing is invalidated")
    let disabled = page.agents.flatMap(\.capabilities).filter { !$0.enabled }
    check(!disabled.isEmpty && disabled.allSatisfy { $0.reason != nil },
          "and every disabled control carries the server's own reason, which is what a tap surfaces")
} catch {
    check(false, "today's roster decodes: \(error)")
}

do {
    let health = try decoder.decode(Health.self, from: load("today-health.json"))
    check(health.globalControls?.contains { $0.id == "new" } == true,
          "/health now declares `new`, so the pull past the bottom is not a dead end")
    check(health.dbBytes != nil && health.diskFree != nil, "and db_bytes / disk_free reach Settings")
} catch {
    check(false, "today's health decodes: \(error)")
}

do {
    // The live feed, which is what a channel actually streams. Decoded rather
    // than described, because a page that fails to decode is a channel that
    // silently never fills.
    let page = try decoder.decode(FeedPage.self, from: load("today-feed.json"))
    check(page.agent == "hotline-80", "today's feed page names its agent")
    check(!page.events.isEmpty, "and carries \(page.events.count) events")
    check(page.cursor >= (page.events.last?.seq ?? 0), "its cursor is at or past the newest event")
    check(page.events.allSatisfy { $0.kind != .summary },
          "**every kind on it decodes to a real case** -- .summary is the unknown bucket, and nothing lands there")
    check(page.events.contains { $0.kind == .tool },
          "tool rows are there, so the tool dot has something exact to flash on")
    check(page.events.allSatisfy { $0.durationMs == nil },
          "and none of them carries duration_ms yet, so every tool row renders NO bar rather than a guess")
    check(page.events.allSatisfy { !$0.viaSubagent },
          "no viaSubagent rows in this slice either, so nothing is dimmed on a guess")
} catch {
    check(false, "today's feed decodes: \(error)")
}

// ---------------------------------------------------------------------------
section("purge: the dry run is the consent, and it is reconciled against it")

do {
    // The exact bytes archserver answers a dry run with today. It carries three
    // keys this build does not model (`scope`, `agent_removed`,
    // `history_generation`); a decoder that choked on those would take the whole
    // deletion surface down.
    let live = try decoder.decode(PurgeCounts.self, from: load("today-purge-dryrun.json"))
    check(live.agent == "hotline-80", "a live dry run decodes")
    check(live.dryRun == true, "and says it was one")
    check(live.total == live.events + live.conversations + live.phases,
          "its total is the sum of what it actually reported")
    check(!purgeSentence(live).isEmpty, "and the sheet has a real sentence to show")
    check(purgeSentence(live) != "nothing to delete" || live.total == 0,
          "which says 'nothing to delete' only when there is nothing")
} catch {
    check(false, "live purge dry run decodes: \(error)")
}

do {
    let counts = try decoder.decode(PurgeCounts.self, from: """
    {"agent":"scratch","conversations":6,"events":340,"phases":4,
     "oldest_at":1787000000.0,"dry_run":true}
    """.data(using: .utf8)!)
    check(counts.dryRun == true, "dry_run decodes from snake_case")
    check(purgeSentence(counts) == "340 events, 6 conversations, 4 phases",
          "the sheet's line is built from the real counts, never a generic warning")
    check(counts.oldestAt != nil, "and it can say how far back it goes")

    let same = try decoder.decode(PurgeCounts.self, from: """
    {"agent":"scratch","conversations":6,"events":340,"phases":4,"dry_run":true}
    """.data(using: .utf8)!)
    check(sameConsent(counts, same), "a re-run that agrees is the same consent")

    let moved = try decoder.decode(PurgeCounts.self, from: """
    {"agent":"scratch","conversations":6,"events":361,"phases":4,"dry_run":true}
    """.data(using: .utf8)!)
    check(!sameConsent(counts, moved),
          "**one that does not agree is NOT** -- consenting to stale counts is not consent")

    let nothing = try decoder.decode(PurgeCounts.self, from: """
    {"agent":"scratch","conversations":0,"events":0,"phases":0,"dry_run":true}
    """.data(using: .utf8)!)
    check(nothing.total == 0, "nothing to delete is a real answer")
    check(purgeSentence(nothing) == "nothing to delete",
          "and it says so rather than offering a hold that would destroy nothing")
} catch {
    check(false, "purge counts decode: \(error)")
}

check(bytesLabel(0) == "0 bytes", "an empty cache says so")
check(bytesLabel(19_293_798) == "18.4 MB", "and 18.4 MB is the real figure, from a real walk")
check(bytesLabel(940) == "940 bytes" && bytesLabel(20_480) == "20 KB", "with honest units below a megabyte")

// ---------------------------------------------------------------------------
section("the auto-open rule (APP-PLAN 12.2), as three conditions and no more")

let now = Date(timeIntervalSince1970: 1_787_600_000)
func agent(_ name: String, blocked: Bool) -> Agent {
    // Decoding is the only initialiser Agent has, which is the point: the rule
    // is tested against the same shape the wire produces.
    try! decoder.decode(Agent.self, from: """
    {"name":"\(name)","task":"t","cwd":"/w","live":true,"busy":false,
     "state":"idle","blocked":\(blocked)}
    """.data(using: .utf8)!)
}
let one = [agent("a", blocked: true), agent("b", blocked: false)]
let two = [agent("a", blocked: true), agent("b", blocked: true)]
let none = [agent("a", blocked: false)]

check(autoOpen(in: one, launch: .cold, backedOutAt: [:], now: now) == "a",
      "one blocked agent on a cold launch: open it, with the same transition a tap runs")
check(autoOpen(in: two, launch: .cold, backedOutAt: [:], now: now) == nil,
      "two blocked agents: stay on the list with them pinned -- picking one would be a guess")
check(autoOpen(in: none, launch: .cold, backedOutAt: [:], now: now) == nil, "none blocked: nothing to open")
check(autoOpen(in: one, launch: .resumed(after: 600), backedOutAt: [:], now: now) == "a",
      "backgrounded 10 minutes counts as a fresh arrival")
check(autoOpen(in: one, launch: .resumed(after: 120), backedOutAt: [:], now: now) == nil,
      "backgrounded 2 minutes does not -- he never left")
check(autoOpen(in: one, launch: .cold,
               backedOutAt: ["a": now.addingTimeInterval(-30)], now: now) == nil,
      "**and backing out of that channel 30 s ago vetoes it** -- he just said no")
check(autoOpen(in: one, launch: .cold,
               backedOutAt: ["a": now.addingTimeInterval(-90)], now: now) == "a",
      "90 s ago does not veto it")
check(autoOpen(in: one, launch: .cold,
               backedOutAt: ["b": now.addingTimeInterval(-5)], now: now) == "a",
      "and backing out of a DIFFERENT channel is not a veto at all")

// ---------------------------------------------------------------------------
section("every seam rests at 0 or 1, and nowhere in between")

// The defect this exists for: the map came to rest half-open, drawn over the
// conversation, with the channel underneath it non-interactive. `seamTarget` is
// the release rule all five seams share, and the property it has to have is not
// "usually snaps" -- it is that no input at all produces a third resting state.
do {
    var offenders: [String] = []
    var reachedZero = false
    var reachedOne = false
    for commit in [0.42, 0.55] {
        for p in stride(from: 0.0, through: 1.0, by: 0.01) {
            for v in stride(from: -6.0, through: 6.0, by: 0.05) {
                let t = seamTarget(p, velocity: v, commit: commit)
                if t == 0 { reachedZero = true } else if t == 1 { reachedOne = true }
                else { offenders.append("p=\(p) v=\(v) -> \(t)") }
            }
        }
    }
    check(offenders.isEmpty,
          "\(offenders.count == 0 ? "48 642" : "\(offenders.count) of 48 642") "
          + "(progress, velocity) pairs land on exactly 0 or exactly 1")
    check(reachedZero && reachedOne, "and both ends are actually reachable, so it is not a constant")
}

// 0.5 is not an arbitrary sample: it is the exact value the map used to park on,
// because it is where `ChannelLayer` stopped hit-testing and `MapLayer` had not
// started. A release from there has to leave it.
check(seamTarget(0.5, velocity: 0, commit: 0.42) == 1,
      "**a release at the map's old stuck point commits** -- 0.5 is past 0.42, so it opens")
check(seamTarget(0.5, velocity: 0, commit: 0.55) == 0,
      "a sheet released at 0.5 closes, because 0.55 is its threshold and it has not reached it")
check(seamTarget(0.9, velocity: -3, commit: 0.42) == 0,
      "a hard flick back beats position: 0.9 with -3/s projects to -0.6")
check(seamTarget(0.1, velocity: 3, commit: 0.42) == 1, "and the same the other way")
check(seamTarget(0, velocity: 0, commit: 0.42) == 0, "an untouched seam stays shut")
check(seamTarget(1, velocity: 0, commit: 0.42) == 1, "and an open one stays open")

// ---------------------------------------------------------------------------
section("the fleet row's swipe (APP-PLAN 4.7's table)")

// His report was "the swipe just does stuff, it isn't really usable". These are
// the numbers behind that: `stop` on the left at -148, `retask`/`resume` on the
// right at +118, the limits `FleetLayer` computes for a live agent.
let L = 148.0
let R = 118.0

check(swipeOutcome(x: -L, velocity: -600, leftLimit: L, rightLimit: R) == .openLeft,
      "**swiping the row open at 600 pt/s opens it** -- as shipped this fired `stop`")
check(swipeOutcome(x: -L, velocity: -200, leftLimit: L, rightLimit: R) == .openLeft,
      "and so does 200 pt/s, which is a slow one and still fired it")
check(swipeOutcome(x: R, velocity: 400, leftLimit: L, rightLimit: R) == .openRight,
      "the right side opens too, where 400 pt/s used to dispatch `retask`")
check(swipeOutcome(x: -L, velocity: 0, leftLimit: L, rightLimit: R) == .openLeft,
      "held still at the limit, it rests open -- the one release that used to work")

check(swipeOutcome(x: -L - 80, velocity: 0, leftLimit: L, rightLimit: R) == .fireLeft,
      "dragged a full 80 pt past the limit and released, it commits: that is the full swipe")
check(swipeOutcome(x: R + 70, velocity: 0, leftLimit: L, rightLimit: R) == .fireRight,
      "and the same on the right")

// The clause that was dead code. With the old projected-end test, `v < -1100`
// and `x < -60` implied an end below -609, which had already tripped the first
// clause -- so the fling rule could never be the branch that decided anything.
check(swipeOutcome(x: -70, velocity: -1400, leftLimit: L, rightLimit: R) == .fireLeft,
      "**the fling clause decides something again**: -70 pt at -1400 pt/s commits")
check(swipeOutcome(x: -70, velocity: -900, leftLimit: L, rightLimit: R) == .openLeft,
      "and -900 pt/s does not, so it is a threshold rather than a formality")
check(swipeOutcome(x: 60, velocity: 1400, leftLimit: L, rightLimit: R) == .fireRight,
      "the right fling mirrors it")

check(swipeOutcome(x: -20, velocity: 0, leftLimit: L, rightLimit: R) == .closed,
      "a 20 pt nudge released is nothing at all")
check(swipeOutcome(x: 0, velocity: 0, leftLimit: L, rightLimit: R) == .closed,
      "and so is no movement")

// A dead agent has no `stop` and no `kill`, so `leftLimit` is 0 and the row must
// not move at all in that direction. An empty capability list renders as no
// controls; it never invents one.
check(swipeOutcome(x: -400, velocity: -2000, leftLimit: 0, rightLimit: R) == .closed,
      "**with nothing declared on the left, no amount of swipe fires anything**")
check(swipeOutcome(x: 400, velocity: 2000, leftLimit: L, rightLimit: 0) == .closed,
      "and the same on the right")

// The regression itself, spelled out so it cannot come back quietly.
check(-L + project(-200) < -L - 74,
      "the old rule's arithmetic: at the limit, 200 pt/s already projected past the commit line")
check(!(-L < -L - 74),
      "the new one needs the finger to actually be there, and at the limit it is not")

// **Left and right must be the same gesture.** The thresholds were tuned per
// direction and had drifted apart; with the real limits that was 38 pt more
// travel to fire left than right and 18 pt more to open, and the open rule was
// proportional on one side and a flat constant on the other -- so two rows in
// the same list answered the same swipe differently. This is the property that
// keeps them together, rather than three constants that happen to match today.
do {
    var offenders: [String] = []
    func mirror(_ o: SwipeOutcome) -> SwipeOutcome {
        switch o {
        case .fireLeft: return .fireRight
        case .fireRight: return .fireLeft
        case .openLeft: return .openRight
        case .openRight: return .openLeft
        case .closed: return .closed
        }
    }
    for (a, b) in [(L, R), (R, L), (132.0, 118.0), (118.0, 118.0)] {
        for x in stride(from: -400.0, through: 400.0, by: 1.0) {
            for v in stride(from: -3000.0, through: 3000.0, by: 25.0) {
                let got = swipeOutcome(x: x, velocity: v, leftLimit: a, rightLimit: b)
                let flipped = swipeOutcome(x: -x, velocity: -v, leftLimit: b, rightLimit: a)
                if got != mirror(flipped) { offenders.append("L=\(a) R=\(b) x=\(x) v=\(v)") }
            }
        }
    }
    check(offenders.isEmpty,
          "**mirroring the swipe mirrors the outcome** -- \(offenders.count) asymmetric cells "
          + "(was 4 206 with the per-direction constants)")
}

// The specific pairs his hand would have noticed, named rather than swept.
check(swipeOutcome(x: -L - 70, velocity: 0, leftLimit: L, rightLimit: R) == .fireLeft
      && swipeOutcome(x: R + 70, velocity: 0, leftLimit: L, rightLimit: R) == .fireRight,
      "the same overshoot past either limit fires, where left used to need 8 pt more")
check(swipeOutcome(x: -55, velocity: -1400, leftLimit: L, rightLimit: R) == .fireLeft
      && swipeOutcome(x: 55, velocity: 1400, leftLimit: L, rightLimit: R) == .fireRight,
      "and the fling gate opens at the same 50 pt both ways, where left used to need 60")

// A live agent and a finished one differ only in how deep the drawer is, so the
// fraction of it that means "open this" has to be the same fraction.
check(abs(-148.0 * 0.62 - -91.76) < 1e-9 && abs(-132.0 * 0.62 - -81.84) < 1e-9,
      "open scales with the drawer: 91.8 pt on a live row, 81.8 pt on a finished one")

// ---------------------------------------------------------------------------
section("the seam flick threshold, which every seam now shares")

// The defect: velocity only ever reached the decision through `project()` added
// to position, so `commit` was the single knob and the seams had drifted to
// different ones. Nav and the sheets sat at 0.55 with unit gain; the map at
// 0.42 with 1.35. In pt/s on a full-height surface that is 937 against 530.
do {
    let viewport = 850.0
    func flickToOpen(commit: Double, gain: Double) -> Double {
        for pts in stride(from: 0.0, through: 3000.0, by: 1.0) {
            let seamPerSec = pts / viewport * gain
            if seamTarget(0, velocity: seamPerSec, commit: commit) == 1 { return pts }
        }
        return .infinity
    }
    // Every seam's `rate` closure now reports true seam-units/s -- the map's
    // 1.35 is a position gain and no longer touches velocity -- so the flick
    // threshold is the same gesture on all five regardless of their commits.
    let nav = flickToOpen(commit: 0.55, gain: 1.0)
    let sheet = flickToOpen(commit: 0.55, gain: 1.0)
    let map = flickToOpen(commit: 0.42, gain: 1.0)
    check(nav == sheet && nav == map,
          "**all five seams open on the same throw** -- \(Int(nav)) pt/s, "
          + "where nav wanted 937 and the map 530")
    check(nav < 700, "and it is a deliberate flick rather than a shove: \(Int(nav)) pt/s")
}

// The throw beats position wherever the finger got to -- that is what makes it
// a throw rather than a fast drag. Position still decides everything below it.
check(seamTarget(0.02, velocity: 0.7, commit: 0.55) == 1,
      "**a decisive throw from nearly shut opens it**, which at commit 0.55 it did not")
check(seamTarget(0.98, velocity: -0.7, commit: 0.42) == 0,
      "and a decisive throw from nearly open shuts it")
check(seamTarget(0.3, velocity: 0.2, commit: 0.55) == 0,
      "a drift under the flick threshold is still judged on position")
check(seamTarget(0.8, velocity: -0.2, commit: 0.55) == 1,
      "and so is a drift the other way, which at 0.8 is still past the commit")
check(seamTarget(0.6, velocity: -0.2, commit: 0.55) == 0,
      "a slow drift back from 0.6 lands at 0.500 and closes -- position, not the throw")

// ---------------------------------------------------------------------------
section("authority: a standing role, carried through untouched")

do {
    let page = try decoder.decode(AgentsPage.self, from: load("today-agents.json"))
    let admin = page.agents.first { $0.authority != nil }
    check(admin != nil, "the live roster carries `authority` on at least one row")
    check(admin?.authority == "sys-admin",
          "and it is hotline's own string, not a boolean the daemon derived")
    check(admin?.isSysAdmin == true, "which is the role `Registry.Agent.privileged` names")
    check(admin?.authorityLabel == "SYS-ADMIN", "the badge says it in the app's own case")
    check(page.agents.contains { $0.authority == nil },
          "every other row sends null, and null is the normal case")
    check(page.agents.allSatisfy { $0.authority != nil || $0.authorityLabel == nil },
          "**absent means no badge** -- nothing is drawn for a role that was not granted")
} catch {
    check(false, "authority decodes off the live roster: \(error)")
}

do {
    // A roster row from a daemon that predates the field. The whole
    // forward-compatibility story is that this still decodes and renders less.
    let old = try decoder.decode(Agent.self, from: """
    {"name":"a","task":"t","cwd":"","live":true,"busy":false}
    """.data(using: .utf8)!)
    check(old.authority == nil, "a row with no `authority` key decodes")
    check(old.authorityLabel == nil, "and draws no badge")
    check(old.isSysAdmin == false, "and is not privileged, which is the narrower answer and the right one")

    let blank = try decoder.decode(Agent.self, from: """
    {"name":"a","task":"t","cwd":"","live":true,"busy":false,"authority":""}
    """.data(using: .utf8)!)
    check(blank.authorityLabel == nil,
          "an empty string draws no badge either -- a bordered capsule with nothing in it is a bug")

    let future = try decoder.decode(Agent.self, from: """
    {"name":"a","task":"t","cwd":"","live":true,"busy":false,"authority":"release-manager"}
    """.data(using: .utf8)!)
    check(future.authorityLabel == "RELEASE-MANAGER",
          "**a role this build has never heard of renders itself** rather than being dropped")
    check(future.isSysAdmin == false, "without claiming to be the one role the app knows")
}

// ---------------------------------------------------------------------------
print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
