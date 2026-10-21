import Foundation

/// Modifier keys, in the order macOS displays them (⌃⌥⇧⌘), then Fn (🌐).
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case control, option, shift, command, function

    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    /// Left and right physical keys.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 59, 62: self = .control
        case 58, 61: self = .option
        case 56, 60: self = .shift
        case 55, 54: self = .command
        case 63: self = .function
        default: return nil
        }
    }

    /// Canonical order, so equal sets compare and display the same.
    public static func sorted(_ set: Set<ModifierKey>) -> [ModifierKey] {
        allCases.filter(set.contains)
    }
}

/// Which of the two physical keys of a modifier (Fn has one).
public enum ModifierSide: String, Codable, CaseIterable, Sendable {
    case left, right

    /// The modifiers held and on which side, from an event's flags (`CGEventFlags.rawValue` or
    /// `NSEvent.ModifierFlags.rawValue`: both carry the device-dependent bits for each physical key).
    public static func held(in flags: UInt64) -> [ModifierKey: Set<ModifierSide>] {
        let bits: [(ModifierKey, ModifierSide, UInt64)] = [
            (.control, .left, 0x0001), (.control, .right, 0x2000),
            (.shift, .left, 0x0002), (.shift, .right, 0x0004),
            (.command, .left, 0x0008), (.command, .right, 0x0010),
            (.option, .left, 0x0020), (.option, .right, 0x0040),
        ]
        var result: [ModifierKey: Set<ModifierSide>] = [:]
        for (key, side, bit) in bits where flags & bit != 0 { result[key, default: []].insert(side) }
        return result
    }
}

/// A user-assignable shortcut.
/// `sides`: modifiers that only count on one side ("right ⌘"); the others work with either key.
/// Saved shortcuts from before sides existed have none (the key is missing in their JSON).
public enum Shortcut: Codable, Hashable, Sendable {
    /// Modifiers pressed together and released with no other key, e.g. ⌥⌘ or a double ⇧⇧.
    case modifierTap(modifiers: [ModifierKey], double: Bool, sides: [ModifierKey: ModifierSide]? = nil)
    /// A regular key with modifiers, e.g. ⌃⇧Space.
    case combo(keyCode: UInt16, modifiers: [ModifierKey], sides: [ModifierKey: ModifierSide]? = nil)

    public init(keyCode: UInt16, modifiers: Set<ModifierKey>, sides: [ModifierKey: ModifierSide] = [:]) {
        self = .combo(keyCode: keyCode, modifiers: ModifierKey.sorted(modifiers), sides: Self.normalized(sides, modifiers))
    }

    public init(modifiers: Set<ModifierKey>, double: Bool, sides: [ModifierKey: ModifierSide] = [:]) {
        self = .modifierTap(modifiers: ModifierKey.sorted(modifiers), double: double, sides: Self.normalized(sides, modifiers))
    }

    /// Sides of the shortcut's own modifiers only; none is stored as nil, so it equals an old shortcut.
    private static func normalized(_ sides: [ModifierKey: ModifierSide], _ modifiers: Set<ModifierKey>) -> [ModifierKey: ModifierSide]? {
        let kept = sides.filter { modifiers.contains($0.key) && $0.key != .function }
        return kept.isEmpty ? nil : kept
    }

    /// The sides of a recorded chord: each modifier held on one side only, when sides are told apart.
    public static func sides(_ held: [ModifierKey: Set<ModifierSide>]) -> [ModifierKey: ModifierSide] {
        held.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    public var modifiers: [ModifierKey] {
        switch self {
        case .modifierTap(let modifiers, _, _), .combo(_, let modifiers, _): modifiers
        }
    }

    public var sides: [ModifierKey: ModifierSide] {
        switch self {
        case .modifierTap(_, _, let sides), .combo(_, _, let sides): sides ?? [:]
        }
    }

    /// `held`: the physical keys held (from `ModifierSide.held(in:)`); every side the shortcut names must be among them.
    public func matches(keyCode: UInt16, modifiers: Set<ModifierKey>, held: [ModifierKey: Set<ModifierSide>] = [:]) -> Bool {
        guard case .combo(keyCode, let own, _) = self, own == ModifierKey.sorted(modifiers) else { return false }
        return sidesMatch(held)
    }

    public func matches(_ tap: ModifierTap) -> Bool {
        guard case .modifierTap(let own, let double, _) = self, own == ModifierKey.sorted(tap.modifiers),
              double == tap.isDouble else { return false }
        return sidesMatch(tap.sides)
    }

    private func sidesMatch(_ held: [ModifierKey: Set<ModifierSide>]) -> Bool {
        sides.allSatisfy { held[$0.key]?.contains($0.value) == true }
    }

    private func symbol(_ modifier: ModifierKey) -> String {
        switch sides[modifier] {
        case .left: tr("лівий ", "left ") + modifier.symbol
        case .right: tr("правий ", "right ") + modifier.symbol
        case nil: modifier.symbol
        }
    }

    /// Pieces for keycap-style display: ["двічі", "⌥", "⌘"], ["⌃", "⇧", "Space"], ["правий ⌘"].
    public func parts(layout: LayoutMap?) -> [String] {
        switch self {
        case .modifierTap(let modifiers, let double, _):
            return (double ? [tr("двічі", "twice")] : []) + modifiers.map(symbol)
        case .combo(let keyCode, let modifiers, _):
            return modifiers.map(symbol) + [KeyNames.name(for: keyCode, layout: layout)]
        }
    }

    /// "⇧⇧", "двічі ⌥⌘", "⌥⌘", "⌃⇧Space", "правий ⌘".
    public func displayName(layout: LayoutMap?) -> String {
        switch self {
        case .modifierTap(let modifiers, true, _) where modifiers.count == 1 && sides.isEmpty:
            return modifiers[0].symbol + modifiers[0].symbol
        case .modifierTap(let modifiers, true, _):
            return tr("двічі ", "twice ") + modifiers.map(symbol).joined(separator: sides.isEmpty ? "" : " ")
        default:
            return parts(layout: layout).joined(separator: sides.isEmpty ? "" : " ")
        }
    }
}

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case convertWord, convertText, undo, changeCase, translate, screenText, clipboard, voice

    public var title: String {
        switch self {
        case .convertWord: tr("Змінити розкладку слова", "Switch the layout of the word")
        case .convertText: tr("Змінити розкладку виділеного або набраного", "Switch the layout of the selection or typed text")
        case .undo: tr("Скасувати або повернути виправлення", "Undo or redo a fix")
        case .changeCase: tr("Змінити регістр (слово або виділене)", "Change case (word or selection)")
        case .translate: tr("Перекласти виділене", "Translate Selection")
        case .screenText: tr("Текст з екрана (розпізнати й перекласти)", "Text from the screen (read and translate)")
        case .clipboard: tr("Історія буфера обміну", "Clipboard history")
        case .voice: tr("Голосовий ввід (почати / вставити)", "Voice input (start / insert)")
        }
    }

    public var defaultShortcut: Shortcut? {
        switch self {
        case .convertWord: Shortcut(modifiers: [.shift], double: true)
        case .convertText: Shortcut(modifiers: [.option], double: true)
        case .undo: nil
        case .changeCase: nil
        case .translate: Shortcut(modifiers: [.command], double: true)
        case .screenText: Shortcut(keyCode: 12, modifiers: [.control])  // ⌃Q
        case .clipboard: Shortcut(keyCode: 9, modifiers: [.option, .command])  // ⌥⌘V
        case .voice: Shortcut(modifiers: [.function], double: false)
        }
    }
}

/// When to check a finished word.
public enum SwitchTrigger: String, Codable, CaseIterable, Sendable {
    case space, tab, enter, punctuation

    public var title: String {
        switch self {
        case .space: "Space"
        case .tab: "Tab"
        case .enter: "Enter"
        case .punctuation: ", . ! ?"
        }
    }
}

public enum KeyNames {
    private static let special: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    public static func name(for keyCode: UInt16, layout: LayoutMap?) -> String {
        special[keyCode]
            ?? layout?.character(for: Keystroke(keyCode: keyCode))?.uppercased()
            ?? "#\(keyCode)"
    }
}

public enum ModifierTap: Equatable, Sendable {
    /// `sides`: the physical keys pressed for each modifier, when known.
    case single(Set<ModifierKey>, sides: [ModifierKey: Set<ModifierSide>] = [:])
    case double(Set<ModifierKey>, sides: [ModifierKey: Set<ModifierSide>] = [:])

    public var modifiers: Set<ModifierKey> {
        switch self {
        case .single(let modifiers, _), .double(let modifiers, _): modifiers
        }
    }

    public var sides: [ModifierKey: Set<ModifierSide>] {
        switch self {
        case .single(_, let sides), .double(_, let sides): sides
        }
    }

    public var isDouble: Bool {
        if case .double = self { return true }
        return false
    }
}

/// Recognizes modifier-only gestures: a chord pressed and released alone (⌥⌘),
/// and the same chord tapped twice quickly (⇧⇧).
public struct ModifierTapDetector {
    public var maxChordDuration: TimeInterval = 0.6
    public var maxInterval: TimeInterval = 0.5

    private var chord: Set<ModifierKey> = []
    private var chordSides: [ModifierKey: Set<ModifierSide>] = [:]
    private var startedAt: TimeInterval?
    private var interrupted = false
    private var lastTap: (chord: Set<ModifierKey>, sides: [ModifierKey: Set<ModifierSide>], at: TimeInterval)?

    public init() {}

    /// Feed the set of held modifiers after every modifier change, with the physical keys held if known.
    /// Returns [.single] when a chord is released, plus .double when it was the second quick tap
    /// (of the same keys: a left ⌘ and then a right one are two different taps for a "right ⌘" shortcut).
    public mutating func modifiersChanged(_ active: Set<ModifierKey>, sides: [ModifierKey: Set<ModifierSide>] = [:],
                                          at time: TimeInterval) -> [ModifierTap] {
        if !active.isEmpty {
            if startedAt == nil {
                startedAt = time
                chord = active
                chordSides = sides
                interrupted = false
            } else {
                chord.formUnion(active)
                chordSides.merge(sides) { $0.union($1) }
            }
            return []
        }

        guard let start = startedAt else { return [] }
        startedAt = nil
        guard !interrupted, time - start < maxChordDuration else {
            lastTap = nil
            return []
        }
        var taps: [ModifierTap] = [.single(chord, sides: chordSides)]
        if let last = lastTap, last.chord == chord, time - last.at < maxInterval {
            // Only the sides pressed both times count.
            let both = Dictionary(uniqueKeysWithValues: chord.compactMap { key in
                let sides = (chordSides[key] ?? []).intersection(last.sides[key] ?? [])
                return sides.isEmpty ? nil : (key, sides)
            })
            taps.append(.double(chord, sides: both))
            lastTap = nil
        } else {
            lastTap = (chord, chordSides, time)
        }
        return taps
    }

    /// A regular key, mouse click or Caps Lock cancels the gesture in progress.
    public mutating func interrupt() {
        interrupted = true
        lastTap = nil
    }
}
