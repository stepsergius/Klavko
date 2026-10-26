import Foundation
import KlavkoCore

/// The voice input statistics on disk: ~/Library/Application Support/Klavko/voice-stats.json (this Mac only).
@MainActor
final class VoiceStatsStore: ObservableObject {
    @Published private(set) var stats = VoiceStats()
    /// A word milestone just reached (1 000, 10 000…): time to congratulate.
    var onMilestone: (Int) -> Void = { _ in }

    private let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Klavko/voice-stats.json")
    }()
    /// Off for the developer's sample statistics, which must never overwrite the real ones.
    private var persists = true
    private var lastKey: UInt64?
    private var typingUnsaved = false
    private var saveTimer: Timer?

    init() {
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(VoiceStats.self, from: data) {
            stats = stored
        }
        // Typing is counted key by key: written down once a minute, not on every key.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.typingUnsaved else { return }
                self.save()
            }
        }
    }

    func started() {
        stats.addStart()
        save()
    }

    func listened(_ seconds: Double) {
        stats.addListening(seconds)
        save()
    }

    func inserted(_ text: String) {
        let milestone = stats.addInserted(text)
        save()
        if let milestone { onMilestone(milestone) }
    }

    /// A key pressed on the keyboard, at its event time (nanoseconds since startup).
    func key(at nanoseconds: UInt64, printable: Bool) {
        let interval = lastKey.map { nanoseconds > $0 ? Double(nanoseconds - $0) / 1e9 : 0 }
        lastKey = nanoseconds
        stats.addKey(printable: printable, interval: interval)
        typingUnsaved = true
    }

    func reset() {
        stats = VoiceStats()
        save()
    }

    /// Developer check of the windows: a few weeks of made-up dictation, kept in memory only.
    func fillWithSample() {
        persists = false
        var sample = VoiceStats()
        let calendar = Calendar.current
        let phrases = ["Привіт, надсилаю документи для проєкту, перевірте, будь ласка, договір і рахунок.",
                       "Сьогодні зустріч о третій, проєкт треба закінчити до п’ятниці.",
                       "Дякую за допомогу з проєктом, документи вже в папці.",
                       "Нагадай мені купити молоко, хліб і каву після роботи."]
        for dayBack in 0..<40 {
            guard let day = calendar.date(byAdding: .day, value: -dayBack, to: Date()) else { continue }
            for index in 0..<(3 + dayBack % 4) {
                sample.addStart(at: day)
                sample.addListening(Double(8 + index * 3), at: day)
                for _ in 0..<(4 + index) { sample.addInserted(phrases[(dayBack + index) % phrases.count], at: day) }
            }
        }
        for _ in 0..<2_000 { sample.addKey(printable: true, interval: 0.27) }
        stats = sample
    }

    private func save() {
        typingUnsaved = false
        guard persists else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stats).write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            Log.engine.error("Voice statistics not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
