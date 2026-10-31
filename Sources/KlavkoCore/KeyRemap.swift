import Foundation

/// A key as the keyboard sends it, with the modifiers held (⌃⌥⇧⌘; Fn is left out: macOS sets it on its own
/// for arrows and F-keys).
public struct KeyCombo: Codable, Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: [ModifierKey]

    public init(keyCode: UInt16, modifiers: Set<ModifierKey> = []) {
        self.keyCode = keyCode
        self.modifiers = ModifierKey.sorted(modifiers.subtracting([.function]))
    }

    /// Pieces for keycap-style display: ["⌥", "Ґ"], ["⌘", "⇧", "4"].
    public func parts(layout: LayoutMap?) -> [String] {
        modifiers.map(\.symbol) + [KeyNames.name(for: keyCode, layout: layout)]
    }
}

/// One key or combination made to act as another, everywhere (like BetterTouchTool's key remapping).
public struct KeyRemap: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let from: KeyCombo
    public let to: KeyCombo

    public init(id: UUID = UUID(), from: KeyCombo, to: KeyCombo) {
        self.id = id
        self.from = from
        self.to = to
    }

    /// The same two keys the other way round («ґ» → «ʼ» gives «ʼ» → «ґ»).
    public var reversed: KeyRemap { KeyRemap(from: to, to: from) }
}

public enum KeyRemapping {
    /// What a key pressed with `held` modifiers becomes, or nil when no rule covers it.
    /// A rule with modifiers covers exactly those; a plain key's rule also covers the key with any modifiers, which
    /// are kept (a remapped key still types its capital with ⇧), unless a rule names that combination itself.
    public static func output(keyCode: UInt16, held: Set<ModifierKey>, rules: [KeyRemap]) -> KeyCombo? {
        let pressed = KeyCombo(keyCode: keyCode, modifiers: held)
        if let exact = rules.first(where: { $0.from == pressed }) { return exact.to }
        guard !pressed.modifiers.isEmpty,
              let plain = rules.first(where: { $0.from == KeyCombo(keyCode: keyCode) }) else { return nil }
        return KeyCombo(keyCode: plain.to.keyCode, modifiers: Set(pressed.modifiers).union(plain.to.modifiers))
    }

    /// Adds `rule`, replacing a rule for the same key or combination.
    public static func adding(_ rule: KeyRemap, to rules: [KeyRemap]) -> [KeyRemap] {
        rules.filter { $0.from != rule.from } + [rule]
    }
}
