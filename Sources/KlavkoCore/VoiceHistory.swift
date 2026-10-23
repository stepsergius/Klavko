import Foundation

/// What was dictated, newest first, kept only on this Mac when the user turns it on.
public struct VoiceHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var text: String
        public var date: Date

        public init(id: UUID = UUID(), text: String, date: Date = Date()) {
            self.id = id
            self.text = text
            self.date = date
        }
    }

    public private(set) var entries: [Entry] = []
    /// The oldest go when there are more.
    public static let limit = 1000

    public init(entries: [Entry] = []) { self.entries = entries }

    /// Adds dictated text on top (empty text is ignored).
    public mutating func add(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Entry(text: trimmed, date: date), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func clear() {
        entries = []
    }
}
