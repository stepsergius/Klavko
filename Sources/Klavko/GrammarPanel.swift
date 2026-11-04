import AppKit
import KlavkoCore
import SwiftUI

/// "Check spelling": checks the selected text with LanguageTool on this Mac and shows it in a small panel near
/// the mouse, mistakes marked and the suggested fixes chosen; a click picks another fix or leaves the place as it
/// was. Return puts the fixed text in place of the selection, ⌘C copies it.
@MainActor
final class GrammarPanel: ObservableObject {
    enum Stage: Equatable {
        case working
        case result
        case failed(String)
        case noSelection
        case notDownloaded
    }

    @Published private(set) var stage: Stage = .working
    @Published private(set) var text = ""
    @Published private(set) var issues: [GrammarIssue] = []
    /// Issue id → the fix to put in; issues not here stay as written.
    @Published private(set) var choices: [String: String] = [:]

    var checker: GrammarChecker?
    /// Adds a word to the user's dictionary.
    var addWord: (String) -> Void = { _ in }
    /// The languages the user writes in (the enabled layouts), to tell which one the text is in.
    var languages: () -> [String] = { ["uk", "en"] }
    var openSettings: () -> Void = {}

    private var panel: NSPanel?
    private var anchor = NSPoint.zero
    private var resizeObserver: NSObjectProtocol?
    private var selection: SelectionConverter.Selection?
    private var sourceApp: NSRunningApplication?
    private var checking: Task<Void, Never>?

    func start() {
        close()
        sourceApp = NSWorkspace.shared.frontmostApplication
        anchor = NSEvent.mouseLocation
        if let selection = SelectionConverter.accessibleSelection() {
            self.selection = selection
            check(selection.text)
            showPanel()
            return
        }
        selection = nil
        SelectionConverter.copySelection { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.check(text)
                } else {
                    self.stage = .noSelection
                }
                self.showPanel()
            }
        }
    }

    private func check(_ text: String) {
        self.text = text
        issues = []
        choices = [:]
        guard let checker, checker.isDownloaded else {
            stage = .notDownloaded
            return
        }
        stage = .working
        let language = TranslationDirection.language(of: text, among: languages())
        checking = Task { [weak self] in
            do {
                let issues = try await checker.check(text, language: language)
                guard let self, !Task.isCancelled else { return }
                self.issues = issues
                // The likely fixes are chosen already; style is only a suggestion.
                for issue in issues where issue.kind != .style {
                    if let first = issue.replacements.first { self.choices[issue.id] = first }
                }
                self.stage = .result
                Log.engine.notice("Grammar check: \(issues.count) issues")
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.stage = .failed(tr("Не вдалося перевірити: ", "Couldn’t check: ") + error.localizedDescription)
                Log.engine.error("Grammar check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Picked in the panel: put `replacement` there, or (nil) leave the place as written.
    func choose(_ replacement: String?, for issue: GrammarIssue) {
        choices[issue.id] = replacement
    }

    /// The word of a spelling mistake goes into the dictionary: it and the same word elsewhere stay as written.
    func addToDictionary(_ issue: GrammarIssue) {
        guard let range = issue.range(in: text) else { return }
        let word = String(text[range])
        addWord(word)
        let same = Set(issues.filter { GrammarCheck.withoutKnownWords([$0], in: text, words: [TextRules.coreWord(word).lowercased()]).isEmpty }.map(\.id))
        issues.removeAll { same.contains($0.id) }
        for id in same { choices[id] = nil }
    }

    var fixedText: String { GrammarCheck.apply(choices, of: issues, to: text) }

    /// Can replace the selection (and not only copy).
    var canReplace: Bool { selection != nil || sourceApp != nil }

    func replace() {
        let fixed = fixedText
        let app = sourceApp
        let selection = selection
        close()
        guard fixed != text else { return }
        app?.activate()
        // The other app gets its keyboard focus back once the panel is gone.
        let paste = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SelectionConverter.paste(fixed) } }
        guard let selection else { return paste() }
        selection.replace(with: fixed) { replaced in
            if !replaced { paste() }
        }
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fixedText, forType: .string)
        let app = sourceApp
        close()
        app?.activate()
    }

    func showSettings() {
        close()
        openSettings()
    }

    func close() {
        checking?.cancel()
        checking = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Developer check: --grammar-check <text> <out.txt> checks without a selection and writes what was found.
    func check(_ text: String, writeTo url: URL) {
        sourceApp = nil
        anchor = NSEvent.mouseLocation
        check(text)
        showPanel()
        Task { @MainActor in
            for _ in 0..<1200 {
                switch stage {
                case .result:
                    let lines = issues.map { "\($0.kind.rawValue) «\($0.range(in: text).map { String(text[$0]) } ?? "")» → \($0.replacements): \($0.message)" }
                    try? (lines + ["", fixedText]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                case .failed(let message):
                    try? message.write(to: url, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                case .notDownloaded, .noSelection:
                    try? "not downloaded".write(to: url, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                case .working:
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try? "timeout".write(to: url, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func showPanel() {
        let controller = NSHostingController(rootView: GrammarPanelView(panel: self))
        controller.sizingOptions = [.preferredContentSize]
        let panel = GrammarNSPanel(contentViewController: controller)
        panel.styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView, .closable]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.close() }
        place(panel)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.place(panel)
            }
        }
        // Takes Return / ⌘C / Esc without activating Klavko, so the app with the selection stays active.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Below and right of the mouse pointer; above it when there is no room below; always on screen.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.x + 12, y: anchor.y - size.height - 12)
        if let frame = screen?.visibleFrame {
            if origin.y < frame.minY + 8 { origin.y = anchor.y + 12 }
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

private final class GrammarNSPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func close() {
        super.close()
        onClose?()
    }
}

private struct GrammarPanelView: View {
    @ObservedObject var panel: GrammarPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Перевірка правопису", "Spelling and Grammar"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: 460)
    }

    @ViewBuilder private var content: some View {
        switch panel.stage {
        case .noSelection:
            Text(tr("Спершу виділіть текст, потім натисніть гарячу клавішу.", "Select some text first, then press the hotkey."))
                .foregroundStyle(.secondary)
            closeRow

        case .notDownloaded:
            Text(tr("Для перевірки правопису потрібно один раз завантажити LanguageTool (~300 МБ). Після цього перевірка працює без інтернету.",
                    "The spelling check needs LanguageTool, downloaded once (~300 MB). After that it works offline."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Закрити", "Close")) { panel.close() }.keyboardShortcut(.cancelAction)
                Button(tr("Відкрити налаштування", "Open Settings")) { panel.showSettings() }.keyboardShortcut(.defaultAction)
            }

        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(tr("Перевіряю…", "Checking…")).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            closeRow

        case .failed(let message):
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            closeRow

        case .result where panel.issues.isEmpty:
            Label(tr("Помилок не знайдено", "No mistakes found"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .padding(.vertical, 4)
            closeRow

        case .result:
            ScrollView {
                Text(marked)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(panel.issues) { issue in IssueRow(panel: panel, issue: issue, text: panel.text) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            actions
        }
    }

    /// The text with the fixes: what goes in green, what it replaces struck through; places left as written
    /// underlined in their colour.
    private var marked: AttributedString {
        let text = panel.text
        var result = AttributedString()
        var position = text.startIndex
        for issue in panel.issues {
            guard let range = issue.range(in: text), range.lowerBound >= position else { continue }
            result += AttributedString(text[position..<range.lowerBound])
            let original = String(text[range])
            if let replacement = panel.choices[issue.id] {
                if !original.isEmpty {
                    var gone = AttributedString(original)
                    gone.strikethroughStyle = .single
                    gone.foregroundColor = .secondary
                    result += gone
                }
                var fix = AttributedString(replacement)
                fix.foregroundColor = .green
                fix.font = .system(size: 14, weight: .semibold)
                result += fix
            } else {
                var kept = AttributedString(original)
                kept.underlineStyle = Text.LineStyle(pattern: .dot, color: issue.kind.color)
                result += kept
            }
            position = range.upperBound
        }
        result += AttributedString(text[position...])
        return result
    }

    private var actions: some View {
        HStack {
            Text(tr("LanguageTool, на цьому Mac", "LanguageTool, on this Mac"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button(tr("Копіювати", "Copy")) { panel.copyResult() }
                .keyboardShortcut("c", modifiers: .command)
            Button(tr("Замінити", "Replace")) { panel.replace() }
                .keyboardShortcut(.defaultAction)
                .disabled(!panel.canReplace)
        }
    }

    private var closeRow: some View {
        HStack {
            Spacer()
            Button(tr("Закрити", "Close")) { panel.close() }.keyboardShortcut(.cancelAction)
        }
    }
}

/// One mistake: what's wrong, and the fixes to pick from (or none: leave it as written).
private struct IssueRow: View {
    @ObservedObject var panel: GrammarPanel
    let issue: GrammarIssue
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(issue.kind.color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(issue.range(in: text).map { String(text[$0]) } ?? "")
                        .font(.system(size: 13, weight: .semibold))
                    Text(issue.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                Text(issue.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowRow {
                    ForEach(issue.replacements, id: \.self) { replacement in
                        choice(replacement.isEmpty ? tr("(прибрати)", "(remove)") : replacement, replacement)
                    }
                    if !issue.replacements.isEmpty {
                        choice(tr("Не змінювати", "Keep"), nil)
                    }
                    if issue.kind == .spelling {
                        Button(tr("Додати до словника", "Add to Dictionary")) { panel.addToDictionary(issue) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func choice(_ title: String, _ replacement: String?) -> some View {
        let chosen = panel.choices[issue.id] == replacement
        return Button(title) { panel.choose(replacement, for: issue) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: chosen ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(chosen ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(chosen ? Color.accentColor : .clear, lineWidth: 1))
    }
}

/// Buttons in rows that wrap.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

extension GrammarIssue.Kind {
    var color: Color {
        switch self {
        case .spelling: .red
        case .grammar: .orange
        case .punctuation: .blue
        case .typography: .purple
        case .style: .teal
        }
    }

    var title: String {
        switch self {
        case .spelling: tr("правопис", "spelling")
        case .grammar: tr("граматика", "grammar")
        case .punctuation: tr("пунктуація", "punctuation")
        case .typography: tr("типографіка", "typography")
        case .style: tr("стиль", "style")
        }
    }
}
