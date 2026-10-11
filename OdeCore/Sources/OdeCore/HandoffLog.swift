import Foundation

/// Pending handoffs and the append-only kept log, stored as JSON beside Ode's other data.
public struct HandoffLog: Sendable {
    private let pendingURL: URL
    private let keptURL: URL
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        pendingURL = directory.appendingPathComponent("handoffs.json")
        keptURL = directory.appendingPathComponent("kept.json")
    }

    public func pending() throws -> [Handoff] { try read(pendingURL) }

    /// Keeps the earlier of two handoffs to one conversation, so a later copy never hides a send already made.
    /// Pending handoffs live a day at most, so an unreadable file is replaced rather than allowed to block logging.
    public func record(_ handoff: Handoff) throws {
        let existing = (try? pending()) ?? []
        guard !existing.contains(where: { $0.conversationID == handoff.conversationID }) else { return }
        try write(existing + [handoff], to: pendingURL)
    }

    public func replacePending(_ handoffs: [Handoff]) throws {
        try write(handoffs, to: pendingURL)
    }

    public func kept() throws -> [Kept] { try read(keptURL) }

    public func appendKept(_ new: [Kept]) throws {
        let existing = try kept()
        let fresh = new.filter { event in
            !existing.contains { $0.conversationID == event.conversationID && $0.messageID == event.messageID }
        }
        guard !fresh.isEmpty else { return }
        try write(existing + fresh, to: keptURL)
    }

    private func read<T: Decodable>(_ url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([T].self, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: [T], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
