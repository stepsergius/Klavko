import Foundation

/// Cyrillic in Latin letters by each language's official system, the one its passports use:
/// - uk: Cabinet of Ministers resolution No. 55, 2010 ("Сергій Шевченко" → "Serhii Shevchenko");
/// - ru: ICAO Doc 9303, Russian passports since 2014 ("Юрий Щербаков" → "Iurii Shcherbakov");
/// - be: the national system of 2007, recognized by the UN ("Віцебск" → "Viciebsk", "Гомель" → "Homieĺ");
/// - bg: the law of 2009 ("Щастливец" → "Shtastlivets", "София" → "Sofia");
/// - sr: Serbian Latin ("Ђорђе Чворовић" → "Đorđe Čvorović");
/// - mk: the official system of 2008 ("Ѓорѓи" → "Gjorgji").
public enum Transliteration {
    public static let languages = ["uk", "ru", "be", "bg", "sr", "mk"]

    /// Has letters a transliteration changes.
    public static func applies(to text: String) -> Bool {
        text.contains { $0.isLetter && allLetters.contains(Character($0.lowercased())) }
    }

    /// The language of Cyrillic `text`: by letters only some languages have (і, ў, ы, ђ…), else by the words
    /// `wordShare` knows best among Ukrainian, Russian and Bulgarian; Ukrainian when nothing tells.
    public static func language(of text: String, wordShare: (_ language: String) -> Double = { _ in 0 }) -> String {
        let lower = text.lowercased()
        func has(_ letters: String) -> Bool { lower.contains { letters.contains($0) } }
        if has("ѓќѕ") { return "mk" }
        if has("ђћјљњџ") { return "sr" }
        if has("ў") { return "be" }
        if has("їєґ") { return "uk" }
        if has("і") { return has("ыэё") ? "be" : "uk" }
        if has("ыэё") { return "ru" }
        // Bulgarian ъ is a vowel ("път"); Russian ъ only goes before е ё ю я ("объект").
        if lower.range(of: "ъ(?![еёюя])", options: .regularExpression) != nil { return "bg" }
        let shares = ["uk", "ru", "bg"].map { ($0, wordShare($0)) }
        let best = shares.max { $0.1 < $1.1 }!
        return best.1 > shares[0].1 ? best.0 : "uk"
    }

    /// `text` in Latin letters by the system of `language`; letters of no Cyrillic alphabet stay as they are.
    public static func latin(_ text: String, language: String) -> String {
        var text = text
        if language == "bg" {
            // The law's own exception: the country's name.
            text = text.replacingOccurrences(of: #"(?i)\bбългария\b"#, with: "Bulgaria", options: .regularExpression)
        }
        let table = tables[language] ?? tables["uk"]!
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            let lower = Character(character.lowercased())
            guard var latin = table[lower] else { result.append(character); continue }
            let previous = index > 0 ? Character(characters[index - 1].lowercased()) : nil
            let next = index + 1 < characters.count ? Character(characters[index + 1].lowercased()) : nil
            let atWordStart = previous.map { !$0.isLetter && !apostrophes.contains($0) } ?? true
            switch language {
            case "uk":
                if atWordStart, let start = ukrainianAtWordStart[lower] { latin = start }
                if lower == "г", previous == "з" { latin = "gh" }
            case "be":
                // Е Ё Ю Я: je… at a word's start, after a vowel, an apostrophe, ь or ў; ie… after a consonant.
                if let vowel = belarusianIotated[lower] {
                    let separated = atWordStart || previous.map { "аеёіоуыэюяьў".contains($0) || apostrophes.contains($0) } ?? true
                    latin = (separated ? "j" : "i") + vowel
                }
                // The soft sign marks the consonant before it: ль → ĺ, сь → ś.
                if lower == "ь", let last = result.last, let soft = belarusianSoft[last] {
                    result.removeLast()
                    result.append(soft)
                    continue
                }
            case "bg":
                // -ия at a word's end: -ia ("София" → "Sofia").
                if lower == "я", previous == "и", !(next?.isLetter ?? false) { latin = "a" }
            default:
                break
            }
            if character.isUppercase, !latin.isEmpty {
                // A word in capitals stays in capitals: "ЩУКА" → "SHCHUKA"; otherwise only the first letter: "Щ" → "Shch".
                let neighbours = [index > 0 ? characters[index - 1] : nil, index + 1 < characters.count ? characters[index + 1] : nil]
                let allCaps = neighbours.contains { $0.map { $0.isLetter && $0.isUppercase } ?? false }
                latin = allCaps ? latin.uppercased() : latin.prefix(1).uppercased() + latin.dropFirst()
            }
            result += latin
        }
        return result
    }

    private static let apostrophes: Set<Character> = ["'", "’", "ʼ"]

    private static let tables: [String: [Character: String]] = [
        "uk": [
            "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e", "є": "ie", "ж": "zh", "з": "z",
            "и": "y", "і": "i", "ї": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p",
            "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh",
            "щ": "shch", "ю": "iu", "я": "ia", "ь": "", "'": "", "’": "", "ʼ": "",
        ],
        "ru": [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
            "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
            "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "ie", "ы": "y",
            "ь": "", "э": "e", "ю": "iu", "я": "ia",
        ],
        "be": [
            "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "ie", "ё": "io", "ж": "ž", "з": "z",
            "і": "i", "й": "j", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s",
            "т": "t", "у": "u", "ў": "ŭ", "ф": "f", "х": "ch", "ц": "c", "ч": "č", "ш": "š", "ы": "y", "ь": "",
            "э": "e", "ю": "iu", "я": "ia", "'": "", "’": "", "ʼ": "",
        ],
        "bg": [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "zh", "з": "z", "и": "i", "й": "y",
            "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
            "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sht", "ъ": "a", "ь": "y", "ю": "yu", "я": "ya",
        ],
        "sr": [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "đ", "е": "e", "ж": "ž", "з": "z", "и": "i",
            "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj", "о": "o", "п": "p", "р": "r",
            "с": "s", "т": "t", "ћ": "ć", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "č", "џ": "dž", "ш": "š",
        ],
        "mk": [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ѓ": "gj", "е": "e", "ж": "zh", "з": "z", "ѕ": "dz",
            "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj", "о": "o", "п": "p",
            "р": "r", "с": "s", "т": "t", "ќ": "kj", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch", "џ": "dj",
            "ш": "sh",
        ],
    ]

    private static let allLetters = Set(tables.values.flatMap { $0.keys }.filter(\.isLetter))
    private static let ukrainianAtWordStart: [Character: String] = ["є": "ye", "ї": "yi", "й": "y", "ю": "yu", "я": "ya"]
    private static let belarusianIotated: [Character: String] = ["е": "e", "ё": "o", "ю": "u", "я": "a"]
    private static let belarusianSoft: [Character: Character] = [
        "z": "ź", "l": "ĺ", "n": "ń", "s": "ś", "c": "ć", "Z": "Ź", "L": "Ĺ", "N": "Ń", "S": "Ś", "C": "Ć",
    ]
}
