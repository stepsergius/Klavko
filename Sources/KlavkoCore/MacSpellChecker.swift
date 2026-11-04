import AppKit

/// Spell checking via the built-in macOS dictionaries (includes words the user taught the system).
/// Everything runs locally; nothing is sent anywhere.
public final class MacSpellChecker: SpellChecking {
    private let checker = NSSpellChecker.shared
    /// Completions per "language:prefix"; prefixes repeat a lot while typing.
    private var completionCache: [String: [String]] = [:]

    public init() {}

    /// The macOS dictionary for a layout language: "pt" is "pt_BR" or "pt_PT" there.
    private var dictionaries: [String: String] = [:]

    private func dictionary(_ language: String) -> String {
        if let known = dictionaries[language] { return known }
        let available = checker.availableLanguages
        let found = available.contains(language) ? language
            : available.first { $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-") } ?? language
        dictionaries[language] = found
        return found
    }

    /// macOS has a dictionary for `language`.
    public func hasDictionary(_ language: String) -> Bool {
        checker.availableLanguages.contains { $0 == language || $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-") }
    }

    /// Languages whose macOS spell check passes any string ("λνπφη" is "correct" Greek), while their
    /// completions are real: a word counts as known there when its own completions include it.
    public static let knownByCompletions: Set<String> = ["el", "he", "ar"]

    public func isValid(_ word: String, language: String) -> Bool {
        if Self.knownByCompletions.contains(language) {
            let lowered = word.lowercased()
            return completions(for: lowered, language: language).contains { $0.lowercased() == lowered }
        }
        let language = dictionary(language)
        let range = checker.checkSpelling(of: word, startingAt: 0, language: language,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    public func hasCompletions(_ prefix: String, language: String) -> Bool {
        !completions(for: prefix, language: language).isEmpty
    }

    public func completions(for prefix: String, language: String) -> [String] {
        let language = dictionary(language)
        let key = language + ":" + prefix
        if let cached = completionCache[key] { return cached }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        let result = checker.completions(forPartialWordRange: range, in: prefix, language: language,
                                         inSpellDocumentWithTag: 0) ?? []
        if completionCache.count > 2000 { completionCache.removeAll() }
        completionCache[key] = result
        return result
    }

    public func correction(for word: String, language: String, context: String) -> String? {
        let language = dictionary(language)
        let (text, range) = Self.place(word, after: context)
        return checker.correction(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0)
    }

    public func guesses(for word: String, language: String, context: String) -> [String] {
        let language = dictionary(language)
        let (text, range) = Self.place(word, after: context)
        return checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0) ?? []
    }

    /// One pass over all words instead of a call per word (hundreds of candidates in a few ms).
    public func validWords(among words: [String], language: String) -> Set<String> {
        guard !words.isEmpty else { return [] }
        if Self.knownByCompletions.contains(language) {
            return Set(words.filter { isValid($0, language: language) })
        }
        let language = dictionary(language)
        // A fixed language: automatic detection would judge each candidate in whatever language it resembles.
        checker.automaticallyIdentifiesLanguages = false
        guard checker.setLanguage(language) else {
            return Set(words.filter { isValid($0, language: language) })
        }
        let text = words.joined(separator: " ")
        let nsText = text as NSString
        var orthography: NSOrthography?
        var wordCount = 0
        let results = checker.check(text, range: NSRange(location: 0, length: nsText.length),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: [:], inSpellDocumentWithTag: 0,
                                    orthography: &orthography, wordCount: &wordCount)
        let misspelled = Set(results.map { nsText.substring(with: $0.range) })
        return Set(words.filter { !misspelled.contains($0) })
    }

    /// The word after its preceding text, so suggestions can take neighbouring words into account.
    private static func place(_ word: String, after context: String) -> (String, NSRange) {
        let prefix = context.isEmpty || context.hasSuffix(" ") ? context : context + " "
        let text = prefix + word
        return (text, NSRange(location: (prefix as NSString).length, length: (word as NSString).length))
    }
}
