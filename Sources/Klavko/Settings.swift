import Foundation
import KlavkoCore
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private enum Key {
        static let enabled = "enabled"
        static let switchWhileTyping = "switchWhileTyping"
        static let triggers = "triggers"
        static let backspaceUndo = "backspaceUndo"
        static let showFlag = "showFlag"
        static let playSound = "playSound"
        static let soundName = "soundName"
        static let excludedApps = "excludedApps"
        static let shortcuts = "shortcuts.v2"
        static let modifierSides = "modifierSides"
        static let loginItemConfigured = "loginItemConfigured"
        static let lastRunVersion = "lastRunVersion"
        static let loginItemPath = "loginItemPath"
        static let convertAbbreviations = "convertAbbreviations"
        static let manualLanguages = "manualLanguages"
        static let exceptions = "exceptions"
        static let correctSpelling = "correctTypos"
        static let spaceAfterPunctuation = "spaceAfterPunctuation"
        static let autoCapitalize = "autoCapitalize"
        /// Before 0.14 one switch for all typography; now only read to carry its value over.
        static let typography = "typography"
        static let dashes = "dashes"
        static let smartQuotes = "smartQuotes"
        static let symbols = "symbols"
        static let listContinuation = "listContinuation"
        static let replacements = "replacements"
        static let voiceVocabulary = "voiceVocabulary"
        static let interfaceLanguage = "interfaceLanguage"
        static let checkForUpdates = "checkForUpdates"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let offerVoiceCorrections = "offerVoiceCorrections"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardKeepDays = "clipboardKeepDays"
        static let clipboardIgnoredApps = "clipboardIgnoredApps"
        static let voiceLanguage = "voiceLanguage"
        static let voiceLanguages = "voiceLanguages"
        static let translationOwn = "translationOwn"
        static let translationOther = "translationOther"
        static let voiceEngine = "voiceEngine"
        static let googleSmart = "googleSmart"
        static let googleModel = "googleModel"
        static let playSpellingSound = "playSpellingSound"
        static let spellingSoundName = "spellingSoundName"
        static let playCopySound = "playCopySound"
        static let copySoundName = "copySoundName"
        static let revertCounts = "revertCounts"
        static let declinedExceptions = "declinedExceptions"
    }

    /// Short, soft macOS system sounds that suit a quick fix.
    /// macOS system sounds (/System/Library/Sounds).
    static let sounds = ["Pop", "Tink", "Purr", "Bottle", "Morse", "Frog", "Glass", "Ping", "Blow", "Funk", "Hero",
                         "Submarine", "Basso", "Sosumi"]

    private let defaults = UserDefaults.standard

    /// Called after any change so the engine and the menu bar icon pick it up.
    var onChange: (() -> Void)?

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled); onChange?() }
    }

    @Published var switchWhileTyping: Bool {
        didSet { defaults.set(switchWhileTyping, forKey: Key.switchWhileTyping); onChange?() }
    }

    @Published private(set) var triggers: Set<SwitchTrigger> {
        didSet { defaults.set(triggers.map(\.rawValue).sorted(), forKey: Key.triggers); onChange?() }
    }

    @Published var backspaceUndo: Bool {
        didSet { defaults.set(backspaceUndo, forKey: Key.backspaceUndo); onChange?() }
    }

    @Published var convertAbbreviations: Bool {
        didSet { defaults.set(convertAbbreviations, forKey: Key.convertAbbreviations); onChange?() }
    }

    /// Languages Klavko never switches into by itself, only by a hotkey ("uk", "ru"…; empty by default).
    @Published private(set) var manualLanguages: [String] {
        didSet { defaults.set(manualLanguages, forKey: Key.manualLanguages); onChange?() }
    }

    func toggleManualLanguage(_ code: String) {
        if manualLanguages.contains(code) {
            manualLanguages.removeAll { $0 == code }
        } else {
            manualLanguages.append(code)
        }
    }

    @Published var correctSpelling: Bool {
        didSet { defaults.set(correctSpelling, forKey: Key.correctSpelling); onChange?() }
    }

    @Published var spaceAfterPunctuation: Bool {
        didSet { defaults.set(spaceAfterPunctuation, forKey: Key.spaceAfterPunctuation); onChange?() }
    }

    @Published var autoCapitalize: Bool {
        didSet { defaults.set(autoCapitalize, forKey: Key.autoCapitalize); onChange?() }
    }

    /// "так - ні" → "так — ні".
    @Published var dashes: Bool {
        didSet { defaults.set(dashes, forKey: Key.dashes); onChange?() }
    }

    /// A straight " → «» / “”.
    @Published var smartQuotes: Bool {
        didSet { defaults.set(smartQuotes, forKey: Key.smartQuotes); onChange?() }
    }

    /// "..." → "…", (c) (r) (tm) → © ® ™.
    @Published var symbols: Bool {
        didSet { defaults.set(symbols, forKey: Key.symbols); onChange?() }
    }

    @Published var listContinuation: Bool {
        didSet { defaults.set(listContinuation, forKey: Key.listContinuation); onChange?() }
    }

    /// Look for new versions on GitHub now and then.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }

    /// A version the user chose to skip: not offered again by automatic checks.
    var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Key.skippedUpdateVersion) }
        set { defaults.set(newValue, forKey: Key.skippedUpdateVersion) }
    }

    /// The language of Klavko's windows and menus.
    @Published var interfaceLanguage: AppLanguage {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: Key.interfaceLanguage)
            AppLanguage.current = interfaceLanguage
            onChange?()
        }
    }

    /// Languages the user speaks, for voice input on this Mac ("uk", "en", "ru"…; never empty).
    /// Russian is inserted only if it is here. Google AI recognizes any language anyway.
    /// Translation by default: text in `translationOwn` goes into `translationOther`, any other text into
    /// `translationOwn`.
    @Published var translationOwn: String {
        didSet {
            defaults.set(translationOwn, forKey: Key.translationOwn)
            if translationOther == translationOwn { translationOther = translationOwn == "en" ? "uk" : "en" }
        }
    }

    @Published var translationOther: String {
        didSet {
            defaults.set(translationOther, forKey: Key.translationOther)
            if translationOther == translationOwn { translationOwn = translationOther == "en" ? "uk" : "en" }
        }
    }

    @Published var voiceLanguages: [String] {
        didSet {
            if voiceLanguages.isEmpty { voiceLanguages = ["uk"] }
            defaults.set(voiceLanguages, forKey: Key.voiceLanguages)
        }
    }

    /// Languages voice input can be set to: those of the keyboard layouts.
    static let speechLanguages = ["uk", "en", "ru", "de", "fr", "es", "it", "pt", "pl", "tr", "el", "he", "ar"]

    func toggleVoiceLanguage(_ code: String) {
        if voiceLanguages.contains(code) {
            voiceLanguages.removeAll { $0 == code }
        } else {
            voiceLanguages.append(code)
        }
    }

    /// Who recognizes speech: "local" (on this Mac) or "google" (Google AI, with the user's key).
    @Published var voiceEngine: String {
        didSet { defaults.set(voiceEngine, forKey: Key.voiceEngine) }
    }

    /// Google AI drops fillers and self-corrections instead of writing word for word.
    @Published var googleSmart: Bool {
        didSet { defaults.set(googleSmart, forKey: Key.googleSmart) }
    }

    /// The Google AI speech model the key can reach, found when the key was checked.
    @Published var googleModel: String? {
        didSet { defaults.set(googleModel, forKey: Key.googleModel) }
    }

    /// Dictated words the user taught Klavko to spell their way (heard → written), in the order added.
    @Published private(set) var voiceVocabulary: [Replacement] {
        didSet { defaults.set(try? JSONEncoder().encode(voiceVocabulary), forKey: Key.voiceVocabulary) }
    }

    /// After a dictated word is fixed by hand, offer to remember the spelling.
    @Published var offerVoiceCorrections: Bool {
        didSet { defaults.set(offerVoiceCorrections, forKey: Key.offerVoiceCorrections) }
    }

    /// What voice input applies to its text: the vocabulary, then the word replacements ("зсу" → "ЗСУ").
    var voiceRules: [Replacement] {
        voiceVocabulary + replacements.filter { rule in
            !voiceVocabulary.contains { $0.from.lowercased() == rule.from.lowercased() }
        }
    }

    /// Keep a clipboard history.
    @Published var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) }
    }

    /// Days to keep clipboard items (0: forever).
    @Published var clipboardKeepDays: Int {
        didSet { defaults.set(clipboardKeepDays, forKey: Key.clipboardKeepDays) }
    }

    /// Apps whose copies the clipboard history never records (password managers).
    @Published private(set) var clipboardIgnoredApps: [String] {
        didSet { defaults.set(clipboardIgnoredApps, forKey: Key.clipboardIgnoredApps) }
    }

    func toggleClipboardIgnored(_ bundleID: String) {
        if clipboardIgnoredApps.contains(bundleID) {
            clipboardIgnoredApps.removeAll { $0 == bundleID }
        } else {
            clipboardIgnoredApps.append(bundleID)
        }
    }

    /// The user's own replacements, in the order added.
    @Published private(set) var replacements: [Replacement] {
        didSet {
            defaults.set(try? JSONEncoder().encode(replacements), forKey: Key.replacements)
            onChange?()
        }
    }

    /// Words Klavko never converts, lowercased, sorted.
    @Published private(set) var exceptions: [String] {
        didSet { defaults.set(exceptions, forKey: Key.exceptions); onChange?() }
    }

    @Published var showFlag: Bool {
        didSet { defaults.set(showFlag, forKey: Key.showFlag); onChange?() }
    }

    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.playSound); onChange?() }
    }

    @Published var soundName: String {
        didSet { defaults.set(soundName, forKey: Key.soundName); onChange?() }
    }

    @Published var playSpellingSound: Bool {
        didSet { defaults.set(playSpellingSound, forKey: Key.playSpellingSound); onChange?() }
    }

    /// A sound when something is copied (clipboard history).
    @Published var playCopySound: Bool {
        didSet { defaults.set(playCopySound, forKey: Key.playCopySound) }
    }

    @Published var copySoundName: String {
        didSet { defaults.set(copySoundName, forKey: Key.copySoundName) }
    }

    @Published var spellingSoundName: String {
        didSet { defaults.set(spellingSoundName, forKey: Key.spellingSoundName); onChange?() }
    }

    @Published private(set) var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: Key.excludedApps); onChange?() }
    }

    @Published private(set) var shortcuts: [HotkeyAction: Shortcut] {
        didSet { saveShortcuts(); onChange?() }
    }

    /// New shortcuts remember the side of each modifier ("right ⌘"). Off by default.
    @Published var modifierSides: Bool {
        didSet { defaults.set(modifierSides, forKey: Key.modifierSides) }
    }

    /// Lives in macOS (System Settings → General → Login Items), not in UserDefaults.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.engine.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Klavko had settings saved before this launch: not a first install.
    let usedBefore: Bool

    /// The version Klavko last ran as (remembered since 0.14), to tell an update from a first launch.
    var lastRunVersion: String? {
        get { defaults.string(forKey: Key.lastRunVersion) }
        set { defaults.set(newValue, forKey: Key.lastRunVersion) }
    }

    init() {
        usedBefore = !(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "app.klavko.Klavko") ?? [:]).isEmpty
        let oldTypography = defaults.object(forKey: Key.typography) as? Bool ?? true
        defaults.register(defaults: [
            Key.enabled: true,
            Key.switchWhileTyping: true,
            Key.triggers: SwitchTrigger.allCases.map(\.rawValue),
            Key.backspaceUndo: true,
            Key.convertAbbreviations: false,
            Key.correctSpelling: true,
            Key.spaceAfterPunctuation: true,
            Key.autoCapitalize: true,
            // Typography was one switch before 0.14: whoever turned it off keeps all three off.
            Key.dashes: oldTypography,
            Key.smartQuotes: oldTypography,
            Key.symbols: oldTypography,
            Key.listContinuation: true,
            Key.showFlag: true,
            Key.playSound: true,
            Key.soundName: "Pop",
            Key.playSpellingSound: true,
            Key.spellingSoundName: "Tink",
            Key.playCopySound: true,
            Key.copySoundName: "Tink",
            // Terminals: words there are mostly commands, not natural language.
            // Code editors: "...", quotes and capitals mean something else in code.
            Key.offerVoiceCorrections: true,
            Key.voiceEngine: "local",
            Key.googleSmart: true,
            Key.checkForUpdates: true,
            Key.clipboardEnabled: true,
            Key.clipboardKeepDays: 30,
            Key.clipboardIgnoredApps: ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                                       "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc"],
            Key.excludedApps: ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
                               "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
                               "com.sublimetext.4"],
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        switchWhileTyping = defaults.bool(forKey: Key.switchWhileTyping)
        triggers = Set((defaults.stringArray(forKey: Key.triggers) ?? []).compactMap(SwitchTrigger.init(rawValue:)))
        backspaceUndo = defaults.bool(forKey: Key.backspaceUndo)
        convertAbbreviations = defaults.bool(forKey: Key.convertAbbreviations)
        manualLanguages = defaults.stringArray(forKey: Key.manualLanguages) ?? []
        exceptions = defaults.stringArray(forKey: Key.exceptions) ?? []
        correctSpelling = defaults.bool(forKey: Key.correctSpelling)
        spaceAfterPunctuation = defaults.bool(forKey: Key.spaceAfterPunctuation)
        autoCapitalize = defaults.bool(forKey: Key.autoCapitalize)
        dashes = defaults.bool(forKey: Key.dashes)
        smartQuotes = defaults.bool(forKey: Key.smartQuotes)
        symbols = defaults.bool(forKey: Key.symbols)
        listContinuation = defaults.bool(forKey: Key.listContinuation)
        let language = defaults.string(forKey: Key.interfaceLanguage).flatMap(AppLanguage.init(rawValue:))
            ?? .systemDefault
        interfaceLanguage = language
        AppLanguage.current = language
        // Before 0.13 it was one choice: "auto" (Ukrainian and English), "uk" or "en".
        let oldVoice = defaults.string(forKey: Key.voiceLanguage)
        let languages = TranslationDirection.languages
        let own = defaults.string(forKey: Key.translationOwn).flatMap { languages.contains($0) ? $0 : nil } ?? "uk"
        translationOwn = own
        translationOther = defaults.string(forKey: Key.translationOther)
            .flatMap { languages.contains($0) && $0 != own ? $0 : nil } ?? (own == "en" ? "uk" : "en")
        let storedVoices = (defaults.stringArray(forKey: Key.voiceLanguages) ?? [])
            .filter(Self.speechLanguages.contains)
        voiceLanguages = !storedVoices.isEmpty ? storedVoices
            : oldVoice == "uk" || oldVoice == "en" ? [oldVoice!] : ["uk", "en"]
        voiceEngine = defaults.string(forKey: Key.voiceEngine) == "google" ? "google" : "local"
        googleSmart = defaults.bool(forKey: Key.googleSmart)
        googleModel = defaults.string(forKey: Key.googleModel)
        // Left over from the AI actions (removed in 0.10).
        defaults.removeObject(forKey: "aiModel")
        defaults.removeObject(forKey: "aiActions")
        offerVoiceCorrections = defaults.bool(forKey: Key.offerVoiceCorrections)
        checkForUpdates = defaults.bool(forKey: Key.checkForUpdates)
        clipboardEnabled = defaults.bool(forKey: Key.clipboardEnabled)
        clipboardKeepDays = defaults.integer(forKey: Key.clipboardKeepDays)
        clipboardIgnoredApps = defaults.stringArray(forKey: Key.clipboardIgnoredApps) ?? []
        voiceVocabulary = defaults.data(forKey: Key.voiceVocabulary)
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
        replacements = defaults.data(forKey: Key.replacements)
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
        showFlag = defaults.bool(forKey: Key.showFlag)
        playSound = defaults.bool(forKey: Key.playSound)
        soundName = defaults.string(forKey: Key.soundName) ?? "Pop"
        playSpellingSound = defaults.bool(forKey: Key.playSpellingSound)
        spellingSoundName = defaults.string(forKey: Key.spellingSoundName) ?? "Tink"
        playCopySound = defaults.bool(forKey: Key.playCopySound)
        copySoundName = defaults.string(forKey: Key.copySoundName) ?? "Tink"
        excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        shortcuts = Self.loadShortcuts(defaults.data(forKey: Key.shortcuts))
        modifierSides = defaults.bool(forKey: Key.modifierSides)
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Autostart is on by default, but only from an installed copy: a build folder may move or vanish.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if installed && !defaults.bool(forKey: Key.loginItemConfigured) {
            defaults.set(true, forKey: Key.loginItemConfigured)
            // didSet doesn't run inside init, so register directly.
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.engine.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else if installed && launchAtLogin && defaults.string(forKey: Key.loginItemPath) != Bundle.main.bundlePath {
            // The app was moved (e.g. ~/Applications → /Applications): point the login item at this copy.
            try? SMAppService.mainApp.unregister()
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.engine.error("Login item re-registration failed: \(error.localizedDescription, privacy: .public)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        if installed && launchAtLogin { defaults.set(Bundle.main.bundlePath, forKey: Key.loginItemPath) }
    }

    func toggleTrigger(_ trigger: SwitchTrigger) {
        if triggers.contains(trigger) { triggers.remove(trigger) } else { triggers.insert(trigger) }
    }

    // MARK: - Shortcuts

    /// Assigning a shortcut already used by another action moves it here.
    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        var updated = shortcuts
        if let shortcut {
            for (other, existing) in updated where other != action && existing == shortcut {
                updated[other] = nil
            }
        }
        updated[action] = shortcut
        shortcuts = updated
    }

    func resetShortcuts() {
        shortcuts = Self.loadShortcuts(nil)
    }

    /// Stored as {action: shortcut or null}; an action missing from storage gets its default.
    private static func loadShortcuts(_ data: Data?) -> [HotkeyAction: Shortcut] {
        let stored = data.flatMap { try? JSONDecoder().decode([String: Shortcut?].self, from: $0) } ?? [:]
        var result: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            let shortcut = stored[action.rawValue] ?? action.defaultShortcut
            if let shortcut { result[action] = shortcut }
        }
        return result
    }

    private func saveShortcuts() {
        let stored = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.rawValue, shortcuts[$0]) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.shortcuts)
        }
    }

    // MARK: - Exceptions

    /// Adds a word as typed ("ye", "npm"); returns false for empty input or a duplicate.
    @discardableResult
    func addException(_ input: String) -> Bool {
        let word = TextRules.coreWord(input.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        guard !word.isEmpty, !exceptions.contains(word) else { return false }
        exceptions = (exceptions + [word]).sorted()
        return true
    }

    func removeException(_ word: String) {
        exceptions.removeAll { $0 == word }
    }

    /// Counts reverts of Klavko's fixes per word, across restarts.
    /// Returns true on the second revert of a word the user hasn't already declined to add.
    func recordRevert(of word: String) -> Bool {
        let key = word.lowercased()
        guard !exceptions.contains(key),
              !(defaults.stringArray(forKey: Key.declinedExceptions) ?? []).contains(key) else { return false }
        var counts = defaults.dictionary(forKey: Key.revertCounts) as? [String: Int] ?? [:]
        counts[key, default: 0] += 1
        // Keep only a handful of recent words; this is a hint, not a history.
        if counts.count > 200, let stale = counts.min(by: { $0.value < $1.value })?.key, stale != key {
            counts[stale] = nil
        }
        let offer = counts[key, default: 0] >= 2
        if offer { counts[key] = nil }
        defaults.set(counts, forKey: Key.revertCounts)
        return offer
    }

    /// "No" to the offer: don't ask about this word again.
    func declineException(_ word: String) {
        var declined = defaults.stringArray(forKey: Key.declinedExceptions) ?? []
        declined.append(word.lowercased())
        defaults.set(declined, forKey: Key.declinedExceptions)
    }

    // MARK: - Replacements

    /// Adds or updates a replacement; false if either side is empty.
    @discardableResult
    func setReplacement(from: String, to: String) -> Bool {
        let from = from.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return false }
        var updated = replacements.filter { $0.from != from }
        updated.append(Replacement(from: from, to: to))
        replacements = updated
        return true
    }

    func removeReplacement(_ replacement: Replacement) {
        replacements.removeAll { $0 == replacement }
    }

    // MARK: - Voice vocabulary

    /// Adds or updates a spelling for dictation ("зсу" → "ЗСУ"); false if either side is empty.
    @discardableResult
    func setVoiceSpelling(heard: String, written: String) -> Bool {
        let heard = heard.trimmingCharacters(in: .whitespaces)
        let written = written.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !written.isEmpty else { return false }
        var updated = voiceVocabulary.filter { $0.from.lowercased() != heard.lowercased() }
        updated.append(Replacement(from: heard, to: written))
        voiceVocabulary = updated
        return true
    }

    func removeVoiceSpelling(_ rule: Replacement) {
        voiceVocabulary.removeAll { $0 == rule }
    }

    // MARK: - Excluded apps

    func isExcluded(_ bundleID: String) -> Bool {
        excludedApps.contains(bundleID)
    }

    func toggleExcluded(_ bundleID: String) {
        if isExcluded(bundleID) {
            excludedApps.removeAll { $0 == bundleID }
        } else {
            excludedApps.append(bundleID)
        }
    }
}
