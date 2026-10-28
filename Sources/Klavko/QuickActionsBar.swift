import AppKit
import AVFoundation
import KlavkoCore
import NaturalLanguage
import SwiftUI

/// Quick Actions: after text is selected with the mouse (a drag, a double or triple click), a small dark bar
/// appears over or under it with what can be done to the text; holding the mouse down in a text field brings
/// it up with just "Paste". The second button sits right at the mouse, the first to its left, the rest to its
/// right. Any click elsewhere, a key or scrolling hides it. Brought up by the hotkey, it takes the keyboard:
/// ← → move along it, Return runs the highlighted action, Esc closes it.
/// The bar never takes the focus: the app with the selection stays in front, so copy and paste go to it.
@MainActor
final class QuickActionsBar {
    var settings: () -> Settings? = { nil }
    /// "Translate": the translation panel, which reads the selection itself.
    var translate: () -> Void = {}
    /// "Check spelling": the spelling panel, which reads the selection itself.
    var checkText: () -> Void = {}
    /// The emoji, the ones used lately, and the list near the caret while an emoji is typed by name.
    var emoji: EmojiInput?

    fileprivate let model = QuickActionsModel()
    private var panel: BarPanel?
    private var monitors: [Any] = []
    private var downPoint: NSPoint?
    private var pending: DispatchWorkItem?
    /// A long press in a text field: "Paste" once the mouse has been held still long enough.
    private var holding: DispatchWorkItem?
    private let speech = AVSpeechSynthesizer()
    /// Where the second button goes (the mouse), kept when the bar changes width (a submenu, an answer).
    private var anchorX: CGFloat = 0
    /// The bar's edge next to the text (its bottom over it, its top under it): it stays when the bar grows or
    /// shrinks (the emoji groups come and go), so the bar never covers the text.
    private var textEdge: (y: CGFloat, above: Bool) = (0, true)
    /// How wide the bar with all its actions was last: the emoji list is as wide.
    private var fullWidth: CGFloat = 400

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
            // The emoji list near the caret stays while its name is typed (the typing engine closes it).
            if event.type == .keyDown, isShowingEmojiList { return }
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
              NSPasteboard.general.string(forType: .string)?.isEmpty == false || settings.quickActions.contains(.emoji)
        else { return }
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
             only: [.paste, .plainPaste, .emoji])
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
            show(text: selection.text, selection: selection, editable: info.editable, around: info.bounds ?? mouseRect,
                 settings: settings, byKeyboard: byHotkey)
            return
        }
        // Apps that don't share the selection: copy it (the clipboard is put back). Never in Finder, where
        // a drag selects files, not text.
        guard app.bundleIdentifier != "com.apple.finder" else { return }
        SelectionConverter.copySelection { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                // Unknown: offer the editing actions too (in a page that can't change, they do nothing).
                self.show(text: text, selection: nil, editable: true, around: mouseRect, settings: settings, byKeyboard: byHotkey)
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
                      settings: Settings, only: Set<QuickAction>? = nil, byKeyboard: Bool = false) {
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
        model.keyIndex = byKeyboard ? 0 : nil
        model.page = .main
        model.emojiNearCaret = false
        model.emojiFitted = false
        model.speaking = speech.isSpeaking
        model.run = { [weak self] action in self?.run(action) }
        model.wrap = { [weak self] open, close in self?.replace { QuickText.wrapped($0, open: open, close: close) } }
        model.ask = { [weak self] service in self?.hideThen { self?.open(in: service) } }
        model.close = { [weak self] in self?.hide() }
        model.anchorMoved = { [weak self] in self?.keepAnchored() }
        model.insertEmoji = { [weak self] emoji in self?.insertFromList(emoji) }
        present(around: rect, position: settings.quickActionsPosition, takesKeys: byKeyboard)
    }

    // MARK: Emoji

    /// The bar's Emoji action: all the emoji, the five used lately first; ← → choose, Return puts it in.
    private func showEmojiPage() {
        guard let catalog = emoji?.currentCatalog() else { return }
        let sections = catalog.sections(recent: emoji?.recent ?? [])
        model.emojiRecentCount = 0
        model.emojis = sections.flatMap(\.emojis)
        model.emojiGroups = Self.marks(sections)
        model.groupFocus = nil
        // All of them scroll (the few after a word fit, which this list must not).
        model.emojiFitted = false
        model.emojiWidth = fullWidth
        model.page = .emoji
        model.keyIndex = 1
        // The arrows go to the bar now (the app with the text stays in front).
        if let panel, !panel.takesKeys {
            panel.takesKeys = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Where each part of the whole list starts, and its name.
    private static func marks(_ sections: [EmojiCatalog.Section]) -> [QuickActionsModel.GroupMark] {
        var start = 0
        return sections.map { section in
            defer { start += section.emojis.count }
            return QuickActionsModel.GroupMark(title: title(of: section.group), start: start)
        }
    }

    static func title(of group: EmojiCatalog.Group?) -> String {
        switch group {
        case nil: tr("Останні", "Recent")
        case .smileys: tr("Смайли та емоції", "Smileys & Emotion")
        case .people: tr("Люди й тіло", "People & Body")
        case .animals: tr("Тварини й природа", "Animals & Nature")
        case .food: tr("Їжа й напої", "Food & Drink")
        case .travel: tr("Подорожі й місця", "Travel & Places")
        case .activities: tr("Активності", "Activities")
        case .objects: tr("Предмети", "Objects")
        case .symbols: tr("Символи", "Symbols")
        case .flags: tr("Прапори", "Flags")
        }
    }

    /// An emoji picked on the Emoji page: typed where the caret (or the selection) is.
    private func insertFromList(_ emoji: String) {
        guard !model.emojiNearCaret else {
            self.emoji?.clicked(emoji)
            return
        }
        self.emoji?.used(emoji)
        hideThen { TextInjector.type(emoji) }
    }

    /// The emoji list near the caret: found by the name typed after " :", or offered after a word.
    var isShowingEmojiList: Bool { panel?.isVisible == true && model.page == .emoji && model.emojiNearCaret }

    var emojiListContainsMouse: Bool {
        isShowingEmojiList && panel!.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    var highlightedEmoji: String? {
        guard isShowingEmojiList, model.groupFocus == nil, let index = model.keyIndex, model.emojis.indices.contains(index)
        else { return nil }
        return model.emojis[index]
    }

    /// The keyboard on the groups over the emoji (the list after a bare colon).
    var isOnEmojiGroups: Bool { isShowingEmojiList && model.groupFocus != nil }

    /// ↑ in the list near the caret: to the groups; false when it has none.
    func emojiListUp() -> Bool { isShowingEmojiList && model.focusGroups() }

    /// ↓ in the list near the caret: from a group to its first emoji; false when it has no groups.
    func emojiListDown() -> Bool {
        guard isShowingEmojiList, !model.emojiGroups.isEmpty else { return false }
        model.enterGroup()
        return true
    }

    /// The whole list near the caret (after a bare colon): its parts named over it.
    func showEmojiSections(_ sections: [EmojiCatalog.Section]) {
        showEmojiList(sections.flatMap(\.emojis), highlighted: false, groups: Self.marks(sections))
    }

    /// `recentCount`: how many of `emojis` are the latest used (a divider after them). Not `highlighted`: none is
    /// picked until an arrow is pressed (Return goes on to the app). `fitted`: the few offered after a word, the bar
    /// as wide as they are and over the caret.
    func showEmojiList(_ emojis: [String], recentCount: Int = 0, highlighted: Bool = true, fitted: Bool = false,
                       groups: [QuickActionsModel.GroupMark] = []) {
        let wasShowing = isShowingEmojiList
        model.emojis = emojis
        model.emojiRecentCount = recentCount
        model.emojiGroups = groups
        model.groupFocus = nil
        model.emojiWidth = fullWidth
        model.emojiFitted = fitted
        model.emojiNearCaret = true
        model.page = .emoji
        model.keyIndex = highlighted ? 0 : nil
        model.insertEmoji = { [weak self] emoji in self?.insertFromList(emoji) }
        model.close = { [weak self] in self?.hide() }
        model.anchorMoved = { [weak self] in self?.keepAnchored() }
        guard !wasShowing else { return }
        // Where the bar comes up, over (or under) the line, its first emoji at the caret; where the app doesn't tell,
        // at the mouse.
        let mouse = NSEvent.mouseLocation
        // A caret's rect is a sliver within the line (TextEdit's ends above the descenders): a little room below it.
        let caret = Self.caretRect().map { NSRect(x: $0.minX, y: $0.minY - 6, width: $0.width, height: $0.height + 6) }
        let position = fitted ? .above : settings()?.quickActionsPosition ?? .above
        present(around: caret ?? Self.rect(from: mouse, to: mouse), position: position, takesKeys: false)
    }

    func hideEmojiList() {
        if isShowingEmojiList { hide() }
    }

    func moveInEmojiList(by step: Int) {
        if model.groupFocus != nil { return model.moveGroup(by: step) }
        guard let index = model.keyIndex else {
            model.keyIndex = 0
            return
        }
        model.keyIndex = min(max(index + step, 0), model.emojis.count - 1)
    }

    /// Where the caret of the focused text field is, in AppKit coordinates.
    private static func caretRect() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        // Electron apps (Slack, Obsidian…) tell where the caret is only when asked.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = focused as! AXUIElement
        // Where the caret is, not the mouse: some apps answer with the next character's or the line's width.
        if let bounds = details(of: field).bounds { return NSRect(x: bounds.minX, y: bounds.minY, width: 0, height: bounds.height) }
        // Many apps (Telegram, browsers) have no bounds for an empty selection: the character before the caret
        // ends where it is, the one after starts there.
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
            if range.location > 0, let before = bounds(of: CFRange(location: range.location - 1, length: 1), in: field) {
                return NSRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
            }
            if let after = bounds(of: CFRange(location: range.location, length: 1), in: field) {
                return NSRect(x: after.minX, y: after.minY, width: 0, height: after.height)
            }
        }
        // Chromium and Electron (Claude, Slack…) tell it by text markers.
        var markers: CFTypeRef?
        var markerBounds: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, "AXSelectedTextMarkerRange" as CFString, &markers) == .success, let markers,
           AXUIElementCopyParameterizedAttributeValue(field, "AXBoundsForTextMarkerRange" as CFString, markers,
                                                      &markerBounds) == .success,
           let markerBounds, CFGetTypeID(markerBounds) == AXValueGetTypeID(),
           let mainHeight = NSScreen.screens.first?.frame.height {
            var rect = CGRect.zero
            AXValueGetValue(markerBounds as! AXValue, .cgRect, &rect)
            let flipped = NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: 0, height: rect.height)
            // An empty field answers with all of it: its start is the caret then.
            if rect.height > 0, rect.height < 200, NSScreen.screens.contains(where: { $0.frame.contains(flipped.origin) }) {
                return flipped
            }
        }
        // Nothing about the caret: a field of a line or a few, at its start (the mouse may be anywhere).
        if let frame = frame(of: field), frame.height < 120 {
            return NSRect(x: frame.minX + 12, y: frame.minY, width: 0, height: frame.height)
        }
        return nil
    }

    /// Where `range` of the text in `field` is, in AppKit coordinates.
    private static func bounds(of range: CFRange, in field: AXUIElement) -> NSRect? {
        var range = range
        var boundsValue: CFTypeRef?
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
        guard rect.height > 0, rect.height < 200, let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let flipped = NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        return NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) ? flipped : nil
    }

    private func present(around rect: NSRect, position: QuickActionsPosition, takesKeys: Bool) {
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
            panel.onKey = { [weak self] event in self?.key(event) ?? false }
            self.panel = panel
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepAnchored() }
            }
        }
        guard let panel else { return }
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
        panel.setContentSize(size)
        if model.page == .main, model.actions.count > 3 { fullWidth = size.width }
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
        let above = origin.y >= rect.midY
        textEdge = (above ? origin.y : origin.y + size.height, above)
        panel.takesKeys = takesKeys
        if takesKeys {
            // Key without bringing Klavko forward (the panel doesn't activate): the app with the selection stays
            // in front and gets the keyboard back when the bar goes.
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// The keyboard while the bar has it: true when the key was used.
    private func key(_ event: NSEvent) -> Bool {
        guard let index = model.keyIndex else { return false }
        if model.page == .emoji, !model.emojiGroups.isEmpty {
            switch event.keyCode {
            case 126: return model.focusGroups()  // ↑
            case 125: model.enterGroup(); return true  // ↓
            case 123, 124 where model.groupFocus != nil: model.moveGroup(by: event.keyCode == 123 ? -1 : 1); return true
            default: break
            }
        }
        switch event.keyCode {
        case 123: model.keyIndex = max(index - 1, 0)  // ←
        case 124: model.keyIndex = min(index + 1, model.itemCount - 1)  // →
        case 36, 76: model.perform(index)  // Return, Enter
        default: hide()  // Esc, or any other key
        }
        return true
    }

    /// The second button back at the mouse once the bar has measured where it is.
    private func keepAnchored() {
        guard let panel, let visible = panel.screen?.visibleFrame else { return }
        let offset = model.anchorOffset ?? panel.frame.width / 2
        let x = min(max(anchorX - offset, visible.minX + 4), visible.maxX - panel.frame.width - 4)
        let height = panel.frame.height
        let y = min(max(textEdge.above ? textEdge.y : textEdge.y - height, visible.minY + 4), visible.maxY - height - 4)
        if panel.frame.origin != NSPoint(x: x, y: y) { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.takesKeys = false
    }

    /// Hides the bar, then does the work: a moment later when the bar had the keyboard, so keys pressed for the
    /// action (⌘C, ⌘V…) reach the app again.
    private func hideThen(_ work: @escaping () -> Void) {
        let hadKeyboard = panel?.isKeyWindow == true
        hide()
        if hadKeyboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            work()
        }
    }

    // MARK: Actions

    private static let keyB: CGKeyCode = 11, keyC: CGKeyCode = 8, keyI: CGKeyCode = 34, keyN: CGKeyCode = 45, keyReturn: CGKeyCode = 36, keyU: CGKeyCode = 32,
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
        case .emoji:
            showEmojiPage()
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
        hideThen { [self] in
        switch action {
        case .openLink: if let link = model.link { NSWorkspace.shared.open(link) }
        case .copy: pressOnSelection(Self.keyC)
        case .cut: pressOnSelection(Self.keyX)
        case .paste: TextInjector.pressKey(Self.keyV, flags: .maskCommand)
        case .plainPaste:
            if let plain = NSPasteboard.general.string(forType: .string) { SelectionConverter.paste(plain) }
        case .search: if let url = settings()?.searchEngine.url(for: text) { NSWorkspace.shared.open(url) }
        case .youtube: if let url = SearchEngine.youtube(text) { NSWorkspace.shared.open(url) }
        case .music: searchInMusic(text)
        case .translate: translate()
        case .check: checkText()
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
        case .brackets, .stats, .sum, .emoji: break
        }
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
    private func replace(_ change: @escaping (String) -> String) {
        hideThen { [self] in
            let changed = change(model.text)
            guard changed != model.text else { return }
            if let selection = model.selection, selection.replace(with: changed) { return }
            SelectionConverter.paste(changed)
        }
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

    /// The Music app's own search: its search links open an empty page, so the text is typed into the search
    /// field (a value set through Accessibility isn't searched for) and Return pressed.
    private func searchInMusic(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.typeInMusic(query, attempt: 0) }
            }
        }
    }

    private static let musicID = "com.apple.Music"

    /// Waits (up to 8 s) for Music to be in front with its search field, then types.
    private func typeInMusic(_ query: String, attempt: Int) {
        let retry = { [weak self] in
            guard attempt < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.typeInMusic(query, attempt: attempt + 1) }
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == Self.musicID else { return retry() }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return retry() }
        let window = windowValue as! AXUIElement
        // "Search" is the first row of the sidebar; its page has the search field in the toolbar (the other
        // search field, "filterField", filters a list).
        if let sidebar = Self.firstElement(in: window, where: { Self.string($0, kAXRoleAttribute) == kAXOutlineRole }),
           let searchRow = Self.children(of: sidebar).first(where: { Self.string($0, kAXRoleAttribute) == kAXRowRole }) {
            AXUIElementSetAttributeValue(searchRow, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
        guard let field = Self.firstElement(in: window, where: {
            Self.string($0, kAXSubroleAttribute) == "AXSearchField" && Self.string($0, kAXIdentifierAttribute) != "filterField"
        }) else { return retry() }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            TextInjector.type(query)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { TextInjector.pressKey(Self.keyReturn) }
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    private static func firstElement(in element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth < 12 else { return nil }
        for child in children(of: element) {
            if let found = firstElement(in: child, depth: depth + 1, where: match) { return found }
        }
        return nil
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
    /// Only when brought up by the hotkey: then the arrows and Return go to the bar.
    var takesKeys = false
    var onKey: (NSEvent) -> Bool = { _ in false }

    override var canBecomeKey: Bool { takesKeys }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, takesKeys, onKey(event) { return }
        super.sendEvent(event)
    }
}

/// What the bar shows; the view reads it, the bar fills it.
@MainActor
final class QuickActionsModel: ObservableObject {
    enum Page: Equatable {
        case main, brackets, ai, emoji
        /// A short answer in the bar itself ("Words: 12…", "Σ 1 234"); `copy`, when set, is copied on a click.
        case result(String, copy: String?)
    }

    @Published var actions: [QuickAction] = []
    @Published var page: Page = .main {
        // From the keyboard, a submenu starts on its first choice (after "Back"), the bar on its first action.
        didSet { if keyIndex != nil { keyIndex = page == .main ? 0 : 1 } }
    }
    @Published var speaking = false
    /// The button the keyboard is on (the bar brought up by the hotkey); nil when it's used with the mouse.
    @Published var keyIndex: Int?
    @Published var copied = false
    var text = ""
    var link: URL?
    var selection: SelectionConverter.Selection?
    /// Where the selection was when the bar appeared (an AXValue range).
    var range: CFTypeRef?
    var aiServices: [AIService] = []
    /// How wide the Emoji page is: as the bar with all its actions.
    @Published var emojiWidth: CGFloat = 400
    /// Only as wide as its emoji (the few offered after a word).
    @Published var emojiFitted = false
    /// The Emoji page: the emoji, the first `emojiRecentCount` of them the latest used.
    @Published var emojis: [String] = []
    var emojiRecentCount = 0
    /// The emoji list near the caret (typed by name, offered after a word): no Back, the keyboard stays with the app.
    var emojiNearCaret = false
    /// Where each group starts in `emojis` (the whole list only), named over the emoji.
    struct GroupMark: Equatable {
        let title: String
        let start: Int
    }
    @Published var emojiGroups: [GroupMark] = []
    /// The group the keyboard is on (↑ from the emoji); nil: on the emoji.
    @Published var groupFocus: Int?
    /// ↓ just went into a group: its first emoji stays at the start, where the group brought it.
    var enteredGroup = false
    var insertEmoji: (String) -> Void = { _ in }
    var run: (QuickAction) -> Void = { _ in }
    var wrap: (String, String) -> Void = { _, _ in }
    var ask: (AIService) -> Void = { _ in }
    var close: () -> Void = {}
    /// How far from the bar's left edge the middle of its second button is (the first when it's alone).
    var anchorOffset: CGFloat?
    var anchorMoved: () -> Void = {}

    /// The group named over the emoji: the one the keyboard is on, or the one with the emoji it's on.
    var currentGroup: Int {
        if let groupFocus { return groupFocus }
        let index = (keyIndex ?? 0) - (emojiNearCaret ? 0 : 1)
        return emojiGroups.lastIndex { $0.start <= index } ?? 0
    }

    /// ↑ from the emoji: to the groups. False when there are none.
    func focusGroups() -> Bool {
        guard !emojiGroups.isEmpty else { return false }
        if groupFocus == nil { groupFocus = currentGroup }
        return true
    }

    func moveGroup(by step: Int) {
        guard let groupFocus else { return }
        self.groupFocus = min(max(groupFocus + step, 0), emojiGroups.count - 1)
    }

    /// ↓ (or Return) from a group: to its first emoji.
    func enterGroup() {
        guard let groupFocus else { return }
        enteredGroup = true
        keyIndex = emojiGroups[groupFocus].start + (emojiNearCaret ? 0 : 1)
        self.groupFocus = nil
    }

    /// The buttons on the page: in a submenu or an answer, "Back" comes first.
    var itemCount: Int {
        switch page {
        case .main: actions.count
        case .emoji: (emojiNearCaret ? 0 : 1) + emojis.count
        case .brackets: 1 + QuickText.brackets.count
        case .ai: 1 + aiServices.count
        case .result: 2
        }
    }

    /// What a click on the button at `index` does.
    func perform(_ index: Int) {
        if page == .emoji {
            if groupFocus != nil { return enterGroup() }
            let offset = emojiNearCaret ? 0 : 1
            if index < offset { page = .main } else if emojis.indices.contains(index - offset) { insertEmoji(emojis[index - offset]) }
            return
        }
        if page != .main && index == 0 {
            page = .main
            return
        }
        switch page {
        case .main: if actions.indices.contains(index) { run(actions[index]) }
        case .brackets: let pair = QuickText.brackets[index - 1]; wrap(pair.open, pair.close)
        case .ai: if aiServices.indices.contains(index - 1) { ask(aiServices[index - 1]) }
        case .result(_, let copy): copyResult(copy)
        case .emoji: break
        }
    }

    /// The answer to the clipboard, a tick, then the bar closes.
    func copyResult(_ copy: String?) {
        guard let copy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copy, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.close() }
    }
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
    @Environment(\.colorScheme) private var colorScheme
    /// When the keyboard last moved along the emoji (a held arrow comes every few hundredths of a second).
    @State private var lastMove = Date.distantPast

    var body: some View {
        HStack(spacing: 0) {
            switch model.page {
            case .main:
                ForEach(Array(model.actions.enumerated()), id: \.element) { index, action in
                    if index > 0 { separator }
                    BarButton(help: action == .ai && model.aiServices.count == 1 ? model.aiServices[0].title : action.title,
                              selected: model.keyIndex == index, action: { model.run(action) }) { label(action) }
                        .barAnchor(index == min(1, model.actions.count - 1))
                }
            case .brackets:
                back
                ForEach(Array(QuickText.brackets.enumerated()), id: \.element.open) { index, pair in
                    separator
                    BarButton(help: pair.open + "…" + pair.close, selected: model.keyIndex == index + 1,
                              action: { model.wrap(pair.open, pair.close) }) {
                        Text(pair.open + " " + pair.close).font(.system(size: 14, weight: .medium, design: .monospaced))
                    }
                    .barAnchor(pair.open == QuickText.brackets[0].open)
                }
            case .ai:
                back
                ForEach(Array(model.aiServices.enumerated()), id: \.element) { index, service in
                    separator
                    BarButton(help: trFormat("Відкрити в %@", "Open in %@", service.title), selected: model.keyIndex == index + 1,
                              action: { model.ask(service) }) {
                        Text(service.title).font(.system(size: 13))
                    }
                    .barAnchor(service == model.aiServices.first)
                }
            case .emoji:
                emojiPage
            case .result(let text, let copy):
                back
                separator
                BarButton(help: copy == nil ? "" : tr("Копіювати", "Copy"), selected: model.keyIndex == 1,
                          action: { model.copyResult(copy) }) {
                    HStack(spacing: 6) {
                        Text(text).font(.system(size: 13).monospacedDigit())
                        if copy != nil {
                            Image(systemName: model.copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        }
                    }
                }
                .barAnchor(true)
            }
        }
        .padding(.horizontal, 3)
        // The whole emoji list has its groups named over it.
        .frame(height: model.page == .emoji && !model.emojiGroups.isEmpty ? 60 : 32)
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
        .onChange(of: model.page) { model.copied = false }
    }

    /// Emoji in a row that scrolls with the keyboard (the bar stays put); after the latest used, a divider.
    private var emojiPage: some View {
        let offset = model.emojiNearCaret ? 0 : 1
        return HStack(spacing: 0) {
            if model.emojiFitted {
                HStack(spacing: 0) { emojiButtons(offset: offset) }
                    .background(firstEmojiAnchor)
            } else {
                scrollingEmoji(offset: offset)
            }
        }
    }

    /// All the emoji (or the found ones) in a row as wide as the bar with all its actions; the whole list with the
    /// names of its groups over it.
    private func scrollingEmoji(offset: Int) -> some View {
        HStack(spacing: 0) {
            if !model.emojiNearCaret {
                back
                separator
            }
            VStack(spacing: 0) {
                if !model.emojiGroups.isEmpty {
                    groupRow
                    Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5).padding(.horizontal, 4)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) { emojiButtons(offset: offset) }
                    }
                    .frame(height: 32)
                    .onChange(of: model.keyIndex) {
                        guard let key = model.keyIndex, key >= offset else { return }
                        let anchor: UnitPoint = model.enteredGroup ? .leading : .center
                        model.enteredGroup = false
                        // An arrow held down moves faster than an animation: then the row follows at once.
                        let now = Date()
                        let held = now.timeIntervalSince(lastMove) < 0.15
                        lastMove = now
                        if held {
                            proxy.scrollTo(key - offset, anchor: anchor)
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(key - offset, anchor: anchor) }
                        }
                    }
                    // A group chosen: its emoji come up.
                    .onChange(of: model.groupFocus) {
                        guard let group = model.groupFocus, model.emojiGroups.indices.contains(group) else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(model.emojiGroups[group].start, anchor: .leading) }
                    }
                    // Measured on the row's frame, which doesn't scroll: the bar stays put.
                    .background(firstEmojiAnchor)
                }
            }
        }
        // The bar's 3-point margins aside.
        .frame(width: max(model.emojiWidth - 6, 120))
    }

    /// The names of the groups, the current one marked (filled when the keyboard is on it); ↑ goes to them.
    private var groupRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.emojiGroups.enumerated()), id: \.offset) { index, mark in
                        GroupButton(title: mark.title, current: model.currentGroup == index,
                                    focused: model.groupFocus == index) {
                            model.groupFocus = index
                        }
                        .id("group\(index)")
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 26)
            .onChange(of: model.currentGroup) {
                proxy.scrollTo("group\(model.currentGroup)", anchor: .center)
            }
        }
    }

    @ViewBuilder private func emojiButtons(offset: Int) -> some View {
        let groupStarts = Set(model.emojiGroups.map(\.start))
        ForEach(Array(model.emojis.enumerated()), id: \.offset) { index, emoji in
            if index > 0, groupStarts.isEmpty ? index == model.emojiRecentCount : groupStarts.contains(index) {
                separator.padding(.horizontal, 6)
            }
            BarButton(help: "", selected: model.groupFocus == nil && model.keyIndex == index + offset, padding: 3,
                      action: { model.insertEmoji(emoji) }) {
                Text(emoji).font(.system(size: 18))
            }
            .id(index)
        }
    }

    /// The first emoji at the colon (the selection, the word), the rest to the right.
    private var firstEmojiAnchor: some View {
        GeometryReader { Color.clear.preference(key: BarAnchorKey.self, value: $0.frame(in: .named("bar")).minX + 15) }
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.14)).frame(width: 0.5, height: 18)
    }

    private var back: some View {
        BarButton(help: tr("Назад", "Back"), selected: model.keyIndex == 0, action: { model.page = .main }) {
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

/// A group's name over the emoji: the current one on a light pill, blue with white text under the keyboard.
private struct GroupButton: View {
    let title: String
    let current: Bool
    let focused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: current ? .semibold : .regular))
                .foregroundStyle(focused ? AnyShapeStyle(.white) : current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(focused ? Color.accentColor
                                           : current || hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A button of the bar: the system's text colour, blue with white text under the mouse (or the keyboard)
/// like a menu.
private struct BarButton<Label: View>: View {
    let help: String
    var selected = false
    var padding: CGFloat = 9
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(hovering || selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.9)))
                .padding(.horizontal, padding)
                .frame(minWidth: 30, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering || selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
