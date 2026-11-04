import AppKit
import KlavkoCore
import SwiftUI

/// Voice input statistics in a window of their own (from the menu): today, a calendar month, a calendar year or all
/// time, with the dates they cover; earlier months and years are a click back, and a chart shows every month (or year)
/// since the first one dictated.
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
        // In front without taking the keyboard: what the user types next still goes where they type.
        window.orderFrontRegardless()
    }
}

private struct VoiceStatsView: View {
    @ObservedObject var store: VoiceStatsStore
    @State private var period: VoiceStats.Period = .day
    /// A day in the month or year shown: today, or one in an earlier month or year.
    @State private var date = Date()
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: Binding(get: { period }, set: { period = $0; date = Date() })) {
                ForEach(VoiceStats.Period.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            PeriodHeader(stats: store.stats, period: period, date: $date)
            StatsSummary(stats: store.stats, period: period, date: date)
            if period == .month || period == .year {
                PeriodChart(stats: store.stats, unit: period == .month ? .month : .year, date: date) { date = $0 }
            }
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
        case .month: tr("Місяць", "Month")
        case .year: tr("Рік", "Year")
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

/// What a period covers, in dates ("1–4 листопада"), and for a month or a year the arrows to earlier ones and back.
private struct PeriodHeader: View {
    let stats: VoiceStats
    let period: VoiceStats.Period
    @Binding var date: Date

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .day:
            caption(StatsFormat.day(now))
        case .all:
            caption(stats.firstDay().map { trFormat("Від %@ до сьогодні", "From %@ to today", StatsFormat.fullDate($0)) }
                    ?? tr("Ще нічого не надиктовано.", "Nothing dictated yet."))
        case .month, .year:
            let unit: Calendar.Component = period == .month ? .month : .year
            let interval = calendar.dateInterval(of: unit, for: date)!
            let current = interval.contains(now)
            let canGoBack = stats.firstDay().map { $0 < interval.start } ?? false
            HStack {
                arrow("chevron.left", tr("Раніше", "Earlier"), enabled: canGoBack) { date = calendar.date(byAdding: unit, value: -1, to: date)! }
                Spacer()
                VStack(spacing: 2) {
                    Text(period == .month ? StatsFormat.month(date) : StatsFormat.year(date))
                        .font(.headline)
                    Text(StatsFormat.range(interval.start, current ? now : interval.end.addingTimeInterval(-1)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                arrow("chevron.right", tr("Пізніше", "Later"), enabled: !current) { date = calendar.date(byAdding: unit, value: 1, to: date)! }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private func arrow(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .disabled(!enabled)
            .help(help)
    }
}

/// The words dictated in every month of the years since the first one dictated (all 12 of each), or in every such
/// year, as bars, the one shown highlighted; a click shows another. More than a year of months scrolls sideways.
private struct PeriodChart: View {
    let stats: VoiceStats
    let unit: Calendar.Component
    let date: Date
    let pick: (Date) -> Void

    private struct Bar: Identifiable {
        let id: String
        let date: Date
        let words: Int
        let label: String
        /// Under each January.
        let year: String?
        /// A month still to come: an empty bar, not clickable.
        let future: Bool
    }

    private var bars: [Bar] {
        let calendar = Calendar.current
        let now = Date()
        var start = calendar.dateInterval(of: .year, for: stats.firstDay() ?? now)!.start
        let end = unit == .month ? calendar.dateInterval(of: .year, for: now)!.end : now
        var bars: [Bar] = []
        while start < end {
            let middle = calendar.date(byAdding: .day, value: 14, to: start)!
            let month = calendar.component(.month, from: start)
            bars.append(Bar(id: VoiceStats.dayKey(start, calendar), date: middle,
                            words: stats.counts(unit == .month ? .month : .year, now: middle).words,
                            label: unit == .month ? StatsFormat.shortMonth(start) : StatsFormat.year(start),
                            year: unit == .month && month == 1 ? StatsFormat.year(start) : nil, future: start > now))
            start = calendar.date(byAdding: unit, value: 1, to: start)!
        }
        return bars
    }

    var body: some View {
        let calendar = Calendar.current
        let bars = bars
        let most = max(bars.map(\.words).max() ?? 0, 1)
        let shown = bars.first { calendar.isDate($0.date, equalTo: date, toGranularity: unit) }?.id
        VStack(alignment: .leading, spacing: 6) {
            Text(unit == .month ? tr("Слова за місяцями", "Words by month") : tr("Слова за роками", "Words by year"))
                .font(.headline)
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: bars.count > 12) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(bars) { bar in
                            let highlighted = bar.id == shown
                            Button { pick(bar.date) } label: {
                                VStack(spacing: 3) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(highlighted ? 1 : 0.45))
                                        .frame(height: bar.words == 0 ? 2 : max(CGFloat(bar.words) / CGFloat(most) * 64, 4))
                                    Text(bar.label)
                                        .font(.caption2)
                                        .foregroundStyle(highlighted ? .primary : .secondary)
                                        .lineLimit(1)
                                    Text(bar.year ?? " ")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                .frame(width: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(bar.future)
                            .help(trFormat("%@: %@ слів", "%@: %@ words",
                                           unit == .month ? StatsFormat.month(bar.date) : StatsFormat.year(bar.date),
                                           StatsFormat.number(bar.words)))
                            .id(bar.id)
                        }
                    }
                    .frame(height: 104)
                    .padding(.bottom, bars.count > 12 ? 8 : 0)
                }
                .onAppear { if let shown { scroller.scrollTo(shown, anchor: .center) } }
                .onChange(of: shown) { if let shown { withAnimation { scroller.scrollTo(shown, anchor: .center) } } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The four numbers and the top 10 words for one period: the one with `date` in it.
private struct StatsSummary: View {
    let stats: VoiceStats
    let period: VoiceStats.Period
    var date = Date()

    var body: some View {
        let counts = stats.counts(period, now: date)
        let top = stats.topWords(period, now: date)
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

    // Dates in the language of Klavko's interface.

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased(with: AppLanguage.current.locale) + text.dropFirst()
    }

    /// "Листопад 2026".
    static func month(_ date: Date) -> String { capitalized(formatter("LLLLy").string(from: date)) }
    /// "2026".
    static func year(_ date: Date) -> String { String(Calendar.current.component(.year, from: date)) }
    /// "лист." under a bar.
    static func shortMonth(_ date: Date) -> String { formatter("LLL").string(from: date) }
    /// "Середа, 4 листопада 2026".
    static func day(_ date: Date) -> String { capitalized(formatter("EEEEdMMMMy").string(from: date)) }
    /// "12 жовтня 2026".
    static func fullDate(_ date: Date) -> String { formatter("dMMMMy").string(from: date) }

    /// "1–4 листопада", "1 січня – 4 листопада".
    static func range(_ start: Date, _ end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateTemplate = "dMMMM"
        return formatter.string(from: start, to: end)
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
