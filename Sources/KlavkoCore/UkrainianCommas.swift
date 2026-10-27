import Foundation

/// Commas LanguageTool misses in Ukrainian (it knows only «але» and «бо»): before «що», «щоб», «якщо», «який»…,
/// and before «як», «де», «коли»… that start a clause with a pronoun («Знаю, де він живе»). Careful rather than
/// complete: nothing at the start of a sentence, after another conjunction or particle, or where a comma is already.
public enum UkrainianCommas {
    /// Always start a clause after a word.
    private static let conjunctions: Set<String> = [
        "що", "щоб", "якщо", "хоча", "оскільки", "ніби", "наче", "неначе", "немов", "немовби", "нібито", "доки",
        "поки", "ніж", "проте", "однак", "зате", "тобто", "а",
    ]
    /// «який» and its forms: a comma before them, or before their preposition («місто, в якому»).
    private static let relatives: Set<String> = [
        "який", "яка", "яке", "які", "якого", "якої", "яких", "якому", "якій", "яким", "якими", "якім", "яку",
        "чий", "чия", "чиє", "чиї", "чийого", "чиєї", "чиїх",
    ]
    /// Start a clause only with a pronoun right after («Перевірка, як воно працює»; but «такий як я» has none).
    private static let questionWords: Set<String> = [
        "як", "де", "куди", "звідки", "коли", "чому", "навіщо", "скільки", "хто",
    ]
    private static let pronouns: Set<String> = [
        "я", "ти", "він", "вона", "воно", "ми", "ви", "вони", "це", "то", "його", "її", "їх", "мене", "тебе", "нас", "вас",
        "мені", "тобі", "нам", "вам", "їм", "йому", "їй",
    ]
    /// After these no comma goes before the next word (it belongs with them).
    private static let noCommaAfter: Set<String> = [
        "і", "й", "та", "а", "але", "чи", "або", "бо", "не", "ні", "ж", "же", "б", "би", "лише", "тільки", "навіть",
        "саме", "то", "тому", "так", "через", "після", "для", "незважаючи", "попри", "аби", "ось", "от", "ну", "хоч",
        "хоча", "якщо", "що", "щоб", "ледве", "такий", "така", "таке", "такі", "таким", "тоді", "там", "тут", "більш",
        "більше", "менш", "менше", "поки", "доки", "ніж", "тобто", "немов", "мов", "наче", "ніби", "ще", "уже", "вже",
        "невідомо", "незрозуміло", "байдуже", "мовляв",
    ]
    private static let prepositions: Set<String> = [
        "в", "у", "на", "за", "про", "до", "з", "із", "зі", "від", "над", "під", "по", "без", "при", "через", "між",
        "перед", "біля", "для", "серед", "крізь", "щодо",
    ]
    /// Pairs that take no comma inside them.
    private static let fixedPairs: Set<String> = ["поки що", "що ж", "що й", "що б", "а саме", "а також", "а то", "ніж що"]

    public static func issues(in text: String) -> [GrammarIssue] {
        let words = Self.words(in: text)
        var issues: [GrammarIssue] = []
        for (index, word) in words.enumerated() where index > 0 {
            let lower = word.text.lowercased()
            let next = index + 1 < words.count ? words[index + 1].text.lowercased() : ""
            guard !fixedPairs.contains(lower + " " + next) else { continue }
            let starts: Bool
            if conjunctions.contains(lower) || relatives.contains(lower) {
                starts = true
            } else if questionWords.contains(lower) {
                starts = pronouns.contains(next)
            } else {
                starts = false
            }
            guard starts else { continue }
            // The comma goes after the word before (or before a preposition that opens the clause).
            var before = index - 1
            if prepositions.contains(words[before].text.lowercased()), relatives.contains(lower) || questionWords.contains(lower) {
                before -= 1
                guard before >= 0 else { continue }
            }
            let previous = words[before]
            let first = words[before + 1]
            guard !noCommaAfter.contains(previous.text.lowercased()), !prepositions.contains(previous.text.lowercased()),
                  // Only spaces between: a comma, a dash or a sentence end is there already.
                  text[previous.range.upperBound..<first.range.lowerBound].allSatisfy({ $0 == " " }) else { continue }
            let span = previous.range.lowerBound..<word.range.upperBound
            let original = String(text[span])
            let fixed = previous.text + ", " + String(text[first.range.lowerBound..<word.range.upperBound])
            let offset = text.utf16.distance(from: text.startIndex, to: span.lowerBound)
            issues.append(GrammarIssue(offset: offset, length: original.utf16.count,
                                       message: "Пропущена кома перед «\(text[first.range])»", replacements: [fixed],
                                       kind: .punctuation, ruleID: "KLAVKO_UK_COMMA"))
        }
        return issues
    }

    /// LanguageTool's issues with these added where they don't overlap one of its own.
    public static func merged(_ issues: [GrammarIssue], with commas: [GrammarIssue]) -> [GrammarIssue] {
        var result = issues
        for comma in commas where !issues.contains(where: {
            $0.offset < comma.offset + comma.length && comma.offset < $0.offset + $0.length
        }) {
            result.append(comma)
        }
        return result.sorted { $0.offset < $1.offset }
    }

    private struct Word {
        let text: String
        let range: Range<String.Index>
    }

    /// Words with the sentence ends between them kept apart: a word after «.» starts over.
    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let inWord = character.isLetter || character == "'" || character == "’" || character == "ʼ"
                || (character == "-" && start != nil)
            if inWord, start == nil { start = index }
            if !inWord, let begin = start {
                words.append(Word(text: String(text[begin..<index]), range: begin..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begin = start { words.append(Word(text: String(text[begin...]), range: begin..<text.endIndex)) }
        return words
    }
}
