import AppKit
import KlavkoCore

/// Records a new shortcut in the settings window:
/// a key with modifiers (⌃⇧Space), modifiers alone (⌥⌘) or a double tap (⇧⇧, двічі ⌥⌘).
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: HotkeyAction?
    /// The keyboard layout (input source ID) whose switching hotkey is being recorded.
    @Published private(set) var recordingLayout: String?
    /// A shortcut of any kind is being recorded: Klavko's hotkeys must not fire meanwhile.
    var isRecordingShortcut: Bool { recording != nil || recordingLayout != nil }
    /// Which key of a remapping rule is being recorded (`recordKey`).
    @Published private(set) var recordingKey: String?
    /// Told when key recording starts and stops: remapping is paused meanwhile, so the key arrives as pressed.
    var onRecordingKey: (Bool) -> Void = { _ in }
    /// Record which of the two keys of each modifier was pressed ("right ⌘"), not just the modifier.
    private var recordsSides = false
    /// Sides for modifier taps even when `recordsSides` is off (a layout's "right ⌘").
    private var recordsTapSides = false

    private var monitor: Any?
    private var detector = ModifierTapDetector()
    private var completion: ((Shortcut) -> Void)?
    /// After a single modifier tap, wait briefly in case it becomes a double tap.
    private var pendingSingle: DispatchWorkItem?

    private let escapeKeyCode: UInt16 = 53

    func start(_ action: HotkeyAction, recordsSides: Bool = false, completion: @escaping (Shortcut) -> Void) {
        stop()
        recording = action
        begin(recordsSides: recordsSides, completion: completion)
    }

    /// A layout's hotkey: modifiers pressed alone keep their side, so left ⌘ and right ⌘ can switch into two layouts.
    func startLayout(_ id: String, recordsSides: Bool = false, completion: @escaping (Shortcut) -> Void) {
        stop()
        recordingLayout = id
        begin(recordsSides: recordsSides, tapSides: true, completion: completion)
    }

    private func begin(recordsSides: Bool, tapSides: Bool = false, completion: @escaping (Shortcut) -> Void) {
        self.recordsSides = recordsSides
        recordsTapSides = tapSides
        self.completion = completion
        detector = ModifierTapDetector()
        // Local monitors run on the main thread; every key is swallowed while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    /// Records any key, with the modifiers held or without (Esc too): a rule's key for remapping.
    func recordKey(_ slot: String, completion: @escaping (KeyCombo) -> Void) {
        stop()
        recordingKey = slot
        onRecordingKey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                let combo = KeyCombo(keyCode: event.keyCode, modifiers: Self.modifiers(event.modifierFlags))
                self?.stop()
                completion(combo)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recordingKey != nil {
            recordingKey = nil
            onRecordingKey(false)
        }
        pendingSingle?.cancel()
        pendingSingle = nil
        recording = nil
        recordingLayout = nil
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
                let sides = recordsSides || recordsTapSides ? Shortcut.sides(tap.sides) : [:]
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
