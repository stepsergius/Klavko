import Foundation

/// The language of Klavko's own windows and menus, chosen in Settings (independent of the macOS language).
/// Ukrainian and English are written inline at every call site (`tr("…", "…")`); the other languages
/// translate the English text through the tables in `Translations/`.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case ukrainian = "uk"
    case english = "en"
    case russian = "ru"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case polish = "pl"
    case turkish = "tr"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"

    /// Set from Settings at launch and whenever it changes.
    nonisolated(unsafe) public static var current: AppLanguage = .systemDefault

    /// The first macOS preferred language Klavko speaks, English otherwise.
    public static var systemDefault: AppLanguage {
        for preferred in Locale.preferredLanguages {
            if let language = allCases.first(where: { preferred == $0.rawValue || preferred.hasPrefix($0.rawValue + "-") }) {
                return language
            }
        }
        return .english
    }

    /// Its own name, as shown in the picker.
    public var title: String {
        switch self {
        case .ukrainian: "Українська"
        case .english: "English"
        case .russian: "Русский"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .polish: "Polski"
        case .turkish: "Türkçe"
        case .chinese: "简体中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    /// For dates and numbers.
    public var locale: Locale {
        switch self {
        case .ukrainian: Locale(identifier: "uk_UA")
        case .english: Locale(identifier: "en_US")
        case .portuguese: Locale(identifier: "pt_BR")
        default: Locale(identifier: rawValue)
        }
    }

    /// English text -> text in this language; nil for Ukrainian and English, which are written inline.
    public var translations: [String: String]? {
        switch self {
        case .ukrainian, .english: nil
        case .russian: Translations.russian
        case .spanish: Translations.spanish
        case .french: Translations.french
        case .german: Translations.german
        case .italian: Translations.italian
        case .portuguese: Translations.portuguese
        case .polish: Translations.polish
        case .turkish: Translations.turkish
        case .chinese: Translations.chinese
        case .japanese: Translations.japanese
        case .korean: Translations.korean
        }
    }
}

/// Translation tables, one file per language in `Translations/`, keyed by the English text.
public enum Translations {}

/// The text in the current interface language: `tr("Налаштування", "Settings")`.
/// A language without a translation for the text shows the English.
public func tr(_ ukrainian: String, _ english: String) -> String {
    switch AppLanguage.current {
    case .ukrainian: ukrainian
    case .english: english
    case let language: language.translations?[english] ?? english
    }
}

/// `tr` with values: each `%@` in the text is replaced by the next value, `%1$@`, `%2$@` by the numbered one
/// (so a translation can change their order). `trFormat("Прибрати «%@»", "Remove “%@”", word)`
public func trFormat(_ ukrainian: String, _ english: String, _ values: String...) -> String {
    let template = tr(ukrainian, english)
    var result = "", next = 0
    var rest = Substring(template)
    while let percent = rest.firstIndex(of: "%") {
        result += rest[..<percent]
        let tail = rest[rest.index(after: percent)...]
        if tail.hasPrefix("@") {
            result += next < values.count ? values[next] : ""
            next += 1
            rest = tail.dropFirst()
        } else if let dollar = tail.firstIndex(of: "$"), let number = Int(tail[..<dollar]),
                  tail[tail.index(after: dollar)...].hasPrefix("@") {
            result += number >= 1 && number <= values.count ? values[number - 1] : ""
            rest = tail[tail.index(dollar, offsetBy: 2)...]
        } else {
            result += "%"
            rest = tail
        }
    }
    return result + rest
}
