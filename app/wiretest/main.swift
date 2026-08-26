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
print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
