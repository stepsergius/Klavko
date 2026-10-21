import AppKit
import KlavkoCore

/// Records a new shortcut in the settings window:
/// a key with modifiers (⌃⇧Space), modifiers alone (⌥⌘) or a double tap (⇧⇧, двічі ⌥⌘).
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: HotkeyAction?
    /// Record which of the two keys of each modifier was pressed ("right ⌘"), not just the modifier.
    private var recordsSides = false

    private var monitor: Any?
    private var detector = ModifierTapDetector()
    private var completion: ((Shortcut) -> Void)?
    /// After a single modifier tap, wait briefly in case it becomes a double tap.
    private var pendingSingle: DispatchWorkItem?

    private let escapeKeyCode: UInt16 = 53

    func start(_ action: HotkeyAction, recordsSides: Bool = false, completion: @escaping (Shortcut) -> Void) {
        stop()
        recording = action
        self.recordsSides = recordsSides
        self.completion = completion
        detector = ModifierTapDetector()
        // Local monitors run on the main thread; every key is swallowed while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingSingle?.cancel()
        pendingSingle = nil
        recording = nil
        completion = nil
    }

    private func handle(_ event: NSEvent) {
        let modifiers = Self.modifiers(event.modifierFlags)
        switch event.type {
        case .keyDown:
            detector.interrupt()
            pendingSingle?.cancel()
            if event.keyCode == escapeKeyCode && modifiers.isEmpty {
                stop()
            } else if modifiers.isEmpty {
                // A plain letter would fire on every keystroke.
                NSSound.beep()
            } else {
                finish(Shortcut(keyCode: event.keyCode, modifiers: modifiers, sides: sides(event)))
            }
        case .flagsChanged:
            guard ModifierKey(keyCode: event.keyCode) != nil else { return }
            var held = modifiers
            if event.modifierFlags.contains(.function) { held.insert(.function) }
            let physical = ModifierSide.held(in: UInt64(event.modifierFlags.rawValue))
            for tap in detector.modifiersChanged(held, sides: physical, at: event.timestamp) {
                let sides = recordsSides ? Shortcut.sides(tap.sides) : [:]
                switch tap {
                case .single(let chord, _):
                    pendingSingle?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated { self?.finish(Shortcut(modifiers: chord, double: false, sides: sides)) }
                    }
                    pendingSingle = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + detector.maxInterval, execute: work)
                case .double(let chord, _):
                    pendingSingle?.cancel()
                    finish(Shortcut(modifiers: chord, double: true, sides: sides))
                }
            }
        default:
            break
        }
    }

    private func sides(_ event: NSEvent) -> [ModifierKey: ModifierSide] {
        recordsSides ? Shortcut.sides(ModifierSide.held(in: UInt64(event.modifierFlags.rawValue))) : [:]
    }

    private func finish(_ shortcut: Shortcut) {
        let completion = completion
        stop()
        completion?(shortcut)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<ModifierKey> {
        var result: Set<ModifierKey> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}
