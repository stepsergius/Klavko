import Foundation

/// A mistake LanguageTool found: where it is in the checked text, what's wrong and how to fix it.
public struct GrammarIssue: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case spelling, grammar, punctuation, style, typography
    }

    /// Where in the text, in UTF-16 units (LanguageTool counts like Java).
    public let offset: Int
    public let length: Int
    /// What's wrong, in the language of the text ("Пропущена кома перед «що»").
    public let message: String
    /// Ways to fix it, the best first; may be empty (then the mistake is only pointed out).
    public let replacements: [String]
    public let kind: Kind
    public let ruleID: String

    public var id: String { "\(offset):\(length):\(ruleID)" }

    public init(offset: Int, length: Int, message: String, replacements: [String], kind: Kind, ruleID: String) {
        self.offset = offset
        self.length = length
        self.message = message
        self.replacements = replacements
        self.kind = kind
        self.ruleID = ruleID
    }

    /// The part of `text` the issue is about; nil when it doesn't fit (the text changed).
    public func range(in text: String) -> Range<String.Index>? {
        let utf16 = text.utf16
        guard offset >= 0, length >= 0, offset + length <= utf16.count,
              let start = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: length, limitedBy: utf16.endIndex),
              let lower = start.samePosition(in: text), let upper = end.samePosition(in: text) else { return nil }
        return lower..<upper
    }
}

/// LanguageTool's answers and fixing text with them.
public enum GrammarCheck {
    /// The language to ask LanguageTool to check in: "uk-UA", "en-US"…; "auto" lets it guess.
    public static func languageCode(for language: String?) -> String {
        switch language {
        case "uk": "uk-UA"
        case "en": "en-US"
        case "de": "de-DE"
        case "pt": "pt-PT"
        case let code? where !code.isEmpty: code
        default: "auto"
        }
    }

    /// The issues in a /v2/check answer, in the order they appear in the text (overlapping ones dropped).
    /// With the checked `text`, fixes given in the dictionary form get the word's ending back.
    public static func issues(fromResponse data: Data, text: String? = nil) throws -> [GrammarIssue] {
        struct Response: Decodable {
            struct Match: Decodable {
                struct Replacement: Decodable { let value: String }
                struct Rule: Decodable {
                    struct Category: Decodable { let id: String }
                    let id: String
                    let issueType: String?
                    let category: Category?
                }
                let message: String
                let offset: Int
                let length: Int
                let replacements: [Replacement]
                let rule: Rule
            }
            let matches: [Match]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var issues: [GrammarIssue] = []
        let utf16 = text?.utf16
        for match in response.matches.sorted(by: { $0.offset < $1.offset }) {
            if let last = issues.last, match.offset < last.offset + last.length { continue }
            var replacements = match.replacements.prefix(5).map(\.value)
            if let utf16, match.offset >= 0, match.offset + match.length <= utf16.count,
               case let start = utf16.index(utf16.startIndex, offsetBy: match.offset),
               let original = String(utf16[start..<utf16.index(start, offsetBy: match.length)]) {
                replacements = replacements.map { inflected($0, like: original) }
            }
            issues.append(GrammarIssue(offset: match.offset, length: match.length, message: match.message,
                                       replacements: replacements,
                                       kind: kind(issueType: match.rule.issueType, category: match.rule.category?.id),
                                       ruleID: match.rule.id))
        }
        return issues
    }

    /// LanguageTool gives some fixes as the dictionary form: «проекті» → «проєкт». When the fix is the start of
    /// the word with a letter or two changed, the word's own ending goes back on: «проєкті».
    static func inflected(_ replacement: String, like original: String) -> String {
        let fix = Array(replacement), word = Array(original)
        guard fix.count >= 3, fix.count < word.count, word[fix.count].isLetter, fix.allSatisfy(\.isLetter) else {
            return replacement
        }
        let changed = zip(fix, word).filter { String($0).lowercased() != String($1).lowercased() }.count
        guard changed <= 2 else { return replacement }
        return replacement + String(word[fix.count...])
    }

    static func kind(issueType: String?, category: String?) -> GrammarIssue.Kind {
        switch (issueType, category) {
        case ("misspelling", _), (_, "TYPOS"): .spelling
        case (_, "PUNCTUATION"): .punctuation
        case ("typographical", _), (_, "TYPOGRAPHY"): .typography
        // Barbarisms come with the word to use instead in its dictionary form («приймаю участь» → «брати»):
        // a suggestion to rephrase, not a fix to put in as is.
        case ("style", _), ("locale-violation", _), (_, "STYLE"), (_, "REDUNDANCY"), (_, "BARBARISM"): .style
        default: .grammar
        }
    }

    /// `text` with the chosen fixes: issue id → the replacement to put in. Issues not in `choices` stay as they are.
    public static func apply(_ choices: [String: String], of issues: [GrammarIssue], to text: String) -> String {
        var result = text
        // From the end, so the earlier offsets still hold.
        for issue in issues.sorted(by: { $0.offset > $1.offset }) {
            guard let replacement = choices[issue.id], let range = issue.range(in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
