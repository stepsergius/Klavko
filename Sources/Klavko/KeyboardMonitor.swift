import CoreGraphics
import Foundation
import KlavkoCore

/// Global keyboard/mouse event tap. Needs the Accessibility permission.
final class KeyboardMonitor {
    /// Return false to swallow the event.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    /// Keys made to act as other keys (Settings → Hotkeys → Key remapping).
    var remaps: [KeyRemap] = []
    /// While a key is recorded in Settings: it must arrive as pressed.
    var remapsPaused = false
    /// Remapped keys still held: what their key-up becomes.
    private var remappedDown: [Int64: Int64] = [:]
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }

        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.process(type, event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        Log.monitor.notice("Event tap started")
        return true
    }

    /// Watchdog: macOS may disable the tap and only tell us on the next event.
    func ensureEnabled() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.monitor.notice("Event tap was disabled; re-enabled by watchdog")
    }

    // MARK: - Keys held during an injection

    private var heldKeys: [CGEvent] = []

    private func hold(_ event: CGEvent) {
        if heldKeys.isEmpty {
            // If a sentinel never comes back, don't keep the user's keys forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !heldKeys.isEmpty else { return }
                Log.monitor.notice("Injection sentinel lost; releasing held keys")
                TextInjector.forgetPendingSentinels()
                releaseHeldKeys()
            }
        }
        heldKeys.append(event)
    }

    /// Re-posts the held keys in order; they go through the tap again and are handled as usual.
    private func releaseHeldKeys() {
        guard !heldKeys.isEmpty else { return }
        let keys = heldKeys
        heldKeys = []
        Log.monitor.notice("Released \(keys.count) key(s) typed during a replacement")
        for key in keys { key.post(tap: .cghidEventTap) }
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback is too slow; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.monitor.notice("Event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        // The end of one of our injections: keys held meanwhile can go now.
        if marker == TextInjector.sentinelMarker {
            TextInjector.sentinelArrived()
            if !TextInjector.isInjecting { releaseHeldKeys() }
            return nil
        }
        // Our own synthetic keystrokes.
        if marker == TextInjector.marker {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.flags.contains(.maskCommand) { SelectionConverter.userCommandKeyAt = Date() }
        // A key typed while our text is still on its way: hold it, so it lands after our text.
        if type == .keyDown && TextInjector.isInjecting, let copy = event.copy() {
            hold(copy)
            return nil
        }
        // After holding: a held key comes back through here and is remapped then, once.
        if type == .keyDown || type == .keyUp { remap(type, event) }
        // Key-ups are watched for remapping only.
        if type == .keyUp { return Unmanaged.passUnretained(event) }

        let start = DispatchTime.now().uptimeNanoseconds
        let pass = handler(type, event)
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if elapsedMs > 50 {
            Log.monitor.notice("Slow event handling: \(elapsedMs) ms")
        }
        return pass ? Unmanaged.passUnretained(event) : nil
    }

    // MARK: - Remapping

    private static let flags: [(ModifierKey, CGEventFlags)] = [
        (.control, .maskControl), (.option, .maskAlternate), (.shift, .maskShift), (.command, .maskCommand),
    ]

    /// Turns the key into the one it's remapped to, in place: the app (and the typing engine) get the new key,
    /// and a held key repeats as the new one.
    private func remap(_ type: CGEventType, _ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if let target = remappedDown.removeValue(forKey: keyCode) {
                event.setIntegerValueField(.keyboardEventKeycode, value: target)
            }
            return
        }
        guard !remaps.isEmpty, !remapsPaused else { return }
        let held = Set(Self.flags.filter { event.flags.contains($0.1) }.map(\.0))
        guard let output = KeyRemapping.output(keyCode: UInt16(keyCode), held: held, rules: remaps) else { return }
        var flags = event.flags
        for (modifier, flag) in Self.flags {
            if output.modifiers.contains(modifier) { flags.insert(flag) } else { flags.remove(flag) }
        }
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(output.keyCode))
        event.flags = flags
        remappedDown[keyCode] = Int64(output.keyCode)
    }
}
