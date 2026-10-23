import AppKit
import KlavkoCore
import SwiftUI
import Translation

/// "Translate the selection" and "text from the screen": translates the selected text (or text read off
/// the screen) with the translator built into macOS (on this Mac, no account or key) and shows it in a
/// small panel near the mouse. Return puts the translation in place of the selection, ⌘C copies what is
/// shown; a switch shows the original text instead.
@MainActor
final class Translator: ObservableObject {
    enum Stage: Equatable {
        case working
        case downloading
        case result(String)
        case failed(String)
        case noSelection
    }

    /// One translation request; a new id makes the panel run it even for the same languages.
    struct Job: Equatable {
        let id: Int
        let text: String
        let direction: TranslationDirection
    }

    @Published private(set) var stage: Stage = .working
    @Published private(set) var job: Job?
    /// Show the text as it was (read off the screen or selected) instead of its translation.
    @Published var showOriginal = false
    /// The text came from the screen (OCR), not from a selection: nothing to replace.
    @Published private(set) var fromScreen = false

    /// The default pair from Settings: (own language, other language).
    var defaultPair: () -> (own: String, other: String) = { ("uk", "en") }

    private var panel: NSPanel?
    /// The mouse position the panel opened at; it stays next to it as its content grows.
    private var anchor = NSPoint.zero
    private var resizeObserver: NSObjectProtocol?
    /// Where the selection came from when Accessibility gave it directly (no clipboard used).
    private var selection: SelectionConverter.Selection?
    private var nextID = 0
    /// The app with the selection, to give focus back to if a language download brought Klavko forward.
    private var sourceApp: NSRunningApplication?

    func start() {
        close()
        fromScreen = false
        showOriginal = false
        sourceApp = NSWorkspace.shared.frontmostApplication
        anchor = NSEvent.mouseLocation
        // Without the clipboard where the app allows it; ⌘C (clipboard restored) elsewhere.
        if let selection = SelectionConverter.accessibleSelection() {
            self.selection = selection
            translate(selection.text, direction(for: selection.text))
            showPanel()
            return
        }
        selection = nil
        SelectionConverter.copySelection { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.translate(text, self.direction(for: text))
                } else {
                    self.job = nil
                    self.stage = .noSelection
                }
                self.showPanel()
            }
        }
    }

    /// Text read off the screen: translated like a selection, shown next to `point` (where the area ended).
    func show(screenText text: String, at point: NSPoint) {
        close()
        fromScreen = true
        showOriginal = false
        selection = nil
        sourceApp = NSWorkspace.shared.frontmostApplication
        anchor = point
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            job = nil
            stage = .failed(tr("У вибраній області не знайдено ні тексту, ні QR-коду.", "No text or QR code found in the selected area."))
        } else {
            translate(text, direction(for: text))
        }
        showPanel()
    }

    /// A problem before there is any text (for example no permission to read the screen).
    func showProblem(_ message: String, at point: NSPoint) {
        close()
        fromScreen = true
        job = nil
        anchor = point
        stage = .failed(message)
        showPanel()
    }

    /// The Settings pair: text in the own language goes into the other one, anything else into the own one.
    private func direction(for text: String) -> TranslationDirection {
        let pair = defaultPair()
        let layouts = SystemLayouts.enabledLayouts().map(\.map.language)
        return TranslationDirection(for: text, own: pair.own, other: pair.other, layouts: layouts)
    }

    /// Picked in the panel: translate the same text again from `source`.
    func setSource(_ source: String) {
        guard let job, source != job.direction.source else { return }
        let target = source == job.direction.target ? job.direction.source : job.direction.target
        translate(job.text, TranslationDirection(source: source, target: target))
    }

    /// Picked in the panel: translate the same text again into `target`.
    func setTarget(_ target: String) {
        guard let job, target != job.direction.target else { return }
        let source = target == job.direction.source ? job.direction.target : job.direction.source
        translate(job.text, TranslationDirection(source: source, target: target))
    }

    /// A short label for the panel: "🇺🇦 UA", "RU". Ukrainian shows "UA": its code "UK" reads as Britain.
    static func shortName(_ code: String) -> String {
        let label = code == "uk" ? "UA" : code.uppercased()
        return LanguageFlags.emoji[code].map { "\($0) \(label)" } ?? label
    }

    /// A language's name in the interface language, after its flag or, without one, its code:
    /// "🇺🇦 Українська", "RU Російська".
    static func languageName(_ code: String) -> String {
        (LanguageFlags.emoji[code] ?? code.uppercased()) + " " + plainName(code)
    }

    /// The name alone, in the interface language: "Українська".
    static func plainName(_ code: String) -> String {
        let locale = AppLanguage.current.locale
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    /// For language lists: the interface language first, the others in alphabetical order of their names.
    static func ordered(_ codes: [String]) -> [String] {
        let locale = AppLanguage.current.locale
        let first = AppLanguage.current.rawValue.components(separatedBy: "-")[0]
        let rest = codes.filter { $0 != first }.sorted {
            plainName($0).compare(plainName($1), options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                == .orderedAscending
        }
        return (codes.contains(first) ? [first] : []) + rest
    }

    /// The same text the other way round, for when the guess was wrong.
    func swapDirection() {
        guard let job else { return }
        translate(job.text, job.direction.reversed)
    }

    /// Puts the result in place of the selection.
    func replace() {
        guard !fromScreen, let text = shownText else { return }
        let app = sourceApp
        let selection = selection
        close()
        app?.activate()
        if let selection, selection.replace(with: text) { return }
        // The other app gets its keyboard focus back once the panel is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SelectionConverter.paste(text) }
    }

    /// What the panel shows: the original or the translation (nil while there is nothing to show).
    var shownText: String? {
        if showOriginal { return job?.text }
        if case .result(let text) = stage { return text }
        return nil
    }

    func copyResult() {
        guard let text = shownText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let app = sourceApp
        close()
        app?.activate()
    }

    func close() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        panel = nil
        job = nil
    }

    private func translate(_ text: String, _ direction: TranslationDirection) {
        nextID += 1
        job = Job(id: nextID, text: text, direction: direction)
        stage = .working
    }

    /// Called from the panel's translation task with the session macOS made for `job`.
    @available(macOS 15.0, *)
    nonisolated func run(_ job: Job, session: TranslationSession) async {
        let source = Locale.Language(identifier: job.direction.source)
        let target = Locale.Language(identifier: job.direction.target)
        if await LanguageAvailability().status(from: source, to: target) != .installed {
            // macOS asks to download the two languages once; its dialog needs Klavko in front.
            await MainActor.run {
                stage = .downloading
                NSApp.activate()
            }
        }
        let lines = TranslationLines(job.text)
        do {
            let requests = lines.toTranslate.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            let result = lines.assemble(responses.map(\.targetText))
            await finish(job, .result(result))
            Log.engine.notice("Translated \(job.direction.source, privacy: .public) → \(job.direction.target, privacy: .public)")
        } catch {
            await finish(job, .failed(Self.message(for: error)))
            Log.engine.error("Translation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish(_ finished: Job, _ stage: Stage) {
        guard job?.id == finished.id else { return }
        self.stage = stage
        // Back to the app with the selection, so Return / ⌘C here still lead there.
        if NSApp.isActive { sourceApp?.activate() }
        panel?.makeKeyAndOrderFront(nil)
    }

    @available(macOS 15.0, *)
    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            tr("Перекладач macOS не підтримує цю пару мов.", "The macOS translator doesn’t support this language pair.")
        case TranslationError.nothingToTranslate:
            tr("Немає що перекладати.", "Nothing to translate.")
        default:
            tr("Не вдалося перекласти: ", "Couldn’t translate: ") + error.localizedDescription
        }
    }

    /// Developer check: --translate-check <text> <out.txt> translates without a selection and writes the result.
    func check(_ text: String, writeTo url: URL) {
        sourceApp = nil
        anchor = NSEvent.mouseLocation
        translate(text, direction(for: text))
        showPanel()
        Task { @MainActor in
            for _ in 0..<600 {
                switch stage {
                case .result(let result), .failed(let result):
                    try? result.write(to: url, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try? "timeout".write(to: url, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// Developer check of the panel's look: a screen text and its translation, into `url`.
    func snapshot(to url: URL) {
        fromScreen = true
        let text = "Знижка 30% на всі товари до неділі\nПодробиці на сайті магазину"
        job = Job(id: 1, text: text, direction: TranslationDirection(source: "uk", target: "en"))
        stage = .result("30% off all products until Sunday\nDetails on the store website")
        let view = NSHostingView(rootView: TranslatorPanelView(translator: self).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }

    private func showPanel() {
        let controller = NSHostingController(rootView: TranslatorPanelView(translator: self))
        controller.sizingOptions = [.preferredContentSize]
        let panel = TranslatorPanel(contentViewController: controller)
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
        // The result is taller than "Translating…": keep the grown panel next to the mouse and on screen.
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

private final class TranslatorPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func close() {
        super.close()
        onClose?()
    }
}

private struct TranslatorPanelView: View {
    @ObservedObject var translator: Translator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: 440)
        .modifier(TranslationRunner(translator: translator))
    }

    /// Original / translation on the left; the languages, small, on the right.
    private var header: some View {
        HStack(spacing: 8) {
            if translator.job != nil {
                Picker("", selection: $translator.showOriginal) {
                    Text(tr("Переклад", "Translation")).tag(false)
                    Text(tr("Оригінал", "Original")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else {
                Text(translator.fromScreen ? tr("Текст з екрана", "Text from the screen")
                                           : tr("Переклад", "Translation"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let job = translator.job {
                // A change translates the text in the panel again right away.
                HStack(spacing: 2) {
                    languageMenu(job.direction.source) { translator.setSource($0) }
                    Button {
                        translator.swapDirection()
                    } label: {
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("Перекласти в інший бік", "Translate the other way"))
                    languageMenu(job.direction.target) { translator.setTarget($0) }
                }
                .opacity(translator.showOriginal ? 0.45 : 1)
            }
        }
    }

    private func languageMenu(_ selected: String, onChange: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(Translator.ordered(TranslationDirection.languages), id: \.self) { code in
                Button(Translator.languageName(code)) { onChange(code) }
            }
        } label: {
            Text(Translator.shortName(selected)).font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Translator.languageName(selected))
    }

    @ViewBuilder private var content: some View {
        if #unavailable(macOS 15.0), !translator.showOriginal {
            Text(tr("Переклад працює на macOS 15 Sequoia і новіших.", "Translation needs macOS 15 Sequoia or later."))
                .foregroundStyle(.secondary)
            closeRow
        } else if translator.showOriginal, let original = translator.job?.text {
            textBody(original)
            actions
        } else {
            switch translator.stage {
            case .noSelection:
                Text(tr("Спершу виділіть текст, потім натисніть гарячу клавішу.", "Select some text first, then press the hotkey."))
                    .foregroundStyle(.secondary)
                closeRow

            case .working, .downloading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(translator.stage == .downloading
                         ? tr("Завантажую мови для перекладу (один раз)…", "Downloading translation languages (once)…")
                         : tr("Перекладаю…", "Translating…"))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                closeRow

            case .result(let text):
                textBody(text)
                actions

            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                closeRow
            }
        }
    }

    /// The text itself, first and large.
    private func textBody(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack {
            Text(translator.showOriginal
                 ? (translator.fromScreen ? tr("Розпізнано на цьому Mac", "Recognized on this Mac") : tr("Виділений текст", "Selected text"))
                 : tr("Перекладач macOS, на цьому Mac", "macOS translator, on this Mac"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if translator.fromScreen {
                Button(tr("Копіювати", "Copy")) { translator.copyResult() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(tr("Копіювати", "Copy")) { translator.copyResult() }
                    .keyboardShortcut("c", modifiers: .command)
                Button(tr("Замінити", "Replace")) { translator.replace() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var closeRow: some View {
        HStack {
            Spacer()
            Button(tr("Закрити", "Close")) { translator.close() }.keyboardShortcut(.cancelAction)
        }
    }
}

/// Runs the current job through the macOS translator (the session only comes from SwiftUI before macOS 26).
private struct TranslationRunner: ViewModifier {
    @ObservedObject var translator: Translator

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(SessionRunner(translator: translator))
        } else {
            content
        }
    }
}

@available(macOS 15.0, *)
private struct SessionRunner: ViewModifier {
    @ObservedObject var translator: Translator
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { [translator] session in
                guard let job = await MainActor.run(body: { translator.job }) else { return }
                await translator.run(job, session: session)
            }
            .onAppear { update(for: translator.job) }
            .onChange(of: translator.job) { _, job in update(for: job) }
    }

    private func update(for job: Translator.Job?) {
        guard let job else { return }
        let source = Locale.Language(identifier: job.direction.source)
        let target = Locale.Language(identifier: job.direction.target)
        if configuration?.source == source && configuration?.target == target {
            configuration?.invalidate()  // Same languages, new text: run again.
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}
