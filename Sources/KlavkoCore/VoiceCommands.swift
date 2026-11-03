import Foundation

/// Spoken punctuation and line breaks in dictated text: "до завтра крапка новий абзац дякую" →
/// "до завтра.\n\nДякую". Recognizers write such commands as words; this turns them into what they say.
///
/// A command is a phrase of its own, in exactly this form ("поставив крапку" stays text), and not right after a
/// word that makes it a noun ("ця кома", "a period"). The punctuation a recognizer put around it at the
/// speaker's pauses goes ("Привіт. Кома. Як справи" → "Привіт, як справи"). "Буквально кома" writes the word.
public enum VoiceCommands {
    public enum Mark: Equatable, Sendable {
        /// Sticks to the word before: . , ? ! : ; … ) » ”
        case after(String)
        /// Sticks to the word after: ( « “
        case before(String)
        /// A dash, with spaces round it.
        case dash
        /// A hyphen, with no spaces.
        case hyphen
        /// Line breaks.
        case lines(Int)
    }

    public struct Command: Sendable {
        public let words: [String]
        public let mark: Mark
        public init(_ phrase: String, _ mark: Mark) {
            words = phrase.split(separator: " ").map(String.init)
            self.mark = mark
        }
    }

    /// The commands of a language, as shown in Settings too; only Ukrainian and English for now.
    public static func commands(for language: String) -> [Command] {
        switch language {
        case "uk": ukrainian
        case "en": english
        default: []
        }
    }

    private static let ukrainian: [Command] = [
        Command("крапка з комою", .after(";")),
        Command("три крапки", .after("…")),
        Command("трикрапка", .after("…")),
        Command("крапка", .after(".")),
        Command("кома", .after(",")),
        Command("знак питання", .after("?")),
        Command("знак запитання", .after("?")),
        Command("знак оклику", .after("!")),
        Command("двокрапка", .after(":")),
        Command("тире", .dash),
        // How recognizers hear "тире" and "крапка" at the end of a phrase: forms no sentence has.
        Command("тере", .dash),
        Command("тіре", .dash),
        Command("даре", .dash),
        Command("дире", .dash),
        Command("крапко", .after(".")),
        Command("дефіс", .hyphen),
        Command("відкрити лапки", .before("«")),
        Command("відкрий лапки", .before("«")),
        Command("закрити лапки", .after("»")),
        Command("закрий лапки", .after("»")),
        // How recognizers hear them.
        Command("відкрила бки", .before("«")),
        Command("відкрили бки", .before("«")),
        Command("відкрила лапки", .before("«")),
        Command("відкрили лапки", .before("«")),
        Command("відкриті лапки", .before("«")),
        Command("відкрите лапки", .before("«")),
        Command("закрила бки", .after("»")),
        Command("закрили бки", .after("»")),
        Command("закрила лапки", .after("»")),
        Command("закрили лапки", .after("»")),
        Command("закриті лапки", .after("»")),
        Command("закрите лапки", .after("»")),
        Command("відкрити дужку", .before("(")),
        Command("відкрий дужку", .before("(")),
        Command("закрити дужку", .after(")")),
        Command("закрий дужку", .after(")")),
        // How recognizers hear them ("душку"), and the plural.
        Command("відкрити дужки", .before("(")),
        Command("відкрити душку", .before("(")),
        Command("відкрити душки", .before("(")),
        Command("відкрий дужки", .before("(")),
        Command("відкрий душку", .before("(")),
        Command("відкрий душки", .before("(")),
        Command("відкрила дужки", .before("(")),
        Command("відкрила душку", .before("(")),
        Command("відкрила душки", .before("(")),
        Command("відкрила дужку", .before("(")),
        Command("відкрили дужки", .before("(")),
        Command("відкрили душку", .before("(")),
        Command("відкрили душки", .before("(")),
        Command("відкрили дужку", .before("(")),
        Command("закрити дужки", .after(")")),
        Command("закрити душку", .after(")")),
        Command("закрити душки", .after(")")),
        Command("закрий дужки", .after(")")),
        Command("закрий душку", .after(")")),
        Command("закрий душки", .after(")")),
        Command("закрила дужки", .after(")")),
        Command("закрила душку", .after(")")),
        Command("закрила душки", .after(")")),
        Command("закрила дужку", .after(")")),
        Command("закрили дужки", .after(")")),
        Command("закрили душку", .after(")")),
        Command("закрили душки", .after(")")),
        Command("закрили дужку", .after(")")),
        Command("новий рядок", .lines(1)),
        Command("з нового рядка", .lines(1)),
        Command("новий абзац", .lines(2)),
        Command("з нового абзацу", .lines(2)),
    ]

    private static let english: [Command] = [
        Command("full stop", .after(".")),
        Command("period", .after(".")),
        Command("comma", .after(",")),
        Command("question mark", .after("?")),
        Command("exclamation mark", .after("!")),
        Command("exclamation point", .after("!")),
        Command("semicolon", .after(";")),
        Command("colon", .after(":")),
        Command("ellipsis", .after("…")),
        Command("dash", .dash),
        Command("hyphen", .hyphen),
        Command("open quote", .before("“")),
        Command("close quote", .after("”")),
        Command("open bracket", .before("(")),
        Command("close bracket", .after(")")),
        Command("open parenthesis", .before("(")),
        Command("close parenthesis", .after(")")),
        Command("new line", .lines(1)),
        Command("new paragraph", .lines(2)),
    ]

    /// Words after which a command word is a noun in the sentence.
    private static let nounSignals: Set<String> = [
        "ця", "та", "ось", "одна", "кожна", "потрібна", "зайва", "стоїть", "і", "й", "моя", "твоя", "наша", "ваша",
        "a", "an", "the", "this", "that", "one", "each", "every", "per", "of", "my", "your", "his", "her", "its", "our", "their",
    ]
    private static let literally: Set<String> = ["буквально", "literally"]

    /// What a recognizer may have put at a pause round a command.
    private static let pauseMarks: Set<Character> = [",", ".", ";", ":", "!", "?", "…"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?"]

    /// `text` with the commands of `languages` done.
    public static func apply(_ text: String, languages: [String]) -> String {
        var commands = languages.flatMap(commands(for:))
        guard !commands.isEmpty else { return text }
        // Longer phrases first: "крапка з комою" before "крапка".
        commands.sort { $0.words.count > $1.words.count }
        var result = text
        var searchFrom = result.startIndex
        while let found = nextCommand(in: result, from: searchFrom, commands: commands) {
            switch found {
            case .literal(let escape, let phraseEnd):
                // "буквально кома": the words stay, the escape goes.
                var cut = escape.upperBound
                while cut < result.endIndex, result[cut].isWhitespace { cut = result.index(after: cut) }
                let end = result.distance(from: result.startIndex, to: phraseEnd) - result.distance(from: escape.lowerBound, to: cut)
                result.removeSubrange(escape.lowerBound..<cut)
                searchFrom = result.index(result.startIndex, offsetBy: end)
            case .command(let range, let mark):
                let (replaced, resume) = replace(range, with: mark, in: result, after: searchFrom)
                result = replaced
                searchFrom = resume
            }
        }
        return result
    }

    private enum Found {
        case command(Range<String.Index>, Mark)
        /// The escape word's range; the command after it, up to `phraseEnd`, is text.
        case literal(Range<String.Index>, phraseEnd: String.Index)
    }

    private static func nextCommand(in text: String, from start: String.Index, commands: [Command]) -> Found? {
        let words = Self.words(in: text, from: start)
        for (i, word) in words.enumerated() {
            for command in commands where command.words.count <= words.count - i {
                let candidate = words[i..<(i + command.words.count)]
                guard zip(candidate, command.words).allSatisfy({ text[$0.0].lowercased() == $0.1 }) else { continue }
                // Words in between must be only spaces: "знак, питання" isn't one phrase.
                guard zip(candidate.dropFirst(), candidate.dropLast()).allSatisfy({ text[$0.1.upperBound..<$0.0.lowerBound].allSatisfy(\.isWhitespace) })
                else { continue }
                let previous = previousWord(in: text, before: word.lowerBound)
                if let previous, literally.contains(text[previous].lowercased()) { return .literal(previous, phraseEnd: candidate.last!.upperBound) }
                if let previous, nounSignals.contains(text[previous].lowercased()),
                   text[previous.upperBound..<word.lowerBound].allSatisfy(\.isWhitespace) { continue }
                return .command(word.lowerBound..<candidate.last!.upperBound, command.mark)
            }
        }
        return nil
    }

    /// Puts `mark` in place of the command at `range`, with the pause marks round it gone.
    /// Marks before `floor` were put in by earlier commands and stay.
    private static func replace(_ range: Range<String.Index>, with mark: Mark, in text: String,
                                after floor: String.Index) -> (String, String.Index) {
        var left = range.lowerBound
        while left > floor, case let c = text[text.index(before: left)], c.isWhitespace && !c.isNewline || pauseMarks.contains(c) {
            left = text.index(before: left)
        }
        var right = range.upperBound
        var pauseEndedSentence = false
        var sentenceEnd: Character?
        while right < text.endIndex, case let c = text[right], c.isWhitespace && !c.isNewline || pauseMarks.contains(c) {
            if sentenceEnds.contains(c) { pauseEndedSentence = true; sentenceEnd = c }
            right = text.index(after: right)
        }
        let before = String(text[..<left])
        var after = String(text[right...])
        let hasBefore = !(before.last?.isNewline ?? true)
        let hasAfter = !(after.first?.isNewline ?? true) && !after.isEmpty
        let nextSticks = after.first.map { pauseMarks.contains($0) || ")»”".contains($0) } ?? false
        var middle: String
        var capitalize = false
        switch mark {
        case .after(let sign):
            // A closing quote or bracket ends what's inside, not the sentence: its full stop stays after it.
            let closes = ")»”".contains(sign)
            middle = sign + (closes ? sentenceEnd.map(String.init) ?? "" : "") + (hasAfter && !nextSticks ? " " : "")
            capitalize = (sign.last.map(sentenceEnds.contains) ?? false) || (closes && sentenceEnd != nil)
        case .before(let sign):
            middle = (hasBefore ? " " : "") + sign
        case .dash:
            middle = (hasBefore ? " " : "") + "—" + (hasAfter ? " " : "")
        case .hyphen:
            middle = "-"
        case .lines(let count):
            middle = String(repeating: "\n", count: count)
            capitalize = true
        }
        if let first = after.first, first.isLetter {
            if capitalize, first.isLowercase {
                after = first.uppercased() + after.dropFirst()
            } else if !capitalize, pauseEndedSentence, first.isUppercase, after.dropFirst().first?.isLowercase ?? true {
                // The recognizer took the pause for the end of a sentence: "Привіт. Кома. Як справи".
                after = first.lowercased() + after.dropFirst()
            }
        }
        let result = before + middle + after
        let done = before.count + middle.count - (middle.last == " " ? 1 : 0)
        return (result, result.index(result.startIndex, offsetBy: done))
    }

    private static func words(in text: String, from start: String.Index) -> [Range<String.Index>] {
        var words: [Range<String.Index>] = []
        var index = start
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else { index = text.index(after: index); continue }
            let begin = index
            while index < text.endIndex, isWordCharacter(text[index]) { index = text.index(after: index) }
            words.append(begin..<index)
        }
        return words
    }

    private static func previousWord(in text: String, before index: String.Index) -> Range<String.Index>? {
        var end = index
        while end > text.startIndex, !isWordCharacter(text[text.index(before: end)]) { end = text.index(before: end) }
        guard end > text.startIndex else { return nil }
        var begin = end
        while begin > text.startIndex, isWordCharacter(text[text.index(before: begin)]) { begin = text.index(before: begin) }
        return begin..<end
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
}
