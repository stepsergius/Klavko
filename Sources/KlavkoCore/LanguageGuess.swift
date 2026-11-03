import Foundation

/// Which recognizer heard the speech right: the one whose words are real words of its language.
/// ("Привіт це перевірка" is all Ukrainian words; the English recognizer's "Prave, Kaya, Kona" isn't English.)
public enum LanguageGuess {
    /// Share of words (two letters or more) in `text` that the dictionary of `language` knows; 0 if none.
    public static func wordShare(_ text: String, language: String, spellChecker: SpellChecking) -> Double {
        let words = text.split { !($0.isLetter || $0 == "'" || $0 == "’") }
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !words.isEmpty else { return 0 }
        let known = words.filter { spellChecker.isValid($0, language: language) }.count
        return Double(known) / Double(words.count)
    }

    /// Share of words that start with a capital in the middle of a sentence (not the first word, not after
    /// . ! ?, not "I"). Speech in another language heard as English comes out as made-up names:
    /// "Previous Please text my Alicia She was not just enough some McKenzie".
    public static func strayCapitalShare(_ text: String) -> Double {
        var words = 0, stray = 0
        var sentenceStart = true
        for token in text.split(separator: " ") {
            let letters = token.filter(\.isLetter)
            guard !letters.isEmpty else { continue }
            words += 1
            if !sentenceStart, let first = letters.first, first.isUppercase, letters != "I" { stray += 1 }
            sentenceStart = token.last.map { ".!?".contains($0) } ?? false
        }
        return words == 0 ? 0 : Double(stray) / Double(words)
    }

    /// How much `text` reads like real speech in `language`: known words, minus stray capitals.
    public static func score(_ text: String, language: String, spellChecker: SpellChecking) -> Double {
        wordShare(text, language: language, spellChecker: spellChecker) - strayCapitalShare(text)
    }

    /// The candidate whose text reads most like real words of its language. Close calls go to `preferred`.
    public static func best(_ candidates: [(language: String, text: String)], preferred: String,
                            spellChecker: SpellChecking) -> (language: String, text: String)? {
        let scored = candidates
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (candidate: $0, score: score($0.text, language: $0.language, spellChecker: spellChecker)) }
        guard let top = scored.max(by: { $0.score < $1.score }) else { return nil }
        if let favourite = scored.first(where: { $0.candidate.language == preferred }),
           top.score - favourite.score < 0.15 {
            return favourite.candidate
        }
        return top.candidate
    }
}

/// Live recognition after a pause: macOS may start the next phrase from scratch within the same
/// recognition, without marking the previous one final. Spotting that keeps the earlier text.
public enum UtteranceJoiner {
    /// True when `next` is a new phrase rather than a revision of `previous`: `previous` ended in a line break
    /// ("новий рядок", which macOS does itself) that `next` doesn't have, or `next` starts with a different
    /// first word and is much shorter or follows a finished sentence.
    public static func isRestart(previous: String, next: String) -> Bool {
        let ended = previous.trimmingCharacters(in: .whitespaces)
        if ended.last?.isNewline == true { return !next.contains(where: \.isNewline) }
        guard let oldFirst = firstWord(previous), let newFirst = firstWord(next), oldFirst != newFirst else { return false }
        return next.count * 2 < previous.count || ended.last.map { ".!?…".contains($0) } ?? false
    }

    /// `parts` joined with spaces (none after a line break), skipping empty ones.
    public static func join(_ parts: String...) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.reduce("") { joined, part in
            joined.isEmpty ? part : joined + (joined.last!.isNewline || part.first!.isNewline ? "" : " ") + part
        }
    }

    private static func firstWord(_ text: String) -> String? {
        text.split { !$0.isLetter }.first.map { $0.lowercased() }
    }
}

extension LanguageGuess {
    /// Cyrillic text that is Russian rather than Ukrainian: it has ы, э, ъ or ё, or it's long enough to
    /// expect і, ї, є or ґ (frequent in Ukrainian) and has none.
    public static func looksRussian(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let cyrillicWords = lowered.split { !$0.isLetter }.filter { $0.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } }
        guard !cyrillicWords.isEmpty else { return false }
        if lowered.contains(where: { "ыэъё".contains($0) }) { return true }
        return cyrillicWords.count >= 4 && !lowered.contains(where: { "іїєґ".contains($0) })
    }

    /// Text the recognizer wrote in the wrong Latin-script language: letters neither Ukrainian nor English
    /// uses (ř, á, ž, ł, ü…), or Latin and Cyrillic mixed in one word ("texті"). Ukrainian heard as Czech
    /// comes out like "Přiby v texті z opisu".
    public static func looksForeignLatin(_ text: String) -> Bool {
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            var latin = false
            var cyrillic = false
            for scalar in word.unicodeScalars {
                switch scalar.value {
                case 0x00C0...0x024F, 0x1E00...0x1EFF: return true  // accented Latin
                case 0x0041...0x005A, 0x0061...0x007A: latin = true
                case 0x0400...0x04FF: cyrillic = true
                default: break
                }
            }
            if latin && cyrillic { return true }
        }
        return false
    }
}
