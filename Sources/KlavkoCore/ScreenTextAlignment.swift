import Foundation

/// Where a part of a text is among the lines read from the screen. For apps that draw their text themselves
/// (Google Docs): the exact text comes from Accessibility, where it is on screen only from reading the screen,
/// which gets a letter wrong now and then («перевцрка» read as «перевирка»). The two are lined up letter by letter,
/// so a word is found even when it was read wrong.
public enum ScreenTextAlignment {
    /// A piece of one read line: its number and the characters in it.
    public struct Spot: Equatable, Sendable {
        public let line: Int
        public let characters: Range<Int>

        public init(line: Int, characters: Range<Int>) {
            self.line = line
            self.characters = characters
        }
    }

    /// Where `range` (UTF-16 units) of `paragraph` is among `lines`: one spot a line (a word split by a line wrap
    /// has two); empty when it isn't on screen.
    public static func spots(of range: Range<Int>, in paragraph: String, lines: [String]) -> [Spot] {
        let words = Set(Self.words(paragraph))
        // The lines of this paragraph: most of their words are in it.
        let mine = lines.indices.filter { index in
            let lineWords = Self.words(lines[index])
            guard !lineWords.isEmpty else { return false }
            return Double(lineWords.filter(words.contains).count) >= Double(lineWords.count) * 0.5
        }
        guard !mine.isEmpty,
              let lower = characterOffset(range.lowerBound, in: paragraph),
              let upper = characterOffset(range.upperBound, in: paragraph), lower < upper else { return [] }

        // The read lines as one text, a space for each line break; who each character belongs to.
        var read: [Character] = []
        var owner: [(line: Int, index: Int)?] = []
        for line in mine {
            if !read.isEmpty {
                read.append(" ")
                owner.append(nil)
            }
            for (index, character) in lines[line].enumerated() {
                read.append(Self.normalized(character))
                owner.append((line, index))
            }
        }
        let text = paragraph.map(Self.normalized)

        // Each letter of the paragraph → the same letter among the read ones, where they agree.
        let difference = read.difference(from: text)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var match = [Int?](repeating: nil, count: text.count)
        var i = 0, j = 0
        while i < text.count, j < read.count {
            if removed.contains(i) { i += 1 } else if inserted.contains(j) { j += 1 } else {
                match[i] = j
                i += 1
                j += 1
            }
        }

        // The letters read for the range, with the ends taken from the neighbours when those were read wrong.
        var found = (lower..<upper).compactMap { match[$0] }
        guard !found.isEmpty else { return [] }
        if match[lower] == nil, lower > 0, let before = match[lower - 1] { found.append(before + 1) }
        if match[upper - 1] == nil, upper < text.count, let after = match[upper] { found.append(after - 1) }
        var byLine: [Int: (low: Int, high: Int)] = [:]
        for position in found where read.indices.contains(position) {
            guard let (line, index) = owner[position] else { continue }
            let known = byLine[line]
            byLine[line] = (min(known?.low ?? index, index), max(known?.high ?? index, index))
        }
        return byLine.keys.sorted().map { Spot(line: $0, characters: byLine[$0]!.low..<(byLine[$0]!.high + 1)) }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 1 }
    }

    /// Letters read the same way whatever the case or the kind of apostrophe.
    private static func normalized(_ character: Character) -> Character {
        if "'’ʼ‘`".contains(character) { return "'" }
        return Character(character.lowercased())
    }

    private static func characterOffset(_ utf16Offset: Int, in text: String) -> Int? {
        let utf16 = text.utf16
        guard utf16Offset >= 0, utf16Offset <= utf16.count,
              let index = utf16.index(utf16.startIndex, offsetBy: utf16Offset).samePosition(in: text) else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }
}
