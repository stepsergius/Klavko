import AppKit
import KlavkoCore
import SwiftUI

/// Mistakes underlined while typing, as in Grammarly: after a short pause the paragraphs of the focused text field
/// that changed are checked with LanguageTool, and each mistake gets a wavy line under it, in a click-through window
/// over the field. Pointing at one shows what's wrong and the fixes; a click puts the fix in.
/// Works in apps that show their text to Accessibility (Notes, Mail, Messages, TextEdit, Safari…).
@MainActor
final class LiveGrammar {
    var checker: GrammarChecker?
    var isOn: () -> Bool = { false }
    /// Apps where Klavko doesn't fix anything: no underlines there either.
    var isExcluded: (String) -> Bool = { _ in false }
    /// The languages the user writes in, to tell which one each paragraph is in.
    var languages: () -> [String] = { ["uk", "en"] }

    /// Paragraph → its issues (offsets in the paragraph). Typing in one paragraph leaves the others' results.
    private var cache: [String: [GrammarIssue]] = [:]
    private var cacheOrder: [String] = []
    /// Mistakes the user chose to leave: rule and word.
    private var ignored: Set<String> = []
    private var checking: Task<Void, Never>?
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var monitors: [Any] = []
    /// What the underlines were drawn for; a change means drawing them again (or checking).
    private var drawnFor: String?
    private var lastKey = Date.distantPast

    private let overlay = UnderlineOverlay()
    private let popup = GrammarPopup()
    /// What's underlined now: the field, its text, and each issue (offsets in the whole text) with where it is.
    private var field: AXUIElement?
    private var fieldText = ""
    private var marks: [(issue: GrammarIssue, rects: [NSRect])] = []
    private var hovered: GrammarIssue?
    private var hoverWork: DispatchWorkItem?

    private static let maxCharacters = 30_000

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let global: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.mouseMoved, { [weak self] _ in self?.mouseMoved() }),
            ([.leftMouseDown, .rightMouseDown], { [weak self] _ in self?.clicked() }),
            (.scrollWheel, { [weak self] _ in self?.scrolled() }),
        ]
        for (mask, handler) in global {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated { handler(event) }
            }) { monitors.append(monitor) }
        }
        // Over the popup the events are Klavko's own.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(monitor) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    self?.clear()
                }
            }
    }

    /// A key typed in some app: the underlines move with the text, so they go until the typing stops.
    func userTyped() {
        lastKey = Date()
        guard !marks.isEmpty || popup.isVisible else { return schedule(after: 0.9) }
        clear()
        schedule(after: 0.9)
    }

    func clear() {
        checking?.cancel()
        overlay.hide()
        popup.close()
        marks = []
        hovered = nil
        drawnFor = nil
    }

    private func schedule(after delay: Double) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clicked() {
        guard !popup.contains(NSEvent.mouseLocation) else { return }
        clear()
        schedule(after: 0.3)
    }

    private func scrolled() {
        guard !marks.isEmpty else { return }
        overlay.hide()
        popup.close()
        drawnFor = nil
        schedule(after: 0.3)
    }

    /// Something changed without a key (a paste, another window, the field moved): check or redraw.
    private func poll() {
        guard Date().timeIntervalSince(lastKey) > 0.9, pending == nil || pending!.isCancelled else { return }
        guard let state = FieldState.focused(), state.signature != drawnFor else { return }
        refresh()
    }

    // MARK: Checking

    private func refresh() {
        pending = nil
        guard isOn(), let checker, checker.isDownloaded,
              let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier, !isExcluded(bundleID),
              let state = FieldState.focused(), state.text.utf16.count <= Self.maxCharacters else {
            return clear()
        }
        let paragraphs = GrammarCheck.paragraphs(of: state.text)
        let missing = paragraphs.filter { cache[$0.text] == nil }
        guard !missing.isEmpty else { return draw(state, paragraphs) }
        checking?.cancel()
        checking = Task { [weak self] in
            for paragraph in missing {
                guard let self, !Task.isCancelled else { return }
                let language = TranslationDirection.language(of: paragraph.text, among: self.languages())
                guard let issues = try? await checker.check(paragraph.text, language: language) else { return }
                guard !Task.isCancelled else { return }
                self.remember(paragraph.text, issues)
            }
            // Drawn only if the text is still what was checked.
            guard let self, !Task.isCancelled, let now = FieldState.focused(), now.text == state.text else { return }
            self.draw(now, paragraphs)
        }
    }

    private func remember(_ paragraph: String, _ issues: [GrammarIssue]) {
        cache[paragraph] = issues
        cacheOrder.append(paragraph)
        if cacheOrder.count > 400 {
            for old in cacheOrder.prefix(100) { cache[old] = nil }
            cacheOrder.removeFirst(100)
        }
    }

    // MARK: Underlines

    private func draw(_ state: FieldState, _ paragraphs: [GrammarCheck.Paragraph]) {
        var issues: [GrammarIssue] = []
        for paragraph in paragraphs {
            for issue in cache[paragraph.text] ?? [] where !isIgnored(issue, in: paragraph.text) {
                issues.append(issue.shifted(by: paragraph.offset))
            }
        }
        issues = GrammarCheck.awayFromCaret(issues, caret: state.caret)
        field = state.element
        fieldText = state.text
        marks = issues.compactMap { issue in
            let rects = state.rects(for: issue)
            return rects.isEmpty ? nil : (issue, rects)
        }
        drawnFor = state.signature
        hovered = nil
        popup.close()
        overlay.show(marks.flatMap { mark in mark.rects.map { ($0, mark.issue.kind.nsColor) } }, clip: state.visibleFrame)
    }

    private func isIgnored(_ issue: GrammarIssue, in text: String) -> Bool {
        ignored.contains(Self.ignoreKey(issue, in: text))
    }

    private static func ignoreKey(_ issue: GrammarIssue, in text: String) -> String {
        issue.ruleID + "|" + (issue.range(in: text).map { text[$0].lowercased() } ?? "")
    }

    // MARK: Pointing at a mistake

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        if popup.isVisible {
            // Kept while the mouse is on the popup or the word.
            if popup.contains(point) || hovered.flatMap({ rects(of: $0) })?.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) == true {
                return
            }
            popup.close()
            hovered = nil
        }
        guard let mark = marks.first(where: { $0.rects.contains { $0.contains(point) } }) else {
            hoverWork?.cancel()
            return
        }
        guard hovered != mark.issue || !popup.isVisible else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, mark.rects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) }) else { return }
            self.hovered = mark.issue
            self.showPopup(for: mark.issue, under: mark.rects)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func rects(of issue: GrammarIssue) -> [NSRect]? {
        marks.first { $0.issue == issue }?.rects
    }

    private func showPopup(for issue: GrammarIssue, under rects: [NSRect]) {
        let word = issue.range(in: fieldText).map { String(fieldText[$0]) } ?? ""
        popup.show(issue: issue, word: word, near: rects.first ?? .zero,
                   onFix: { [weak self] replacement in self?.fix(issue, with: replacement) },
                   onIgnore: { [weak self] in self?.ignore(issue) })
    }

    private func fix(_ issue: GrammarIssue, with replacement: String) {
        popup.close()
        guard let field else { return }
        // The click on the popup can take the keyboard focus from the app (Chromium apps then drop it from the
        // text): give it back, then fix once it has it.
        NSWorkspace.shared.frontmostApplication?.activate()
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let text = fieldText
        overlay.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.fix(issue, with: replacement, in: field, text: text)
        }
    }

    private func fix(_ issue: GrammarIssue, with replacement: String, in field: AXUIElement, text fieldText: String) {
        guard let range = issue.range(in: fieldText) else { return }
        let original = String(fieldText[range])
        let expected = fieldText.replacingCharacters(in: range, with: replacement)
        let caret = Self.selectedRange(of: field)
        var cfRange = CFRange(location: issue.offset, length: issue.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return }
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
        clear()
        schedule(after: 0.8)
        // Some apps take a moment to select; some say yes and leave the caret where it was (the fix would then land
        // next to the word, not over it), so it's put in only once the word itself is selected.
        Self.wait(until: { Self.selectedText(of: field) == original }) { selected in
            if selected {
                let selection = SelectionConverter.Selection(text: original, element: field)
                if selection.replace(with: replacement), Self.value(of: field) == expected { return self.log(issue, "accessibility") }
                if Self.value(of: field) != fieldText { return self.log(issue, "accessibility, changed differently") }
                // Nothing changed (Chromium apps ignore it): paste over the selected word (the clipboard is put back).
                SelectionConverter.paste(replacement)
                return self.log(issue, "paste")
            }
            // Select the word with the arrow keys from the caret, then paste over it.
            let now = Self.selectedRange(of: field)
            guard let caret = now?.length == 0 ? now : caret, caret.length == 0,
                  let caretIndex = Self.index(caret.location, in: fieldText) else { return self.log(issue, "skipped: no caret") }
            let wordEnd = range.upperBound
            let moves = caretIndex <= wordEnd ? fieldText[caretIndex..<wordEnd].count : -fieldText[wordEnd..<caretIndex].count
            let arrow: CGKeyCode = moves >= 0 ? 124 : 123
            for _ in 0..<abs(moves) { TextInjector.pressKey(arrow) }
            for _ in 0..<original.count { TextInjector.pressKey(123, flags: .maskShift) }
            Self.wait(until: { Self.selectedText(of: field) == original }) { selected in
                // Pasted only over exactly the word.
                guard selected else { return Log.engine.error("Live grammar: couldn't select the word, not fixed") }
                SelectionConverter.paste(replacement)
                self.log(issue, "arrows")
            }
        }
    }

    /// Checks `condition` a few times over about half a second, then says whether it came true.
    private static func wait(until condition: @escaping () -> Bool, attempt: Int = 0, then done: @escaping (Bool) -> Void) {
        if condition() { return done(true) }
        guard attempt < 8 else { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated { wait(until: condition, attempt: attempt + 1, then: done) }
        }
    }

    private func log(_ issue: GrammarIssue, _ how: String) {
        Log.engine.notice("Live grammar: fixed \(issue.ruleID, privacy: .public) by \(how, privacy: .public)")
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        return value as? String
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        return value as? String
    }

    /// A UTF-16 offset as an index of `text`.
    private static func index(_ offset: Int, in text: String) -> String.Index? {
        let utf16 = text.utf16
        guard offset >= 0, offset <= utf16.count else { return nil }
        return utf16.index(utf16.startIndex, offsetBy: offset).samePosition(in: text)
    }

    private func ignore(_ issue: GrammarIssue) {
        popup.close()
        for paragraph in GrammarCheck.paragraphs(of: fieldText)
        where paragraph.offset <= issue.offset && issue.offset < paragraph.offset + paragraph.text.utf16.count {
            ignored.insert(Self.ignoreKey(issue.shifted(by: -paragraph.offset), in: paragraph.text))
        }
        marks.removeAll { $0.issue == issue }
        overlay.show(marks.flatMap { mark in mark.rects.map { ($0, mark.issue.kind.nsColor) } }, clip: overlay.clip)
    }
}

/// The focused text field and what's in it, read through Accessibility.
@MainActor
private struct FieldState {
    let element: AXUIElement
    let text: String
    let caret: Int?
    /// Where the text can be seen (the scroll view around it), in AppKit coordinates.
    let visibleFrame: NSRect
    let signature: String
    /// Filled the first time an underline needs it.
    private let runCache = RunCache()

    final class RunCache {
        var value: [(element: AXUIElement, offset: Int, length: Int)]?
    }

    /// Apps already asked to show their text (Electron apps such as Obsidian, Slack, VS Code show it only when asked).
    private static var askedApps: Set<pid_t> = []

    static func focused() -> FieldState? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        if !askedApps.contains(app.processIdentifier) {
            askedApps.insert(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        let role = string(element, kAXRoleAttribute)
        guard role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole,
              string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return nil }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let number = count as? Int, number > 30_000 { return nil }
        guard let text = string(element, kAXValueAttribute), !text.isEmpty,
              let ownFrame = frame(of: element) else { return nil }
        var caret: Int?
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) { caret = range.location + range.length }
        }
        // A text view scrolls inside its scroll area: only that part is on screen.
        var visible = ownFrame
        var parent: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent,
           CFGetTypeID(parent) == AXUIElementGetTypeID(), string(parent as! AXUIElement, kAXRoleAttribute) == kAXScrollAreaRole,
           let scrollFrame = frame(of: parent as! AXUIElement) {
            visible = ownFrame.intersection(scrollFrame)
        }
        let signature = "\(text.hashValue)|\(caret ?? -1)|\(Int(ownFrame.minX)),\(Int(ownFrame.minY)),\(Int(ownFrame.width)),\(Int(ownFrame.height))"
        return FieldState(element: element, text: text, caret: caret, visibleFrame: visible, signature: signature)
    }

    /// Where an issue's text is on screen: one rectangle a line (an issue split by a line wrap gets two).
    func rects(for issue: GrammarIssue) -> [NSRect] {
        guard let whole = bounds(issue.offset, issue.length) else { return [] }
        guard let first = bounds(issue.offset, 1), whole.height > first.height * 1.5,
              let last = bounds(issue.offset + issue.length - 1, 1) else { return [whole] }
        return [NSRect(x: first.minX, y: first.minY, width: max(whole.maxX - first.minX, first.width), height: first.height),
                NSRect(x: whole.minX, y: last.minY, width: last.maxX - whole.minX, height: last.height)]
    }

    /// The field's own answer; in Chromium and Electron apps (Obsidian, Slack…), which answer with an empty
    /// rectangle, the line of text inside it that holds the range.
    private func bounds(_ location: Int, _ length: Int) -> NSRect? {
        if let rect = Self.bounds(of: element, location, length) { return rect }
        guard let run = runs.last(where: { $0.offset <= location }),
              location + length <= run.offset + run.length else { return nil }
        return Self.bounds(of: run.element, location - run.offset, length)
    }

    /// The lines of text inside the field and where each starts in its value (UTF-16 units).
    private var runs: [(element: AXUIElement, offset: Int, length: Int)] {
        if let cached = runCache.value { return cached }
        var result: [(element: AXUIElement, offset: Int, length: Int)] = []
        var searchFrom = text.startIndex
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 8, visited < 3000 else { return }
            for child in Self.children(of: element) {
                visited += 1
                if Self.string(child, kAXRoleAttribute) == kAXStaticTextRole, let value = Self.string(child, kAXValueAttribute),
                   !value.isEmpty, let found = text.range(of: value, range: searchFrom..<text.endIndex) {
                    result.append((child, text.utf16.distance(from: text.startIndex, to: found.lowerBound), value.utf16.count))
                    searchFrom = found.upperBound
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(element, depth: 0)
        runCache.value = result
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func bounds(of element: AXUIElement, _ location: Int, _ length: Int) -> NSRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
        guard rect.width > 0, rect.height > 0, rect.height < 400,
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        // Accessibility counts from the top of the main screen; AppKit from its bottom.
        return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

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
}

// MARK: - The wavy lines

/// A click-through window over the field that only draws the lines.
@MainActor
private final class UnderlineOverlay {
    private var window: NSWindow?
    private let view = UnderlineView()
    private(set) var clip = NSRect.zero

    func show(_ lines: [(NSRect, NSColor)], clip: NSRect) {
        self.clip = clip
        let frame = clip.insetBy(dx: -2, dy: -4)
        guard !lines.isEmpty, frame.width > 0, frame.height > 0 else { return hide() }
        let window = self.window ?? makeWindow()
        window.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.lines = lines.map { (NSRect(x: $0.0.minX - frame.minX, y: $0.0.minY - frame.minY, width: $0.0.width, height: $0.0.height), $0.1) }
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.contentView = view
        self.window = window
        return window
    }
}

private final class UnderlineView: NSView {
    var lines: [(NSRect, NSColor)] = []

    override func draw(_ dirtyRect: NSRect) {
        for (rect, color) in lines {
            // A wave just under the text.
            let path = NSBezierPath()
            let y = rect.minY + 1
            let step: CGFloat = 2.5
            var x = rect.minX
            path.move(to: NSPoint(x: x, y: y))
            var up = true
            while x < rect.maxX {
                x = min(x + step, rect.maxX)
                path.line(to: NSPoint(x: x, y: up ? y + 1.5 : y))
                up.toggle()
            }
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
    }
}

// MARK: - The popup

@MainActor
private final class GrammarPopup {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func contains(_ point: NSPoint) -> Bool {
        isVisible && panel!.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    func show(issue: GrammarIssue, word: String, near rect: NSRect,
              onFix: @escaping (String) -> Void, onIgnore: @escaping () -> Void) {
        close()
        let view = GrammarPopupView(issue: issue, word: word, onFix: onFix, onIgnore: onIgnore)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.contentViewController = controller
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        controller.view.layoutSubtreeIfNeeded()
        let size = controller.view.fittingSize
        panel.setContentSize(size)
        // Under the word; over it when there's no room below.
        let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame ?? rect
        var origin = NSPoint(x: rect.minX - 8, y: rect.minY - size.height - 4)
        if origin.y < visible.minY { origin.y = rect.maxY + 4 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct GrammarPopupView: View {
    let issue: GrammarIssue
    let word: String
    let onFix: (String) -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(issue.kind.color).frame(width: 7, height: 7)
                Text(issue.kind.title.capitalized(with: AppLanguage.current.locale))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(issue.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            FlowRow(spacing: 6) {
                ForEach(issue.replacements.prefix(4), id: \.self) { replacement in
                    Button { onFix(replacement) } label: {
                        Text(replacement.isEmpty ? tr("(прибрати)", "(remove)") : replacement)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Button(tr("Пропустити", "Ignore"), action: onIgnore)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(.vertical, 4)
                    .padding(.leading, 4)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
    }
}

extension GrammarIssue.Kind {
    var nsColor: NSColor {
        switch self {
        case .spelling: .systemRed
        case .grammar: .systemOrange
        case .punctuation: .systemBlue
        case .typography: .systemPurple
        case .style: .systemTeal
        }
    }
}
