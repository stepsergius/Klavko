import Foundation

/// Quick Actions: a small bar over (or under) text selected with the mouse, with what can be done to it —
/// copy, search, translate, change case, wrap in brackets, read aloud, ask an AI…
public enum QuickAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case openLink, copy, cut, paste, plainPaste, search, youtube, music, translate, ai, speak,
         bold, italic, underline, strikethrough, uppercase, lowercase, capitalize, sentence, brackets, quotes, stats, sum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openLink: tr("Відкрити посилання", "Open Link")
        case .copy: tr("Копіювати", "Copy")
        case .cut: tr("Вирізати", "Cut")
        case .paste: tr("Вставити", "Paste")
        case .plainPaste: tr("Вставити як звичайний текст", "Paste as Plain Text")
        case .search: tr("Шукати в інтернеті", "Search the Web")
        case .youtube: tr("Шукати на YouTube", "Search YouTube")
        case .music: tr("Шукати в Музиці", "Search in Music")
        case .translate: tr("Перекласти", "Translate")
        case .ai: tr("Відкрити в ШІ", "Open in AI")
        case .speak: tr("Прочитати вголос", "Read Aloud")
        case .bold: tr("Жирний", "Bold")
        case .italic: tr("Курсив", "Italic")
        case .underline: tr("Підкреслений", "Underline")
        case .strikethrough: tr("Закреслений", "Strikethrough")
        case .uppercase: tr("ВЕЛИКІ ЛІТЕРИ", "UPPERCASE")
        case .lowercase: tr("малі літери", "lowercase")
        case .capitalize: tr("Кожне Слово З Великої", "Capitalize Each Word")
        case .sentence: tr("Перша велика, решта малі", "Sentence case")
        case .brackets: tr("Дужки", "Brackets")
        case .quotes: tr("Лапки «»", "Quotes «»")
        case .stats: tr("Слова й символи", "Words and Characters")
        case .sum: tr("Сума чисел", "Sum of Numbers")
        }
    }

    /// SF Symbol; nil for the ones shown as words (Copy, Cut, Paste) or as their own glyph.
    public var symbol: String? {
        switch self {
        case .openLink: "arrow.up.forward.square"
        case .copy, .cut, .paste: nil
        case .plainPaste: "doc.plaintext"
        case .search: "magnifyingglass"
        case .youtube: "play.rectangle"
        case .music: "music.note"
        case .translate: "character.bubble"
        case .ai: "sparkles"
        case .speak: "speaker.wave.2"
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .uppercase, .lowercase, .capitalize, .sentence, .brackets, .quotes: nil
        case .stats: "textformat.123"
        case .sum: "sum"
        }
    }

    /// What the button shows when it has no symbol.
    public var label: String {
        switch self {
        case .copy: tr("Копіювати", "Copy")
        case .cut: tr("Вирізати", "Cut")
        case .paste: tr("Вставити", "Paste")
        case .uppercase: "AA"
        case .lowercase: "aa"
        case .capitalize: "Aa"
        case .sentence: "S"
        case .brackets: "( )"
        case .quotes: "« »"
        default: title
        }
    }

    /// Only where text can be typed (a text field, a document), not on a web page or in a PDF.
    public var needsEditable: Bool {
        switch self {
        case .cut, .paste, .plainPaste, .bold, .italic, .underline, .strikethrough,
             .uppercase, .lowercase, .capitalize, .sentence, .brackets, .quotes: true
        default: false
        }
    }

    /// On until the user turns it off in Settings.
    public var onByDefault: Bool {
        switch self {
        case .plainPaste, .bold, .italic, .underline, .strikethrough: false
        default: true
        }
    }
}

/// Where the bar appears.
public enum QuickActionsPosition: String, Codable, CaseIterable, Sendable {
    case above, below

    public var title: String {
        switch self {
        case .above: tr("Над виділеним текстом", "Above the selection")
        case .below: tr("Під виділеним текстом", "Below the selection")
        }
    }
}

/// "Search the Web" goes to this engine.
public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google, duckDuckGo, bing

    public var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    public func url(for query: String) -> URL? {
        let base = switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        }
        return URL(string: base + QuickText.queryEncoded(query))
    }

    public static func youtube(_ query: String) -> URL? {
        URL(string: "https://www.youtube.com/results?search_query=" + QuickText.queryEncoded(query))
    }

    /// A search in the Music app.
    public static func music(_ query: String) -> URL? {
        URL(string: "music://music.apple.com/search?term=" + QuickText.queryEncoded(query))
    }
}

/// An AI chat the selection can be opened in: its Mac app when installed, its website otherwise.
public enum AIService: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, chatGPT, gemini, perplexity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .perplexity: "Perplexity"
        }
    }

    /// The Mac apps, if the service has one, the preferred first: the new ChatGPT app is "com.openai.codex"
    /// ("com.openai.chat" is now ChatGPT Classic).
    public var bundleIDs: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .chatGPT: ["com.openai.codex", "com.openai.chat"]
        case .gemini: []
        case .perplexity: ["ai.perplexity.mac"]
        }
    }

    /// Whether an app with this name is the service's (the Codex app shares the new ChatGPT app's identifier).
    public func isApp(named name: String) -> Bool {
        self != .chatGPT || name.hasPrefix("ChatGPT")
    }

    /// The Mac app opens a new chat on ⌘N (ChatGPT and ChatGPT Classic): pressed before the text is pasted.
    public var newChatWithCommandN: Bool { self == .chatGPT }

    /// A link that opens a new chat in the Mac app with the text already in its message box, when the app has one.
    public func appLink(for text: String) -> URL? {
        switch self {
        case .claude: URL(string: "claude://claude.ai/new?q=" + QuickText.queryEncoded(text) + "&surface=chat")
        default: nil
        }
    }

    /// The website with the text already in the message box, or just the website when it can't take the text
    /// in the address (then the text is pasted there).
    public func webURL(for text: String) -> (url: URL, carriesText: Bool) {
        let query = QuickText.queryEncoded(text)
        switch self {
        case .claude: return (URL(string: "https://claude.ai/new?q=" + query)!, true)
        case .chatGPT: return (URL(string: "https://chatgpt.com/?q=" + query)!, true)
        case .gemini: return (URL(string: "https://gemini.google.com/app")!, false)
        // Its address sends the question at once: the text is pasted instead, to be sent by the user.
        case .perplexity: return (URL(string: "https://www.perplexity.ai/")!, false)
        }
    }

    public static let onByDefault: [AIService] = [.claude, .chatGPT]
}

/// What Quick Actions do to the text itself.
public enum QuickText {
    /// The pairs offered by "Brackets".
    public static let brackets: [(open: String, close: String)] = [("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"), ("/", "/")]

    public static func uppercased(_ text: String, locale: Locale = .current) -> String { text.uppercased(with: locale) }
    public static func lowercased(_ text: String, locale: Locale = .current) -> String { text.lowercased(with: locale) }

    /// Every word starts with a capital letter; the rest of each word stays as it was ("iPhone" stays).
    public static func capitalized(_ text: String, locale: Locale = .current) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            if character.isLetter || character.isNumber {
                result += atWordStart ? String(character).uppercased(with: locale) : String(character)
                atWordStart = false
            } else {
                result.append(character)
                // «п’ять», «будь-який»: one word.
                if !["'", "’", "ʼ", "-"].contains(character) { atWordStart = true }
            }
        }
        return result
    }

    /// Sentence case: the first letter of each sentence capital, every other letter small.
    public static func sentenceCased(_ text: String, locale: Locale = .current) -> String {
        var result = ""
        var atSentenceStart = true
        for character in text {
            if character.isLetter {
                let letter = String(character)
                result += atSentenceStart ? letter.uppercased(with: locale) : letter.lowercased(with: locale)
                atSentenceStart = false
            } else {
                result.append(character)
                if [".", "!", "?", "…"].contains(character) || character.isNewline {
                    atSentenceStart = true
                } else if character.isNumber {
                    atSentenceStart = false
                }
            }
        }
        return result
    }

    /// Around the text, leaving spaces and line ends at its edges outside: "word " → "(word) ".
    public static func wrapped(_ text: String, open: String, close: String) -> String {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let range = text.range(of: core) else { return open + text + close }
        return String(text[..<range.lowerBound]) + open + core + close + String(text[range.upperBound...])
    }

    /// Struck through anywhere, even where the app has no such formatting: a combining stroke after each
    /// character (spaces and line ends stay as they are).
    public static func struckThrough(_ text: String) -> String {
        var result = ""
        for character in text {
            result.append(character)
            if !character.isWhitespace { result.unicodeScalars.append("\u{0336}") }
        }
        return result
    }

    public struct Stats: Equatable, Sendable {
        public let words: Int
        public let characters: Int
        public let charactersWithoutSpaces: Int
    }

    public static func stats(_ text: String) -> Stats {
        Stats(words: VoiceStats.words(in: text).count,
              characters: text.count,
              charactersWithoutSpaces: text.filter { !$0.isWhitespace }.count)
    }

    /// The numbers in the text: "1 234,5", "1,234.5", "-12", "3.75"… A comma or a dot once in a number is the
    /// decimal mark; repeated, or before the other one, it separates thousands, as do no-break spaces between
    /// groups of 3 (an ordinary space separates two numbers: "100 200" is a list).
    public static func numbers(in text: String) -> [Decimal] {
        let pattern = #"(?<![\p{L}\d])[-−]?\d{1,3}(?:[\x{00A0}\x{202F}]\d{3})+(?:[.,]\d+)?(?![\p{L}\d])|(?<![\p{L}\d])[-−]?\d+(?:[.,]\d+)*(?![\p{L}\d])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return number(String(text[range]))
        }
    }

    /// The sum when the text has at least two numbers.
    public static func sum(_ text: String) -> Decimal? {
        let found = numbers(in: text)
        guard found.count >= 2 else { return nil }
        return found.reduce(0, +)
    }

    private static func number(_ raw: String) -> Decimal? {
        var text = raw.replacingOccurrences(of: "−", with: "-")
            .filter { ![" ", "\u{00A0}", "\u{202F}"].contains($0) }
        let commas = text.filter { $0 == "," }.count
        let dots = text.filter { $0 == "." }.count
        if commas > 0, dots > 0 {
            // The later one is the decimal mark.
            let decimal: Character = text.lastIndex(of: ",")! > text.lastIndex(of: ".")! ? "," : "."
            text = String(text.filter { $0 != (decimal == "," ? "." : ",") })
            if decimal == "," { text = text.replacingOccurrences(of: ",", with: ".") }
        } else if commas > 1 {
            text = text.replacingOccurrences(of: ",", with: "")
        } else if dots > 1 {
            text = text.replacingOccurrences(of: ".", with: "")
        } else {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func queryEncoded(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
