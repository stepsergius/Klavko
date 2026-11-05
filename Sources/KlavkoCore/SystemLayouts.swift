import Carbon
import Foundation

/// Reads enabled keyboard layouts of the languages Klavko knows from macOS (Text Input Sources).
public enum SystemLayouts {
    /// Languages whose words Klavko can tell apart: each has a macOS dictionary and a plain layout
    /// (one character per key; Chinese, Japanese and Korean are typed through input methods instead).
    public static let supportedLanguages = ["uk", "en", "ru", "de", "fr", "es", "it", "pt", "pl", "tr", "el", "he", "ar"]

    /// Enabled keyboard layouts whose primary language is one of `supportedLanguages`.
    public static func enabledLayouts() -> [(source: TISInputSource, map: LayoutMap)] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID),
                  let table = characterTable(source),
                  let language = language(source, id: id, table: table),
                  supportedLanguages.contains(language) else { return nil }
            return (source, LayoutMap(id: id, language: language, table: table))
        }
    }

    /// Every enabled keyboard layout, of any language, as the macOS input menu lists them: for switching by hand.
    /// `name` is how macOS shows it ("ABC", "Ukrainian"); `language` is its two-letter primary language.
    public static func allLayouts() -> [(source: TISInputSource, id: String, name: String, language: String?)] {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
            let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
            return (source, id, name, language(source, id: id))
        }
    }

    public static func currentLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, kTISPropertyInputSourceID)
    }

    /// Two-letter language of the active layout, e.g. "uk".
    public static func currentLanguage() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        return language(source, id: id)
    }

    @discardableResult
    public static func select(_ source: TISInputSource) -> Bool {
        TISSelectInputSource(source) == noErr
    }

    // MARK: - Private

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Languages worked out so far, by layout ID (reading every key of a layout takes a moment).
    nonisolated(unsafe) private static var languages: [String: String?] = [:]
    private static let languagesLock = NSLock()

    /// The layout's language: the one macOS gives when it matches the letters, otherwise guessed (a layout
    /// installed by hand often has none). A language Klavko doesn't know stays as macOS gives it, for the flag.
    private static func language(_ source: TISInputSource, id: String, table: [Keystroke: String]? = nil) -> String? {
        if let known = languagesLock.withLock({ languages[id] }) { return known }
        let reported = primaryLanguage(source)
        var resolved = reported
        if reported == nil || supportedLanguages.contains(reported!), let table = table ?? characterTable(source) {
            let letters = table.filter { !$0.key.shift && !$0.key.capsLock }.map(\.value)
            let names = [id, stringProperty(source, kTISPropertyLocalizedName) ?? ""]
            resolved = LayoutLanguage.resolve(reported: reported, names: names, letters: letters,
                                              supported: supportedLanguages) ?? reported
        }
        languagesLock.withLock { languages[id] = resolved }
        return resolved
    }

    private static func primaryLanguage(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first.map { String($0.prefix(2)) }
    }

    private static func characterTable(_ source: TISInputSource) -> [Keystroke: String]? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        return data.withUnsafeBytes { raw -> [Keystroke: String] in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            var table: [Keystroke: String] = [:]
            for keyCode in UInt16(0)..<128 {
                for shift in [false, true] {
                    for capsLock in [false, true] {
                        // Carbon modifier bits shifted right by 8, as UCKeyTranslate expects.
                        let modifiers = UInt32((shift ? shiftKey : 0) | (capsLock ? alphaLock : 0)) >> 8
                        var deadKeyState: UInt32 = 0
                        var length = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers,
                                                    keyboardType, OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                                    &deadKeyState, chars.count, &length, &chars)
                        guard status == noErr, length > 0 else { continue }
                        let string = String(utf16CodeUnits: chars, count: length)
                        guard string.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
                        table[Keystroke(keyCode: keyCode, shift: shift, capsLock: capsLock)] = string
                    }
                }
            }
            return table
        }
    }
}
