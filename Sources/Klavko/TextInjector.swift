import CoreGraphics
import Foundation

/// Types and deletes text by posting synthetic keyboard events.
///
/// Every injection ends with a sentinel event. Until it comes back through the event tap, keys the
/// user types are held back (see `KeyboardMonitor`), so they can't land in the middle of our
/// "delete N characters, type this" sequence and throw the count off.
enum TextInjector {
    /// Tags our events so the monitor lets them through untouched ("KLVK").
    static let marker: Int64 = 0x4B4C_564B
    /// Tags the event that ends an injection ("KLVS"); the monitor swallows it.
    static let sentinelMarker: Int64 = 0x4B4C_5653

    /// Injections whose sentinel hasn't come back yet.
    private(set) static var pendingSentinels = 0
    static var isInjecting: Bool { pendingSentinels > 0 }

    private static let source = CGEventSource(stateID: .privateState)
    private static let backspaceKeyCode: CGKeyCode = 51
    private static let returnKeyCode: CGKeyCode = 36
    private static let maxChunk = 16

    static func replace(deleting count: Int, with text: String) {
        for _ in 0..<count { postKey(backspaceKeyCode, flags: []) }
        typeChunks(text)
        postSentinel()
    }

    static func type(_ text: String) {
        typeChunks(text)
        postSentinel()
    }

    /// Types `text` with each line break as a key: ⇧Return, which starts a new line in chats too (where Return
    /// sends the message). Editors in web apps (Claude, Notion…) take in typed text a moment later; a key that
    /// comes sooner splits the line as it was, without that text: so each line break waits a little.
    static func typeLines(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return type(text) }
        pendingSentinels += 1  // the user's keys wait until the last line is in
        func step(_ i: Int) {
            if i > 0 { postKey(returnKeyCode, flags: .maskShift) }
            typeChunks(lines[i])
            guard i + 1 < lines.count else {
                pendingSentinels = max(0, pendingSentinels - 1)
                postSentinel()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + lineBreakPause) { step(i + 1) }
        }
        step(0)
    }

    private static let lineBreakPause: TimeInterval = 0.12

    /// Presses a key with exactly these modifiers (e.g. ⌘C), ignoring keys the user still holds.
    static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        postKey(keyCode, flags: flags)
        postSentinel()
    }

    static func sentinelArrived() {
        pendingSentinels = max(0, pendingSentinels - 1)
    }

    /// Safety valve if a sentinel got lost.
    static func forgetPendingSentinels() {
        pendingSentinels = 0
    }

    // MARK: - Private

    private static func typeChunks(_ text: String) {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: maxChunk) {
            let chunk = Array(units[start..<min(start + maxChunk, units.count)])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress)
                }
                post(event, marker: marker)
            }
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            post(event, marker: marker)
        }
    }

    private static func postSentinel() {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return }
        event.flags = []
        pendingSentinels += 1
        post(event, marker: sentinelMarker)
    }

    private static func post(_ event: CGEvent, marker: Int64) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
}
