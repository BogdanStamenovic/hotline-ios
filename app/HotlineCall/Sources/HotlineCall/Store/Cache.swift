import Foundation
import OSLog

/// The on-disk copy of each agent's transcript.
///
/// **This is a cold-open accelerator, not a database.** The authoritative,
/// indexed, paginated store is on archserver; the phone never queries, it reads
/// the tail and appends. That is the whole reason this is a JSONL segment set
/// rather than SQLite -- SQLite is available as a system library, and it would
/// still be the wrong answer: a schema, migrations, statement lifetimes and a
/// linker setting bought in exchange for query capability nothing here uses,
/// plus a second source of truth to keep honest.
///
/// Form, per agent:
///
///     agents/<key>/head.json     {generation, oldestSeq, newestSeq, segments, bytes}
///     agents/<key>/0001.jsonl    one JSON-encoded Moment per line
///     agents/<key>/0002.jsonl    rotates at 512 KB, at most 4 kept
///
/// Appends are O(1) and crash-tolerant: a torn last line is dropped on read and
/// the history refetch fills the hole. A cold open reads the newest segment
/// only, which is bounded by construction.
///
/// `actor` is the one place in this app where state moves off the main actor,
/// and it is because of file I/O rather than CPU. Everything it hands back is a
/// `Sendable` value.
actor Cache {
    /// What a cold open gets before any network call returns.
    struct Snapshot: Sendable {
        var moments: [Moment] = []
        var generation = 0
        /// Whether anything was on disk at all. `false` and an empty `moments`
        /// mean different things to the thread: nothing cached versus a cached
        /// empty channel.
        var found = false
    }

    private struct Head: Codable {
        var generation: Int
        var oldestSeq: Int
        var newestSeq: Int
        var segments: [String]
        var bytes: Int
    }

    private static let segmentLimit = 512 * 1024
    private static let segmentsKept = 4

    private let root: URL
    private let log = Logger(subsystem: "dev.stamenovic.hotline", category: "cache")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let files = FileManager.default

    init() {
        // Application Support, not Caches: the OS may evict Caches under
        // pressure and the entire point of this is that a channel opens in zero
        // frames.
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appending(path: "hotline", directoryHint: .isDirectory)
    }

    // MARK: - Reading

    /// The newest segment, parsed. Deliberately not the whole history: a cold
    /// open must be bounded, and older pages come back from the server on
    /// demand.
    func load(_ agent: AgentID) -> Snapshot {
        let dir = directory(agent)
        guard let head = head(in: dir), let newest = head.segments.last else {
            return Snapshot()
        }
        var out = Snapshot(moments: [], generation: head.generation, found: true)
        guard let data = try? Data(contentsOf: dir.appending(path: newest)) else { return out }
        out.moments = moments(in: data)
        return out
    }

    /// Every segment, oldest first. Only the older-history path wants this, and
    /// only when the server cannot be reached.
    func loadAll(_ agent: AgentID) -> Snapshot {
        let dir = directory(agent)
        guard let head = head(in: dir) else { return Snapshot() }
        var out = Snapshot(moments: [], generation: head.generation, found: true)
        for segment in head.segments {
            guard let data = try? Data(contentsOf: dir.appending(path: segment)) else { continue }
            out.moments += moments(in: data)
        }
        return out
    }

    /// A torn last line is dropped rather than failing the whole read. The
    /// history refetch fills the hole, so a partial write costs nothing.
    private func moments(in data: Data) -> [Moment] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(Moment.self, from: Data($0))
        }
    }

    // MARK: - Writing

    /// Append a feed page. Batched per page, never per moment.
    func append(_ agent: AgentID, _ batch: [Moment], generation: Int) {
        guard !batch.isEmpty else { return }
        let dir = directory(agent)
        var head = head(in: dir) ?? Head(generation: generation, oldestSeq: batch[0].seq,
                                         newestSeq: batch[0].seq, segments: [], bytes: 0)
        // A generation change means the server's history is not the history
        // this file describes. Start over rather than interleaving two of them.
        if head.generation != generation {
            wipe(dir)
            head = Head(generation: generation, oldestSeq: batch[0].seq,
                        newestSeq: batch[0].seq, segments: [], bytes: 0)
        }
        write(batch, into: dir, head: &head)
        save(head, in: dir)
    }

    /// Replace everything on disk for one agent with an authoritative window.
    /// Used by the hard refresh, so a purge on the server cannot leave stale
    /// rows here.
    func replace(_ agent: AgentID, with moments: [Moment], generation: Int) {
        let dir = directory(agent)
        wipe(dir)
        var head = Head(generation: generation,
                        oldestSeq: moments.first?.seq ?? 0,
                        newestSeq: moments.last?.seq ?? 0,
                        segments: [], bytes: 0)
        write(moments, into: dir, head: &head)
        save(head, in: dir)
    }

    private func write(_ batch: [Moment], into dir: URL, head: inout Head) {
        guard !batch.isEmpty else { return }
        var lines = Data()
        for moment in batch {
            guard let encoded = try? encoder.encode(moment) else { continue }
            lines.append(encoded)
            lines.append(UInt8(ascii: "\n"))
        }
        guard !lines.isEmpty else { return }

        try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        var current = head.segments.last
        if current == nil || size(of: dir.appending(path: current!)) >= Self.segmentLimit {
            current = String(format: "%04d.jsonl", head.segments.count + 1)
            head.segments.append(current!)
        }
        let url = dir.appending(path: current!)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lines)
        } else {
            try? lines.write(to: url)
        }

        // At most four segments. Dropping the oldest loses old history, which
        // is exactly what the server is for.
        while head.segments.count > Self.segmentsKept {
            let stale = head.segments.removeFirst()
            try? files.removeItem(at: dir.appending(path: stale))
        }

        head.oldestSeq = min(head.oldestSeq == 0 ? batch[0].seq : head.oldestSeq, batch[0].seq)
        head.newestSeq = max(head.newestSeq, batch[batch.count - 1].seq)
        head.bytes = head.segments.reduce(0) { $0 + size(of: dir.appending(path: $1)) }
    }

    // MARK: - Deletion

    /// A purge reached us. Exact, and only for this agent.
    func drop(_ agent: AgentID) {
        try? files.removeItem(at: directory(agent))
    }

    /// Settings' "free up space". Non-destructive: nothing on archserver is
    /// touched and the app re-downloads what it needs.
    func dropEverything() {
        try? files.removeItem(at: root)
    }

    /// What "free up space" puts on its label. Real bytes, walked once.
    func bytes() -> Int {
        guard let walk = files.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let url as URL in walk {
            total += ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        }
        return total
    }

    // MARK: - Layout

    /// Agent names come off the wire and end up in a path component. Anything
    /// outside a conservative alphabet is percent-escaped, so a name containing
    /// a separator cannot address a directory that is not its own.
    private func key(_ agent: AgentID) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        let escaped = agent.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return escaped.isEmpty || escaped == "." || escaped == ".." ? "_" : escaped
    }

    private func directory(_ agent: AgentID) -> URL {
        root.appending(path: "agents", directoryHint: .isDirectory)
            .appending(path: key(agent), directoryHint: .isDirectory)
    }

    private func head(in dir: URL) -> Head? {
        guard let data = try? Data(contentsOf: dir.appending(path: "head.json")) else { return nil }
        return try? decoder.decode(Head.self, from: data)
    }

    private func save(_ head: Head, in dir: URL) {
        try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        // Every byte here is re-downloadable, so none of it belongs in a backup.
        var marker = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marker.setResourceValues(values)
        guard let data = try? encoder.encode(head) else { return }
        try? data.write(to: dir.appending(path: "head.json"))
    }

    private func wipe(_ dir: URL) {
        try? files.removeItem(at: dir)
    }

    private func size(of url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }
}
