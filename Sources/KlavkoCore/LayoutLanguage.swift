import Foundation

/// The language of a keyboard layout when macOS doesn't give it, gives one Klavko doesn't know, or gives one
/// that doesn't match the letters (often so for a layout installed by hand, such as a .keylayout file):
/// from the layout's name, then from the letters its keys type.
public enum LayoutLanguage {
    /// `reported`: the language macOS gives; `names`: the layout's ID and name; `letters`: what its keys type
    /// without Option. nil when nothing tells.
    public static func resolve(reported: String?, names: [String], letters: [String], supported: [String]) -> String? {
        let script = dominantScript(letters)
        if let reported, supported.contains(reported), self.script(of: reported) == script { return reported }
        let guessed = byName(names, script: script) ?? byLetters(Set(letters), script: script)
        return guessed.flatMap { supported.contains($0) ? $0 : nil }
    }

    public static func script(of language: String) -> Script {
        switch language {
        case "uk", "ru": .cyrillic
        case "el": .greek
        case "he": .hebrew
        case "ar": .arabic
        default: .latin
        }
    }

    static func dominantScript(_ letters: [String]) -> Script {
        var counts: [Script: Int] = [:]
        for letter in letters { if let script = Script(of: letter), script != .other { counts[script, default: 0] += 1 } }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }?.key ?? .other
    }

    /// Words in layout names, in English, the language itself and Ukrainian. Russian before English
    /// ("Russian" has "us" in it), so English names only whole words.
    private static let nameHints: [(language: String, hints: [String])] = [
        ("uk", ["ukrain", "україн", "укр"]),
        ("ru", ["russian", "русск", "росій", "рос"]),
        ("de", ["german", "deutsch", "нім"]),
        ("fr", ["french", "français", "francais", "франц"]),
        ("es", ["spanish", "español", "espanol", "іспан"]),
        ("it", ["italian", "italiano", "італ"]),
        ("pt", ["portugu", "brazil", "порту"]),
        ("pl", ["polish", "polski", "польс"]),
        ("tr", ["turkish", "türk", "turk", "турец"]),
        ("el", ["greek", "ελλην", "грец"]),
        ("he", ["hebrew", "עבר", "іврит"]),
        ("ar", ["arabic", "عرب", "араб"]),
        ("en", ["english", "british", "abc", "англ"]),
    ]

    static func byName(_ names: [String], script: Script) -> String? {
        let text = names.joined(separator: " ").lowercased()
        for (language, hints) in nameHints where self.script(of: language) == script {
            if hints.contains(where: text.contains) { return language }
        }
        return nil
    }

    static func byLetters(_ letters: Set<String>, script: Script) -> String? {
        func has(_ any: String) -> Bool { any.contains { letters.contains(String($0)) } }
        switch script {
        case .cyrillic: return has("іїєґ") ? "uk" : has("ыэъё") ? "ru" : nil
        case .greek: return "el"
        case .hebrew: return "he"
        case .arabic: return "ar"
        case .latin:
            if has("ąęłżźśćń") { return "pl" }
            if has("ğşı") { return "tr" }
            if has("ß") { return "de" }
            if has("ñ") { return "es" }
            if has("ãõ") { return "pt" }
            if has("ç") && has("éèà") { return "fr" }
            if has("òìù") { return "it" }
            return has("äöü") ? "de" : "en"
        case .other: return nil
        }
    }
}
