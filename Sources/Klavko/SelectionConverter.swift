import AppKit
import Carbon
import KlavkoCore

/// Changes the selected text in the frontmost app: copy, transform, paste, select it again
/// (so the same hotkey can be pressed again), restore the clipboard.
enum SelectionConverter {
    private static let keyC: CGKeyCode = 8
    private static let keyV: CGKeyCode = 9
    private static let leftArrow: CGKeyCode = 123

    /// Until when Klavko is using the clipboard itself (copy selection → put back): the clipboard
    /// history doesn't record those changes.
    nonisolated(unsafe) static var borrowedUntil = Date.distantPast
    /// The clipboard's change count when Klavko last put the user's content back: not a copy either.
    nonisolated(unsafe) static var restoredChangeCount = -1
    /// When the user last pressed a key with ⌘ (set by the keyboard monitor; Klavko's own keys don't count).
    nonisolated(unsafe) static var userCommandKeyAt = Date.distantPast

    private static func borrow() {
        borrowedUntil = Date().addingTimeInterval(1.5)
    }

    private static let spellChecker = MacSpellChecker()

    /// Retypes the selection in the other layout ("ghbdsn" → "привіт") and switches to that layout.
    static func convert(layouts: [(source: TISInputSource, map: LayoutMap)], onConverted: @escaping () -> Void) {
        var target: TISInputSource?
        transform({ text in
            // On a tie (English and German type the same letters) the selection is in the current layout.
            let current = SystemLayouts.currentLayoutID()
            let maps = layouts.map(\.map).sorted { $0.id == current && $1.id != current }
            guard let from = LayoutConverter.sourceLayout(of: text, among: maps),
                  let best = LayoutChoice.best(for: text, from: from,
                                               among: LayoutChoice.alternatives(to: from, among: maps),
                                               spellChecker: spellChecker),
                  let to = layouts.first(where: { $0.map.id == best.id }) else { return nil }
            target = to.source
            Log.engine.notice("Converting selection \(from.language, privacy: .public)→\(to.map.language, privacy: .public), \(text.count) chars")
            return LayoutConverter.convert(text, from: from, to: to.map)
        }, onDone: {
            if let target { SystemLayouts.select(target) }
            onConverted()
        })
    }

    /// Replaces the selection with `change(selection)`; nil or the same text leaves it alone.
    static func transform(_ change: @escaping (String) -> String?, onDone: @escaping () -> Void) {
        borrow()
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let countBeforeCopy = pasteboard.changeCount

        TextInjector.pressKey(keyC, flags: .maskCommand)

        // Give the app time to put the selection on the clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount != countBeforeCopy,
                  let text = pasteboard.string(forType: .string), !text.isEmpty,
                  let changed = change(text), changed != text
            else {
                Log.engine.notice("Selection left alone: nothing selected or nothing to change")
                if pasteboard.changeCount != countBeforeCopy { restore(saved, to: pasteboard) }
                return
            }

            pasteboard.clearContents()
            pasteboard.setString(changed, forType: .string)
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let countAfterWrite = pasteboard.changeCount

            TextInjector.pressKey(keyV, flags: .maskCommand)
            onDone()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Select the pasted text again, so pressing the hotkey again goes on (or switches back).
                for _ in 0..<changed.count { TextInjector.pressKey(leftArrow, flags: .maskShift) }
            }
            // Restore the user's clipboard once the app has pasted, unless they copied something new.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pasteboard.changeCount == countAfterWrite { restore(saved, to: pasteboard) }
            }
        }
    }

    /// The selected text read through Accessibility, so the clipboard is never touched.
    struct Selection {
        let text: String
        let element: AXUIElement

        /// Puts `text` in place of the selection; `done(false)` when the app ignored it (then paste instead).
        func replace(with text: String, done: @escaping (Bool) -> Void) {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return done(false) }
            let before = Self.value(of: element)
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
            else { return done(false) }
            guard let before else { return done(true) }
            Self.waitForChange(of: element, from: before, checks: 10, done: done)
        }

        /// Some apps report success and change nothing; others (Telegram) change the text a moment later, and
        /// pasting at once would put it in twice: the field is looked at again for half a second before giving up.
        private static func waitForChange(of element: AXUIElement, from before: String, checks: Int, done: @escaping (Bool) -> Void) {
            if value(of: element) != before { return done(true) }
            guard checks > 0 else { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForChange(of: element, from: before, checks: checks - 1, done: done)
            }
        }

        private static func value(of element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
    }

    /// The selection of the focused element in the frontmost app, when that app exposes it (nil otherwise).
    static func accessibleSelection() -> Selection? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Selection(text: text, element: element)
    }

    /// Copies the selection and hands over its text (nil if nothing is selected); the clipboard is restored.
    static func copySelection(_ completion: @escaping (String?) -> Void) {
        borrow()
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let countBeforeCopy = pasteboard.changeCount
        let copied = Date()
        TextInjector.pressKey(keyC, flags: .maskCommand)
        // Apps answer ⌘C at different speeds: wait for the copy (up to half a second), not a fixed delay.
        func check(_ attempt: Int) {
            // The user pressed ⌘C (⌘X…) of their own meanwhile: Electron apps (Slack, VS Code) answer ours slowly,
            // and the clipboard is now the user's copy; putting the old content back would undo it.
            if userCommandKeyAt > copied {
                borrowedUntil = .distantPast
                completion(nil)
                return
            }
            guard pasteboard.changeCount != countBeforeCopy else {
                if attempt < 25 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { check(attempt + 1) }
                } else {
                    completion(nil)
                }
                return
            }
            let text = pasteboard.string(forType: .string)
            restore(saved, to: pasteboard)
            let countAfterRestore = pasteboard.changeCount
            // The clipboard is the user's again: a ⌘C of theirs right after (the bar shows on selecting) is a copy.
            borrowedUntil = .distantPast
            let restored = Date()
            // Some apps write the clipboard twice; put the user's content back again if that happens. Not when ⌘
            // was pressed since: that copy is the user's own ⌘C of the same selection (Telegram).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if userCommandKeyAt < restored, pasteboard.changeCount != countAfterRestore,
                   pasteboard.string(forType: .string) == text {
                    restore(saved, to: pasteboard)
                }
            }
            completion(text)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { check(0) }
    }

    /// Pastes `text` over the selection in the frontmost app; the clipboard is restored afterwards.
    static func paste(_ text: String) {
        borrow()
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard history apps skip these (nspasteboard.org): the paste is Klavko's, not the user's copy.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let countAfterWrite = pasteboard.changeCount
        TextInjector.pressKey(keyV, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if pasteboard.changeCount == countAfterWrite { restore(saved, to: pasteboard) }
        }
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        restoredChangeCount = pasteboard.changeCount
    }
}
