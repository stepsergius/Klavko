import Foundation

/// How much the user dictates, kept only on this Mac: words, characters, time spent dictating and the number of
/// times voice input was turned on, by day; the most frequent words by month (and today); and how fast the user
/// types on the keyboard (key counts and time only, never what was typed), to estimate the time dictation saved.
public struct VoiceStats: Codable, Equatable, Sendable {
    public struct Counts: Codable, Equatable, Sendable {
        public var words = 0
        public var characters = 0
        public var seconds: Double = 0
        public var starts = 0

        public init(words: Int = 0, characters: Int = 0, seconds: Double = 0, starts: Int = 0) {
            self.words = words
            self.characters = characters
            self.seconds = seconds
            self.starts = starts
        }

        static func + (a: Counts, b: Counts) -> Counts {
            Counts(words: a.words + b.words, characters: a.characters + b.characters,
                   seconds: a.seconds + b.seconds, starts: a.starts + b.starts)
        }
    }

    /// Today, this calendar month, this calendar year, or everything.
    public enum Period: String, CaseIterable, Sendable {
        case day, month, year, all
    }

    /// The word counts that open the congratulations window.
    public static let milestones = [1_000, 10_000, 50_000, 100_000, 500_000, 1_000_000]
    /// Until Klavko has measured the user's own speed: about 40 words a minute (an average typist; Ukrainian
    /// words are longer than English, so a little under the ~52 wpm measured for English typing tests).
    public static let defaultCharactersPerMinute: Double = 200
    /// Enough typing measured to trust it.
    public static let measuredEnough = 1_500

    /// Keyed "2026-10-26".
    public private(set) var days: [String: Counts] = [:]
    /// Keyed "2026-10": lowercased word → times dictated (words of 3 letters and more).
    public private(set) var monthWords: [String: [String: Int]] = [:]
    /// Today's words only, keyed by the day.
    public private(set) var dayWords: [String: [String: Int]] = [:]
    /// Keys that type a character, and the time spent typing them (pauses over 2 s left out).
    public private(set) var typedCharacters = 0
    public private(set) var typingSeconds: Double = 0
    /// The last milestone the user was congratulated on.
    public private(set) var lastMilestone = 0

    public init() {}

    // MARK: Counting

    /// Voice input turned on.
    public mutating func addStart(at date: Date = Date(), calendar: Calendar = .current) {
        days[Self.dayKey(date, calendar), default: Counts()].starts += 1
    }

    /// Time spent listening (cancelled recordings too).
    public mutating func addListening(_ seconds: Double, at date: Date = Date(), calendar: Calendar = .current) {
        guard seconds > 0 else { return }
        days[Self.dayKey(date, calendar), default: Counts()].seconds += seconds
    }

    /// Dictated text that was inserted. Returns the milestone just reached, if any.
    @discardableResult
    public mutating func addInserted(_ text: String, at date: Date = Date(), calendar: Calendar = .current) -> Int? {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return nil }
        let day = Self.dayKey(date, calendar)
        days[day, default: Counts()].words += words.count
        days[day, default: Counts()].characters += text.count
        // Today's words only: older days live on in their month.
        dayWords = dayWords.filter { $0.key >= day }
        let month = String(day.prefix(7))
        for word in words where word.count >= 3 {
            let key = word.lowercased()
            monthWords[month, default: [:]][key, default: 0] += 1
            dayWords[day, default: [:]][key, default: 0] += 1
        }
        let total = counts(.all, now: date, calendar: calendar).words
        guard let reached = Self.milestones.last(where: { $0 <= total }), reached > lastMilestone else { return nil }
        lastMilestone = reached
        return reached
    }

    /// A key typed on the keyboard, `interval` seconds after the one before. Pauses of 2 s and longer are not
    /// typing time.
    public mutating func addKey(printable: Bool, interval: Double?) {
        if let interval, interval > 0, interval < 2 { typingSeconds += interval }
        if printable { typedCharacters += 1 }
    }

    /// Both in one: what was kept on disk and what was counted before it could be read.
    public func merged(with other: VoiceStats) -> VoiceStats {
        var result = self
        result.days.merge(other.days, uniquingKeysWith: +)
        for (month, words) in other.monthWords { result.monthWords[month, default: [:]].merge(words, uniquingKeysWith: +) }
        for (day, words) in other.dayWords { result.dayWords[day, default: [:]].merge(words, uniquingKeysWith: +) }
        if let today = result.dayWords.keys.max() { result.dayWords = result.dayWords.filter { $0.key == today } }
        result.typedCharacters += other.typedCharacters
        result.typingSeconds += other.typingSeconds
        result.lastMilestone = max(lastMilestone, other.lastMilestone)
        return result
    }

    // MARK: Reading

    public func counts(_ period: Period, now: Date = Date(), calendar: Calendar = .current) -> Counts {
        let prefix = Self.prefix(period, now, calendar)
        return days.filter { $0.key.hasPrefix(prefix) }.values.reduce(Counts(), +)
    }

    /// The most frequent words of 3 letters and more, most frequent first (ties alphabetically).
    public func topWords(_ period: Period, limit: Int = 10, now: Date = Date(),
                         calendar: Calendar = .current) -> [(word: String, count: Int)] {
        var merged: [String: Int] = [:]
        if period == .day {
            merged = dayWords[Self.dayKey(now, calendar)] ?? [:]
        } else {
            let prefix = Self.prefix(period, now, calendar)
            for (month, words) in monthWords where month.hasPrefix(prefix) {
                merged.merge(words, uniquingKeysWith: +)
            }
        }
        return merged.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { (word: $0.key, count: $0.value) }
    }

    /// The user's own typing speed once measured enough, nil before.
    public var measuredCharactersPerMinute: Double? {
        guard typedCharacters >= Self.measuredEnough, typingSeconds > 0 else { return nil }
        return Double(typedCharacters) / typingSeconds * 60
    }

    public var charactersPerMinute: Double { measuredCharactersPerMinute ?? Self.defaultCharactersPerMinute }

    /// About how long typing the dictated text would have taken, less the time spent dictating (never below 0).
    public func savedSeconds(_ counts: Counts) -> Double {
        max(Double(counts.characters) / charactersPerMinute * 60 - counts.seconds, 0)
    }

    // MARK: Helpers

    /// Words: runs of letters and digits, with apostrophes and hyphens inside them («п’ять», «будь-який»),
    /// and decimal marks inside numbers («35,5» is one).
    public static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let joiners: Set<Character> = ["'", "’", "ʼ", "-"]
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if joiners.contains(character), !current.isEmpty {
                current.append(character)
            } else if character == "," || character == ".", current.last?.isNumber == true {
                current.append(character)
            } else {
                flush(&current, into: &words)
            }
        }
        flush(&current, into: &words)
        return words
    }

    private static func flush(_ current: inout String, into words: inout [String]) {
        while let last = current.last, !(last.isLetter || last.isNumber) { current.removeLast() }
        if !current.isEmpty { words.append(current) }
        current = ""
    }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func prefix(_ period: Period, _ now: Date, _ calendar: Calendar) -> String {
        let day = dayKey(now, calendar)
        switch period {
        case .day: return day
        case .month: return String(day.prefix(7))
        case .year: return String(day.prefix(4))
        case .all: return ""
        }
    }
}
