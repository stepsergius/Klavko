import Foundation

/// The emoji and their names in one language (Unicode CLDR, in `Emoji/`): found by a word typed after a colon
/// (":сміх"), offered after a word ("серце" → ❤️), listed in the Quick Actions bar. Skin-tone variants aren't
/// listed, the plain emoji is.
public struct EmojiCatalog: Sendable {
    public struct Entry: Sendable {
        public let emoji: String
        /// What it's called ("червоне серце").
        public let name: String
        public let keywords: [String]
        public var group: Group = .smileys
    }

    /// Unicode's groups, in its order.
    public enum Group: Int, CaseIterable, Sendable {
        case smileys, people, animals, food, travel, activities, objects, symbols, flags
    }

    /// A part of the whole list: the latest used (`group` nil) or a group.
    public struct Section: Sendable, Equatable {
        public let group: Group?
        public let emojis: [String]
    }

    public let language: String
    /// Every emoji, in Unicode's order.
    public let entries: [Entry]

    public init(language: String, entries: [Entry]) {
        self.language = language
        self.entries = entries
    }

    /// The catalog of `language` with the emoji this Mac can show (`maxVersion`: the newest Emoji version it has).
    public static func load(language: String, maxVersion: Double) -> EmojiCatalog? {
        guard let names = file(language), let order = file("order") else { return nil }
        // Lines of "emoji \t version \t group".
        var shown: [String: Group] = [:]
        for line in order.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 3, let version = Double(parts[1]), version <= maxVersion,
               let group = Int(parts[2]).flatMap(Group.init(rawValue:)) {
                shown[String(parts[0])] = group
            }
        }
        return parse(names, language: language, shown: shown)
    }

    /// Lines of "emoji \t name \t keyword|keyword…"; `shown`: the emoji to keep and their groups.
    static func parse(_ text: String, language: String, shown: [String: Group]? = nil) -> EmojiCatalog {
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            let emoji = String(parts[0])
            guard parts.count == 3, let group = shown.map({ $0[emoji] }) ?? .smileys else { continue }
            entries.append(Entry(emoji: emoji, name: normalized(String(parts[1])),
                                 keywords: parts[2].split(separator: "|").map { normalized(String($0)) }, group: group))
        }
        return EmojiCatalog(language: language, entries: entries)
    }

    private static func file(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Emoji") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The emoji whose name or keywords start with `query` (or have it inside, from three letters), the best
    /// first: the whole word, then the start of one; the ones used lately ahead of the rest.
    public func search(_ query: String, recent: [String] = [], limit: Int = 30) -> [String] {
        let query = Self.normalized(query)
        guard !query.isEmpty else { return [] }
        var scored: [(score: Int, index: Int, emoji: String)] = []
        for (index, entry) in entries.enumerated() {
            let nameWords = Self.words(entry.name)
            let score: Int
            // The name, a word of it and a keyword are equally good: "серце" is 🫀 and "smile" is 😼 (a cat with a
            // wry smile), yet people mean ❤️ ("червоне серце") and 😊 (a keyword); the ones used more go first.
            if entry.name == query || nameWords.contains(query) || entry.keywords.contains(query) {
                score = 1
            } else if nameWords.contains(where: { $0.hasPrefix(query) }) {
                score = 2
            } else if entry.keywords.contains(where: { keyword in Self.words(keyword).contains { $0.hasPrefix(query) } }) {
                score = 3
            } else if query.count >= 3, entry.name.contains(query) || entry.keywords.contains(where: { $0.contains(query) }) {
                score = 4
            } else {
                continue
            }
            scored.append((score, index, entry.emoji))
        }
        return ranked(scored, recent: recent, limit: limit)
    }

    /// Better scores first; among equals the ones used lately, then the ones people use most, then Unicode's order.
    private func ranked(_ scored: [(score: Int, index: Int, emoji: String)], recent: [String], limit: Int) -> [String] {
        scored.sorted { a, b in
            if a.score != b.score { return a.score < b.score }
            let ra = recent.firstIndex(of: a.emoji) ?? .max, rb = recent.firstIndex(of: b.emoji) ?? .max
            if ra != rb { return ra < rb }
            let pa = Self.popularity[a.emoji] ?? .max, pb = Self.popularity[b.emoji] ?? .max
            return pa != pb ? pa < pb : a.index < b.index
        }.prefix(limit).map(\.emoji)
    }

    /// The emoji used most, the most first (Unicode's emoji frequency list, 2021).
    private static let popularity: [String: Int] = {
        let popular = ["😂", "❤️", "🤣", "👍", "😭", "🙏", "😘", "🥰", "😍", "😊", "🎉", "😁", "💕", "🥺", "😅", "🔥", "☺️",
                       "🤦", "♥️", "🤷", "🙄", "😆", "🤗", "😉", "🎂", "🤔", "👏", "🙂", "😳", "🥳", "😎", "👌", "💜", "😔",
                       "💪", "✨", "💖", "👀", "😋", "😏", "😢", "👉", "💗", "😩", "💯", "🌹", "💞", "🎈", "💙", "😃", "😡",
                       "💐", "😜", "🙈", "🤞", "😄", "🤤", "🙌", "🤪", "❣️", "😀", "💋", "💀", "👇", "💔", "😌", "💓", "🤩",
                       "🙃", "😬", "😱", "😴", "🤭", "😐", "🌞", "😒", "😇", "🌸", "😈", "🎶", "✌️", "🎊", "🥵", "😞", "💚",
                       "☀️", "🖤", "💰", "😚", "👑", "🎁", "💥", "🙋", "☹️", "😑", "🥴", "👈", "💩", "✅", "👋", "🤮", "😤",
                       "🤢", "🌟", "❗", "😥", "🌈", "💛", "😝", "😫", "😲", "‼️", "🔴", "🌻", "🤯", "💃", "👊", "🤬",
                       "🏃", "😕", "👁️", "⚡", "☕", "🍀", "💦", "⭐", "🦋", "🤨", "🌺", "😹", "🤘", "🌷", "💝", "💤", "🤝",
                       "🐰", "😓", "💘", "🍻", "😟", "😣", "🧐", "😠", "🤠", "😻", "🌙", "😛", "🤙", "🙊"]
        return Dictionary(popular.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// The emoji a whole word means ("серце" → ❤️…): it is their name, a word of the name or a keyword.
    public func matches(word: String, limit: Int = 5) -> [String] {
        let word = Self.normalized(word)
        guard word.count >= 3 else { return [] }
        var scored: [(score: Int, index: Int, emoji: String)] = []
        for (index, entry) in entries.enumerated() {
            if entry.name == word || Self.words(entry.name).contains(word) || entry.keywords.contains(word) {
                scored.append((1, index, entry.emoji))
            }
        }
        return ranked(scored, recent: [], limit: limit)
    }

    /// The order of the Quick Actions list: the latest used first (up to `recentCount`), then all the rest.
    public func listed(recent: [String], recentCount: Int = 5) -> (recent: [String], rest: [String]) {
        let known = Set(entries.map(\.emoji))
        let latest = Array(recent.filter(known.contains).prefix(recentCount))
        let skip = Set(latest)
        return (latest, entries.map(\.emoji).filter { !skip.contains($0) })
    }

    /// The whole list in parts: the latest used (up to `recentCount`, when there are any), then each group.
    public func sections(recent: [String], recentCount: Int = 5) -> [Section] {
        let listed = listed(recent: recent, recentCount: recentCount)
        var result = listed.recent.isEmpty ? [] : [Section(group: nil, emojis: listed.recent)]
        var byGroup: [Group: [String]] = [:]
        for entry in entries { byGroup[entry.group, default: []].append(entry.emoji) }
        for group in Group.allCases {
            if let emojis = byGroup[group], !emojis.isEmpty { result.append(Section(group: group, emojis: emojis)) }
        }
        return result
    }

    /// `list` with `emoji` put first (used just now), at most `limit` kept.
    public static func recorded(_ emoji: String, in list: [String], limit: Int = 30) -> [String] {
        Array(([emoji] + list.filter { $0 != emoji }).prefix(limit))
    }

    /// Lower case, one kind of apostrophe, ё as е: typed however, found the same.
    static func normalized(_ text: String) -> String {
        var result = text.lowercased()
        for apostrophe in ["’", "ʼ", "‘", "`"] { result = result.replacingOccurrences(of: apostrophe, with: "'") }
        return result.replacingOccurrences(of: "ё", with: "е")
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
