import Foundation

/// The user's own spellings for dictated words: what recognition hears → how the user writes it
/// ("зсу" → "ЗСУ"). Learned from corrections after dictation and taken from the text replacements.
public enum VoiceVocabulary {
    /// `text` with every rule applied to whole words (or phrases), ignoring case.
    /// A lowercase spelling at the start of a sentence gets its capital: "київ" → "Київ".
    public static func apply(_ text: String, rules: [Replacement]) -> String {
        var result = text
        // Longer phrases first, so "Нова пошта" wins over "пошта".
        for rule in rules.sorted(by: { $0.from.count > $1.from.count }) {
            let from = rule.from.trimmingCharacters(in: .whitespaces)
            guard from.contains(where: \.isLetter), !rule.to.isEmpty else { continue }
            result = replaceWholeWords(from, with: rule.to, in: result)
        }
        return result
    }

    private static func replaceWholeWords(_ phrase: String, with spelling: String, in text: String) -> String {
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: phrase, options: [.caseInsensitive]) {
            let before = range.lowerBound > rest.startIndex ? rest[rest.index(before: range.lowerBound)] : nil
            let after = range.upperBound < rest.endIndex ? rest[range.upperBound] : nil
            // Already in the text before: the character in front belongs to what's done.
            let previous = before ?? result.last
            let bounded = !(previous.map(isWordCharacter) ?? false) && !(after.map(isWordCharacter) ?? false)
            result += rest[..<range.lowerBound]
            if bounded {
                let found = rest[range]
                var replacement = spelling
                if let first = found.first, first.isUppercase, let own = spelling.first, own.isLowercase {
                    replacement = own.uppercased() + spelling.dropFirst()
                }
                result += replacement
            } else {
                result += rest[range]
            }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’" || character == "ʼ"
    }

    // MARK: - Learning from corrections

    /// Words the user changed in dictated text: compares what was inserted with the text there now
    /// (the field around the insertion) and returns each word replaced by one other word.
    /// Rewritten phrases, additions, deletions and punctuation-only changes are not corrections.
    /// The same word with exactly one letter in another case.
    static func differsInOneLettersCase(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count else { return false }
        return zip(x, y).filter { $0 != $1 }.count == 1
    }

    public static func corrections(inserted: String, now current: String) -> [Replacement] {
        let old = words(inserted)
        let new = words(current)
        guard !old.isEmpty, !new.isEmpty, old.count <= 400, new.count <= 2000 else { return [] }
        let oldKeys = old.map(key)
        let newKeys = new.map(key)

        // Longest common subsequence of the words, case ignored.
        let n = old.count, m = new.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = oldKeys[i] == newKeys[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        // Too little of the dictated text is still there: it isn't the same text any more.
        guard Double(table[0][0]) >= Double(n) * 0.5 else { return [] }

        // Walk the alignment and collect the gaps between matched words.
        var pairs: [(old: Int, new: Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if oldKeys[i] == newKeys[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // With where each one starts in the dictated text, so they come out in reading order.
        var found: [(at: Int, rule: Replacement)] = []
        // Case-only changes are matches in the alignment ("зсу" = "ЗСУ"); they count too,
        // except one letter's case ("київ" → "Київ", "Ми" → "ми"): that's just a capital, not a spelling.
        for pair in pairs where plain(old[pair.old]) != plain(new[pair.new]) && !differsInOneLettersCase(old[pair.old], new[pair.new]) {
            found.append((pair.old, Replacement(from: old[pair.old], to: new[pair.new])))
        }
        // Real gaps: matched words on both sides inside the dictated text; one word for one word.
        for (left, right) in zip(pairs, pairs.dropFirst()) {
            let oldGap = Array(old[(left.old + 1)..<right.old])
            let newGap = Array(new[(left.new + 1)..<right.new])
            guard oldGap.count == 1, newGap.count == 1 else { continue }
            found.append((left.old + 1, Replacement(from: oldGap.joined(separator: " "), to: newGap.joined(separator: " "))))
        }
        // A changed first or last word: the gap has a match on one side only, same word count.
        if let first = pairs.first, first.old == 1, first.new >= 1 {
            let oldGap = old[0..<first.old]
            let newGap = new[(first.new - first.old)..<first.new]
            if oldGap.map(key) != newGap.map(key) {
                found.append((0, Replacement(from: oldGap.joined(separator: " "), to: newGap.joined(separator: " "))))
            }
        }
        if let last = pairs.last, n - 1 - last.old == 1, m - 1 - last.new >= 1 {
            let count = n - 1 - last.old
            let oldGap = old[(last.old + 1)...]
            let newGap = new[(last.new + 1)..<(last.new + 1 + count)]
            if oldGap.map(key) != newGap.map(key) {
                found.append((last.old + 1, Replacement(from: oldGap.joined(separator: " "), to: newGap.joined(separator: " "))))
            }
        }
        var seen = Set<Replacement>()
        return found.sorted { $0.at < $1.at }.map(\.rule).filter { plain($0.from) != plain($0.to) && seen.insert($0).inserted }
    }

    /// Apostrophes all alike: «дев'ять» and «дев’ять» are the same word, whichever one the app typed.
    private static func plain(_ word: String) -> String {
        String(word.map { TextRules.apostrophes.contains($0) ? "’" : $0 })
    }

    private static func key(_ word: String) -> String {
        plain(word).lowercased()
    }

    /// Words with their inner apostrophes and hyphens, without the punctuation around them.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let word = token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            return word.contains(where: { $0.isLetter || $0.isNumber }) ? word : nil
        }
    }
}
