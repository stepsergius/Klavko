import AppKit
import AVFoundation
import KlavkoCore
import NaturalLanguage
import SwiftUI

/// Quick Actions: after text is selected with the mouse (a drag, a double or triple click), a small dark bar
/// appears over or under it with what can be done to the text; holding the mouse down in a text field brings
/// it up with just "Paste". The second button sits right at the mouse, the first to its left, the rest to its
/// right. Any click elsewhere, a key or scrolling hides it.
/// The bar never takes the focus: the app with the selection stays in front, so copy and paste go to it.
@MainActor
final class QuickActionsBar {
    var settings: () -> Settings? = { nil }
    /// "Translate": the translation panel, which reads the selection itself.
    var translate: () -> Void = {}

    fileprivate let model = QuickActionsModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var downPoint: NSPoint?
    private var pending: DispatchWorkItem?
    /// A long press in a text field: "Paste" once the mouse has been held still long enough.
    private var holding: DispatchWorkItem?
    private let speech = AVSpeechSynthesizer()
    /// Where the second button goes (the mouse), kept when the bar changes width (a submenu, an answer).
    private var anchorX: CGFloat = 0

    func start() {
        guard monitors.isEmpty else { return }
        let watched: [NSEvent.EventTypeMask] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown, .scrollWheel]
        for mask in watched {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }) {
                monitors.append(monitor)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    self?.hide()
                }
            }
    }

    // MARK: Watching the mouse

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let down = NSEvent.mouseLocation
            downPoint = down
            pending?.cancel()
            holding?.cancel()
            hide()
            let work = DispatchWorkItem { [weak self] in
                // Still held, and where it went down (a drag selects instead).
                let now = NSEvent.mouseLocation
                guard NSEvent.pressedMouseButtons & 1 != 0, hypot(now.x - down.x, now.y - down.y) <= 6 else { return }
                self?.lookAtField(at: down)
            }
            holding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        case .leftMouseUp:
            holding?.cancel()
            let up = NSEvent.mouseLocation
            let dragged = downPoint.map { hypot($0.x - up.x, $0.y - up.y) > 6 } ?? false
            // A drag, a double click (word) or triple click (line), or ⇧-click extending the selection.
            guard dragged || event.clickCount >= 2 || event.modifierFlags.contains(.shift) else { return }
            let from = downPoint ?? up
            let work = DispatchWorkItem { [weak self] in self?.lookAtSelection(from: from, to: up) }
            pending = work
            // Let the app finish selecting (a double click selects on the second mouse-up).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        default:
            pending?.cancel()
            holding?.cancel()
            hide()
        }
    }

    /// A long press: "Paste" when the mouse is in a text field and there is text to paste.
    private func lookAtField(at point: NSPoint) {
        guard let settings = settings(), settings.quickActionsEnabled,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !settings.quickActionsIgnoredApps.contains(app.bundleIdentifier ?? ""),
              NSPasteboard.general.string(forType: .string)?.isEmpty == false else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let field = focused as! AXUIElement
        guard Self.details(of: field).editable else { return }
        // The field with the focus is the one under the mouse (when the app tells where it is).
        if let frame = Self.frame(of: field), !frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        show(text: "", selection: nil, editable: true, around: Self.rect(from: point, to: point), settings: settings,
             only: [.paste, .plainPaste])
    }

    /// From the hotkey: the bar for text selected with the keyboard too.
    func showForSelection() {
        let mouse = NSEvent.mouseLocation
        lookAtSelection(from: mouse, to: mouse, byHotkey: true)
    }

    private func lookAtSelection(from: NSPoint, to: NSPoint, byHotkey: Bool = false) {
        guard let settings = settings(), settings.quickActionsEnabled || byHotkey,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !settings.quickActionsIgnoredApps.contains(app.bundleIdentifier ?? "") else { return }
        // Electron apps (Slack, VS Code…) show their text to Accessibility only when asked.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let mouseRect = Self.rect(from: from, to: to)
        if let selection = SelectionConverter.accessibleSelection() {
            let info = Self.details(of: selection.element)
            show(text: selection.text, selection: selection, editable: info.editable, around: info.bounds ?? mouseRect, settings: settings)
            return
        }
        // Apps that don't share the selection: copy it (the clipboard is put back). Never in Finder, where
        // a drag selects files, not text.
        guard app.bundleIdentifier != "com.apple.finder" else { return }
        SelectionConverter.copySelection { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                // Unknown: offer the editing actions too (in a page that can't change, they do nothing).
                self.show(text: text, selection: nil, editable: true, around: mouseRect, settings: settings)
            }
        }
    }

    /// Where the selection is on screen (when the app tells) and whether it can be typed over.
    private static func details(of element: AXUIElement) -> (bounds: NSRect?, editable: Bool) {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        let editable = settable.boolValue || textRoles.contains(role as? String ?? "")

        var rangeValue: CFTypeRef?
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue,
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return (nil, editable) }
        var rect = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
        // Accessibility counts from the top of the main screen; AppKit from its bottom.
        guard rect.width > 0 || rect.height > 0, rect.height < 2000,
              let mainHeight = NSScreen.screens.first?.frame.height else { return (nil, editable) }
        let flipped = NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        // Some apps answer with nonsense far away from the text: trust it only on a screen.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return (nil, editable) }
        return (flipped, editable)
    }

    /// Where an element is on screen, in AppKit coordinates.
    private static func frame(of element: AXUIElement) -> NSRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue, let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return NSRect(x: position.x, y: mainHeight - position.y - size.height, width: size.width, height: size.height)
    }

    /// The line the mouse went over, about one line high.
    private static func rect(from: NSPoint, to: NSPoint) -> NSRect {
        NSRect(x: min(from.x, to.x), y: min(from.y, to.y) - 6,
               width: abs(from.x - to.x), height: abs(from.y - to.y) + 20)
    }

    // MARK: The bar

    private func show(text: String, selection: SelectionConverter.Selection?, editable: Bool, around rect: NSRect,
                      settings: Settings, only: Set<QuickAction>? = nil) {
        let links = TextLinks.find(in: text)
        let hasClipboardText = NSPasteboard.general.string(forType: .string)?.isEmpty == false
        var actions = settings.quickActions.filter { action in
            if let only, !only.contains(action) { return false }
            if action.needsEditable && !editable { return false }
            switch action {
            case .openLink: return false  // placed first below, only for a link
            case .paste, .plainPaste: return hasClipboardText
            case .sum: return QuickText.sum(text) != nil
            default: return true
            }
        }
        if let link = links.first, !settings.quickActionsOff.contains(.openLink) {
            actions.insert(.openLink, at: 0)
            model.link = link.url
        } else {
            model.link = nil
        }
        guard !actions.isEmpty else { return }
        model.text = text
        model.selection = selection
        model.range = selection.flatMap { selection in
            var range: CFTypeRef?
            AXUIElementCopyAttributeValue(selection.element, kAXSelectedTextRangeAttribute as CFString, &range)
            return range
        }
        model.actions = actions
        model.aiServices = settings.aiServices
        model.page = .main
        model.speaking = speech.isSpeaking
        model.run = { [weak self] action in self?.run(action) }
        model.wrap = { [weak self] open, close in self?.replace { QuickText.wrapped($0, open: open, close: close) } }
        model.ask = { [weak self] service in self?.hide(); self?.open(in: service) }
        model.close = { [weak self] in self?.hide() }
        model.anchorMoved = { [weak self] in self?.keepAnchored() }
        present(around: rect, position: settings.quickActionsPosition)
    }

    private func present(around rect: NSRect, position: QuickActionsPosition) {
        if panel == nil {
            let controller = NSHostingController(rootView: QuickActionsView(model: model))
            controller.sizingOptions = [.preferredContentSize]
            // Non-activating from the start: set later, AppKit still brings Klavko forward on a click.
            let panel = BarPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                 backing: .buffered, defer: true)
            panel.contentViewController = controller
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.animationBehavior = .utilityWindow
            self.panel = panel
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepAnchored() }
            }
        }
        guard let panel else { return }
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect
        // The second button at the mouse (kept along the selection), over (or under) its top (bottom) line.
        let mouseX = NSEvent.mouseLocation.x
        anchorX = rect.width > 0 ? min(max(mouseX, rect.minX), rect.maxX) : rect.midX
        var origin = NSPoint(x: anchorX - (model.anchorOffset ?? size.width / 2),
                             y: position == .above ? rect.maxY + 6 : rect.minY - 6 - size.height)
        // Where there is no room, the other side.
        if origin.y + size.height > visible.maxY { origin.y = rect.minY - 6 - size.height }
        if origin.y < visible.minY { origin.y = rect.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// The second button back at the mouse once the bar has measured where it is.
    private func keepAnchored() {
        guard let panel, let visible = panel.screen?.visibleFrame else { return }
        let offset = model.anchorOffset ?? panel.frame.width / 2
        let x = min(max(anchorX - offset, visible.minX + 4), visible.maxX - panel.frame.width - 4)
        if panel.frame.minX != x { panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.minY)) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: Actions

    private static let keyB: CGKeyCode = 11, keyC: CGKeyCode = 8, keyI: CGKeyCode = 34, keyN: CGKeyCode = 45, keyU: CGKeyCode = 32,
                       keyV: CGKeyCode = 9, keyX: CGKeyCode = 7

    private func run(_ action: QuickAction) {
        let text = model.text
        switch action {
        case .brackets:
            model.page = .brackets
            return
        case .ai where model.aiServices.count > 1:
            model.page = .ai
            return
        case .stats:
            let stats = QuickText.stats(text)
            let line = trFormat("Слів: %1$@ · символів: %2$@ · без пробілів: %3$@",
                                "Words: %1$@ · characters: %2$@ · without spaces: %3$@",
                                StatsFormat.number(stats.words), StatsFormat.number(stats.characters),
                                StatsFormat.number(stats.charactersWithoutSpaces))
            // A click copies it, as with the sum.
            model.page = .result(line, copy: line)
            return
        case .sum:
            guard let sum = QuickText.sum(text) else { return }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 10
            formatter.locale = AppLanguage.current.locale
            let shown = formatter.string(from: sum as NSDecimalNumber) ?? "\(sum)"
            model.page = .result("Σ " + shown, copy: "\(sum)".replacingOccurrences(of: ".", with: formatter.decimalSeparator))
            return
        default:
            break
        }
        hide()
        switch action {
        case .openLink: if let link = model.link { NSWorkspace.shared.open(link) }
        case .copy: pressOnSelection(Self.keyC)
        case .cut: pressOnSelection(Self.keyX)
        case .paste: TextInjector.pressKey(Self.keyV, flags: .maskCommand)
        case .plainPaste:
            if let plain = NSPasteboard.general.string(forType: .string) { SelectionConverter.paste(plain) }
        case .search: if let url = settings()?.searchEngine.url(for: text) { NSWorkspace.shared.open(url) }
        case .youtube: if let url = SearchEngine.youtube(text) { NSWorkspace.shared.open(url) }
        case .music: if let url = SearchEngine.music(text) { NSWorkspace.shared.open(url) }
        case .translate: translate()
        case .ai: if let service = model.aiServices.first { open(in: service) }
        case .speak: speak(text)
        case .bold: pressOnSelection(Self.keyB)
        case .italic: pressOnSelection(Self.keyI)
        case .underline: pressOnSelection(Self.keyU)
        case .strikethrough: replace(QuickText.struckThrough)
        case .uppercase: replace { QuickText.uppercased($0, locale: Self.locale(of: $0)) }
        case .lowercase: replace { QuickText.lowercased($0, locale: Self.locale(of: $0)) }
        case .capitalize: replace { QuickText.capitalized($0, locale: Self.locale(of: $0)) }
        case .sentence: replace { QuickText.sentenceCased($0, locale: Self.locale(of: $0)) }
        case .quotes: replace { QuickText.wrapped($0, open: "«", close: "»") }
        case .brackets, .stats, .sum: break
        }
    }

    /// ⌘ and the key, on the text that was selected: some apps drop the selection when the bar is clicked, and
    /// ⌘B then makes the whole paragraph bold, so the selection is put back first.
    private func pressOnSelection(_ key: CGKeyCode) {
        guard let element = model.selection?.element, let saved = model.range else {
            TextInjector.pressKey(key, flags: .maskCommand)
            return
        }
        var current: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &current)
        guard current.map({ !CFEqual($0, saved) }) ?? true else {
            TextInjector.pressKey(key, flags: .maskCommand)
            return
        }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, saved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { TextInjector.pressKey(key, flags: .maskCommand) }
    }

    /// Puts the changed text in place of the selection: through Accessibility where the app allows it,
    /// pasted otherwise (the clipboard is put back).
    private func replace(_ change: (String) -> String) {
        hide()
        let changed = change(model.text)
        guard changed != model.text else { return }
        if let selection = model.selection, selection.replace(with: changed) { return }
        SelectionConverter.paste(changed)
    }

    /// Turkish "i" → "İ" and such: the case rules of the text's own language.
    private static func locale(of text: String) -> Locale {
        NLLanguageRecognizer.dominantLanguage(for: text).map { Locale(identifier: $0.rawValue) } ?? .current
    }

    /// In the system voice of the text's language; pressing again while it speaks stops it.
    private func speak(_ text: String) {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        if let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        speech.speak(utterance)
    }

    /// The AI's Mac app when it is installed (the text is pasted into its message box), its website otherwise.
    private func open(in service: AIService) {
        let text = model.text
        let apps = service.bundleIDs.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
            .filter { service.isApp(named: Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String ?? $0.lastPathComponent) }
        // A new chat with the text in it (a link that long stays within what the app takes).
        if !apps.isEmpty, let link = service.appLink(for: text), link.absoluteString.utf8.count < 16_000 {
            NSWorkspace.shared.open(link)
            return
        }
        if let appURL = apps.first {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.pasteWhenFront(text, bundleIDs: service.bundleIDs, newChat: service.newChatWithCommandN, attempt: 0) }
                }
            }
            return
        }
        let web = service.webURL(for: text)
        NSWorkspace.shared.open(web.url)
        guard !web.carriesText else { return }
        // The site can't take the text in its address: it waits on the clipboard and is pasted once the page
        // is up (the message box has the focus there).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            TextInjector.pressKey(Self.keyV, flags: .maskCommand)
        }
    }

    /// Waits (up to 8 s) for the app to be in front with its window, then pastes.
    /// `newChat`: ⌘N first, so the text goes to a new chat, not the one open.
    private func pasteWhenFront(_ text: String, bundleIDs: [String], newChat: Bool, attempt: Int) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(bundleIDs.contains) ?? false
        if front {
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.4 : 1.2)) {
                guard newChat else { return SelectionConverter.paste(text) }
                TextInjector.pressKey(Self.keyN, flags: .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { SelectionConverter.paste(text) }
            }
        } else if attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.pasteWhenFront(text, bundleIDs: bundleIDs, newChat: newChat, attempt: attempt + 1)
            }
        }
    }
}

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// What the bar shows; the view reads it, the bar fills it.
@MainActor
fileprivate final class QuickActionsModel: ObservableObject {
    enum Page: Equatable {
        case main, brackets, ai
        /// A short answer in the bar itself ("Words: 12…", "Σ 1 234"); `copy`, when set, is copied on a click.
        case result(String, copy: String?)
    }

    @Published var actions: [QuickAction] = []
    @Published var page: Page = .main
    @Published var speaking = false
    var text = ""
    var link: URL?
    var selection: SelectionConverter.Selection?
    /// Where the selection was when the bar appeared (an AXValue range).
    var range: CFTypeRef?
    var aiServices: [AIService] = []
    var run: (QuickAction) -> Void = { _ in }
    var wrap: (String, String) -> Void = { _, _ in }
    var ask: (AIService) -> Void = { _ in }
    var close: () -> Void = {}
    /// How far from the bar's left edge the middle of its second button is (the first when it's alone).
    var anchorOffset: CGFloat?
    var anchorMoved: () -> Void = {}
}

/// The middle of the button that goes at the mouse.
private struct BarAnchorKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

private extension View {
    @ViewBuilder func barAnchor(_ isAnchor: Bool) -> some View {
        if isAnchor {
            background(GeometryReader { Color.clear.preference(key: BarAnchorKey.self, value: $0.frame(in: .named("bar")).midX) })
        } else {
            self
        }
    }
}

private struct QuickActionsView: View {
    @ObservedObject var model: QuickActionsModel
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            switch model.page {
            case .main:
                ForEach(Array(model.actions.enumerated()), id: \.element) { index, action in
                    if index > 0 { separator }
                    BarButton(help: action == .ai && model.aiServices.count == 1 ? model.aiServices[0].title : action.title,
                              action: { model.run(action) }) { label(action) }
                        .barAnchor(index == min(1, model.actions.count - 1))
                }
            case .brackets:
                back
                ForEach(QuickText.brackets, id: \.open) { pair in
                    separator
                    BarButton(help: pair.open + "…" + pair.close, action: { model.wrap(pair.open, pair.close) }) {
                        Text(pair.open + " " + pair.close).font(.system(size: 14, weight: .medium, design: .monospaced))
                    }
                    .barAnchor(pair.open == QuickText.brackets[0].open)
                }
            case .ai:
                back
                ForEach(model.aiServices) { service in
                    separator
                    BarButton(help: trFormat("Відкрити в %@", "Open in %@", service.title), action: { model.ask(service) }) {
                        Text(service.title).font(.system(size: 13))
                    }
                    .barAnchor(service == model.aiServices.first)
                }
            case .result(let text, let copy):
                back
                separator
                BarButton(help: copy == nil ? "" : tr("Копіювати", "Copy"), action: {
                    guard let copy else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { model.close() }
                }) {
                    HStack(spacing: 6) {
                        Text(text).font(.system(size: 13).monospacedDigit())
                        if copy != nil {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        }
                    }
                }
                .barAnchor(true)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        // Light or dark with the system.
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: colorScheme == .dark ? 0.13 : 0.97).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(colorScheme == .dark ? 0.12 : 0.1), lineWidth: 0.5))
        .coordinateSpace(name: "bar")
        .onPreferenceChange(BarAnchorKey.self) { offset in
            MainActor.assumeIsolated {
                model.anchorOffset = offset
                model.anchorMoved()
            }
        }
        .onChange(of: model.page) { copied = false }
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.14)).frame(width: 0.5, height: 18)
    }

    private var back: some View {
        BarButton(help: tr("Назад", "Back"), action: { model.page = .main }) {
            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
        }
    }

    @ViewBuilder private func label(_ action: QuickAction) -> some View {
        if let symbol = action.symbol {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
        } else {
            switch action {
            case .uppercase, .lowercase, .capitalize, .sentence:
                Text(action.label).font(.system(size: 14, weight: .semibold, design: .rounded))
            default:
                Text(action.label).font(.system(size: 13))
            }
        }
    }
}

/// A button of the bar: the system's text colour, blue with white text under the mouse like a menu.
private struct BarButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.9)))
                .padding(.horizontal, 9)
                .frame(minWidth: 30, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
