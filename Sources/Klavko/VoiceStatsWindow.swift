import AppKit
import KlavkoCore
import SwiftUI

/// Voice input statistics in a window of their own (from the menu): today, this month, this year or all time.
@MainActor
final class VoiceStatsWindow {
    private var window: NSWindow?

    func show(_ store: VoiceStatsStore) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: VoiceStatsView(store: store)))
            window.title = tr("Статистика голосового вводу", "Voice Input Statistics")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The congratulations on reaching 1 000, 10 000… dictated words, with the statistics for all time.
@MainActor
final class MilestoneWindow {
    private var window: NSWindow?

    func show(words: Int, store: VoiceStatsStore, showAll: @escaping () -> Void) {
        window?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: MilestoneView(
            words: words, store: store,
            close: { [weak self] in self?.window?.close() },
            showAll: { [weak self] in self?.window?.close(); showAll() })))
        window.title = tr("Вітаємо!", "Congratulations!")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct VoiceStatsView: View {
    @ObservedObject var store: VoiceStatsStore
    @State private var period: VoiceStats.Period = .day
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $period) {
                ForEach(VoiceStats.Period.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            StatsSummary(stats: store.stats, period: period)
            Divider()
            HStack(alignment: .top) {
                Text(StatsFormat.speedNote(store.stats))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(tr("Скинути…", "Reset…")) { confirmingReset = true }
            }
        }
        .padding(20)
        .frame(width: 500)
        .confirmationDialog(tr("Скинути всю статистику голосового вводу?", "Reset all voice input statistics?"),
                            isPresented: $confirmingReset) {
            Button(tr("Скинути", "Reset"), role: .destructive) { store.reset() }
        } message: {
            Text(tr("Слова, час, топ слів і виміряна швидкість друку почнуться з нуля.",
                    "Words, time, top words and the measured typing speed start from zero."))
        }
    }

    private static func title(_ period: VoiceStats.Period) -> String {
        switch period {
        case .day: tr("Сьогодні", "Today")
        case .month: tr("Цей місяць", "This Month")
        case .year: tr("Цей рік", "This Year")
        case .all: tr("Увесь час", "All Time")
        }
    }
}

private struct MilestoneView: View {
    let words: Int
    @ObservedObject var store: VoiceStatsStore
    let close: () -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 46))
                .foregroundStyle(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 6) {
                Text(trFormat("%@ слів!", "%@ words!", StatsFormat.number(words)))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(tr("Стільки ви вже надиктували з Klavko. Ось ваша статистика за весь час:",
                        "That’s how much you’ve dictated with Klavko so far. Here are your statistics for all time:"))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StatsSummary(stats: store.stats, period: .all)
            HStack {
                Button(tr("Уся статистика", "All Statistics"), action: showAll)
                Spacer()
                Button(tr("Чудово!", "Great!"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// The four numbers and the top 10 words for one period.
private struct StatsSummary: View {
    let stats: VoiceStats
    let period: VoiceStats.Period

    var body: some View {
        let counts = stats.counts(period)
        let top = stats.topWords(period)
        VStack(spacing: 14) {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    card("text.bubble", StatsFormat.number(counts.words), tr("слів продиктовано", "words dictated"), .blue)
                    card("mic", StatsFormat.duration(counts.seconds), tr("на диктування", "spent dictating"), .pink)
                }
                GridRow {
                    card("hare", "≈ " + StatsFormat.duration(stats.savedSeconds(counts)),
                         tr("зекономлено, ніж друкувати", "saved compared with typing"), .green)
                    card("power", StatsFormat.number(counts.starts), tr("разів увімкнено", "times turned on"), .orange)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Найчастіші слова", "Most frequent words"))
                    .font(.headline)
                if top.isEmpty {
                    Text(tr("Ще нічого не надиктовано за цей час.", "Nothing dictated in this time yet."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(Array(top.enumerated()), id: \.element.word) { index, entry in
                        row(index + 1, entry.word, entry.count, of: top[0].count)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card(_ symbol: String, _ value: String, _ caption: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private func row(_ rank: Int, _ word: String, _ count: Int, of most: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(word)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(proxy.size.width * CGFloat(count) / CGFloat(max(most, 1)), 3))
            }
            .frame(height: 8)
            Text(StatsFormat.number(count))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

/// Numbers and durations in the language of Klavko's interface.
enum StatsFormat {
    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLanguage.current.locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "2 год 15 хв", "45 с".
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = AppLanguage.current.locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds < 60 ? [.second] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds.rounded()) ?? "0"
    }

    static func speedNote(_ stats: VoiceStats) -> String {
        let perMinute = number(Int(stats.charactersPerMinute.rounded()))
        if stats.measuredCharactersPerMinute != nil {
            return trFormat("Зекономлений час порівнюється з вашою швидкістю друку: %@ знаків за хвилину (Klavko рахує лише натискання, не текст).",
                            "Time saved is compared with your typing speed: %@ characters a minute (Klavko counts only key presses, not the text).",
                            perMinute)
        }
        return trFormat("Поки Klavko вимірює вашу швидкість друку, зекономлений час рахується за середньою: %@ знаків за хвилину (≈ 40 слів).",
                        "Until Klavko has measured your typing speed, time saved is based on an average of %@ characters a minute (≈ 40 words).",
                        perMinute)
    }
}
