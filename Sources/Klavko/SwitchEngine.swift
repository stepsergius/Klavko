import Carbon
import CoreGraphics
import Foundation
import KlavkoCore

/// What kind of fix Klavko just made (layout and spelling have their own sounds; formatting is silent).
enum FixKind {
    case layout, spelling, formatting
}

/// Tracks what is being typed and fixes text typed in the wrong layout or misspelled.
///
/// - While typing: as soon as no word starts like the typed letters but many start like the
///   other layout's letters ("ghb" vs "при"), the word is retyped and the layout switches.
/// - After a word (Space, Tab, Enter, punctuation): a misspelled word that is valid in the other layout is converted;
///   otherwise an obvious spelling mistake is corrected ("рлбиш" -> "робиш", "ПРивіт" -> "Привіт").
/// - Backspace right after a fix (if enabled) undoes it. The undo hotkey undoes the latest fix even after
///   more typing (until the caret moves), and pressing it again puts the fix back.
/// - Reverting the same automatic fix twice — by undo or by switching the word back by hand — offers an exception.
/// Hotkeys work even when automatic fixes are off or the app is excluded.
final class SwitchEngine {
    struct Config {
        var shortcuts: [HotkeyAction: Shortcut] = [:]
        var autoSwitch = true
        var triggers: Set<SwitchTrigger> = Set(SwitchTrigger.allCases)
        var switchWhileTyping = true
        var backspaceUndo = true
        var convertAbbreviations = false
        var correctSpelling = true
        var spaceAfterPunctuation = true
        var autoCapitalize = true
        var dashes = true
        var smartQuotes = true
        var symbols = true
        var listContinuation = true
        /// The user's own replacements ("сп" → "спасибі").
        var replacements: [Replacement] = []
        /// Lowercased words never to convert or correct.
        var exceptions: Set<String> = []
        /// Languages Klavko never switches into by itself ("uk" for someone who writes in Russian and only
        /// now and then in Ukrainian: their words are mostly real words of both). A hotkey still converts into them.
        var manualLanguages: Set<String> = []
    }

    /// True while a shortcut is being recorded: Klavko must not react to any key.
    var isPaused: () -> Bool = { false }
    /// True when the frontmost app is in the exclusion list: no automatic fixes there.
    var isExcluded: () -> Bool = { false }
    /// True when the frontmost app continues lists on its own (Notes, Word…): don't add a second marker.
    var appContinuesLists: () -> Bool = { false }
    var config = Config() {
        didSet {
            analyzer.convertAbbreviations = config.convertAbbreviations
            analyzer.exceptions = config.exceptions
            spelling.exceptions = config.exceptions
        }
    }
    /// Called after Klavko changed text.
    var onFix: (FixKind) -> Void = { _ in }
    /// The AI actions hotkey was pressed.
    /// The voice input hotkey was pressed.
    var onTranslate: () -> Void = {}
    var onClipboard: () -> Void = {}
    var onScreenText: () -> Void = {}
    var onVoice: () -> Void = {}
    /// Esc was pressed: true if something (voice input) used it, so it isn't passed on.
    var onEscape: () -> Bool = { false }
    /// Return / Enter was pressed: true if something (voice input) used it, so it isn't passed on.
    var onReturn: () -> Bool = { false }
    /// Any key the user pressed (Klavko's own typing excluded).
    var onUserKey: () -> Void = {}
    /// Called when the user reverted an automatic fix of a word (the word as they want it).
    var onRevert: (String) -> Void = { _ in }

    private typealias Layout = (source: TISInputSource, map: LayoutMap)
    private typealias Pair = (current: Layout, alternative: Layout)

    private struct Conversion {
        enum Scope { case word, phrase }
        /// Exactly what was on screen before (including a trailing space or punctuation).
        let original: String
        /// Exactly what is on screen after.
        let converted: String
        let from: Layout
        /// nil for a spelling fix, which keeps the layout.
        let to: Layout?
        let automatic: Bool
        let scope: Scope
        /// Re-applied with the undo hotkey; reverting it again is not a new complaint.
        var redone = false
        /// Typography, capitalization, case or a user replacement.
        var isFormatting = false

        var kind: FixKind { isFormatting ? .formatting : to == nil ? .spelling : .layout }
    }

    /// A fix and where it sits in `visible`.
    private struct PlacedFix {
        var conversion: Conversion
        /// Index in `visible` just past the fix's text.
        let end: Int
        /// Nothing typed since: Backspace and ⇧⇧ may undo it.
        var immediate = true
    }

    private var layouts: [Layout] = []
    /// Layouts the current one may have been meant as, most likely first (set with the current pair).
    private var alternatives: [Layout] = []
    /// Layout IDs in the order they were last typed in, latest first.
    private var recentLayoutIDs: [String] = []
    /// The languages of words seen in the language context, so each is looked up once.
    private var wordLanguages: [String: Set<String>] = [:]
    /// One checker for both, so its completion cache is shared.
    private let spellChecker = MacSpellChecker()
    private lazy var analyzer = WordAnalyzer(spellChecker: spellChecker)
    private lazy var spelling = TypoCorrector(spellChecker: spellChecker)
    private var modifierTaps = ModifierTapDetector()
    private var lastMissingLayoutID: String?
    /// Evaluated once per event.
    private var excludedNow = false

    // Typed text lives only in memory and is dropped whenever the caret may have moved.
    /// Keystrokes of the word under the caret (its last `buffer.count` characters of `visible`).
    private var buffer: [Keystroke] = []
    /// The current word was already converted or reverted: don't touch it again.
    private var wordLocked = false
    /// Klavko switched the layout of the word while it was typed ("GHb" → "ПРи…"): at its end only a stuck
    /// Shift is still fixed.
    private var convertedMidWord = false
    /// The user went back into the word with Backspace (into a fix, or to a finished word): it is theirs now,
    /// and nothing in it is fixed automatically.
    private var editedByUser = false
    /// The user deleted Klavko's fix: the text before it, and when. A word typed again in that place
    /// within a minute is theirs too (otherwise deleting a fix and retyping the word brings the fix back).
    private var rejectedFix: (before: String, at: Date)?
    /// Something was typed since the caret last jumped (so `buffer` holds letters the user just typed,
    /// not a word picked up from the text around the caret).
    private var typedSinceJump = false
    /// The layout the current word is being typed in, to notice when the user switches it by hand.
    private var bufferLayoutID: String?
    /// The current word had an automatic fix reverted and it is yet to be reported.
    private var revertedInWord = false
    /// What is on screen since the caret last jumped (click, Enter, arrows, app switch).
    private var visible: [Character] = []
    /// How many characters at the start of `visible` were read from the text field (Accessibility)
    /// rather than typed: context only, never converted as "what was typed".
    private var contextLength = 0
    /// Accessibility said the caret is at the very start of the text (so a capital letter is due).
    private var atFieldStart = false
    /// The word that was just finished with a Space and left as is.
    private var lastWord: [Keystroke] = []
    /// The latest fix, undoable while it is still on screen as Klavko left it.
    private var recentFix: PlacedFix?
    /// The fix just undone, re-appliable with the same hotkey until something is typed.
    private var undone: PlacedFix?

    /// A one-letter word at the start of a sentence typed in the other layout ("z" for "я"),
    /// left alone until the next word shows which language the sentence is in.
    private struct LoneLetter {
        /// Where it is in `visible`.
        let index: Int
        let typed: Character
        let converted: Character
        /// A punctuation mark right after it ("S?" -> "І,"), switched along with it.
        let mark: (typed: Character, converted: Character)?
        let language: String
        /// Words after it that may still decide: words of both languages ("у", "так") don't.
        var wordsLeft = 4
    }
    private var loneLetter: LoneLetter?

    private let maxVisibleLength = 1000

    private enum KeyCode {
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
    }

    private var autoSwitchAllowed: Bool { config.autoSwitch && !excludedNow }
    /// The alternatives Klavko may switch into by itself, likeliest first.
    /// Only with more than two languages, as in Settings: with two, leaving one out would turn switching off,
    /// and a language marked while a third layout was on would stay hidden there after that layout is removed.
    private var automaticAlternatives: [Layout] {
        guard !config.manualLanguages.isEmpty, Set(layouts.map(\.map.language)).count > 2 else { return alternatives }
        return alternatives.filter { !config.manualLanguages.contains($0.map.language) }
    }
    private var spellingAllowed: Bool { config.correctSpelling && !excludedNow }

    /// The first dictionary lookups are slow (loading); do them before the user types.
    func warmUp() {
        for (language, word) in [("uk", "привіт"), ("en", "hello")] {
            _ = spellChecker.isValid(word, language: language)
            _ = spellChecker.completions(for: String(word.prefix(3)), language: language)
            _ = spelling.correction(for: word + "q", language: language, layout: nil, allowCapitalized: false)
        }
        for language in Set(layouts.map(\.map.language)).subtracting(["uk", "en"]) {
            _ = spellChecker.isValid("a", language: language)
        }
    }

    func reloadLayouts() {
        layouts = SystemLayouts.enabledLayouts()
        wordLanguages = [:]
        Log.engine.notice("Layouts: \(self.layouts.map(\.map.id).joined(separator: ", "), privacy: .public)")
    }

    /// Returns false to swallow the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard !isPaused() else {
            reset()
            return true
        }
        switch type {
        case .keyDown:
            onUserKey()
            excludedNow = isExcluded()
            return handleKeyDown(event)
        case .flagsChanged:
            handleFlagsChanged(event)
            return true
        default:
            // A mouse click may move the caret; whatever we tracked is stale.
            modifierTaps.interrupt()
            reset()
            return true
        }
    }

    func reset() {
        typedSinceJump = false
        contextLength = 0
        atFieldStart = false
        endWord()
        loneLetter = nil
        visible = []
        lastWord = []
        recentFix = nil
        undone = nil
    }

    // MARK: - Keys

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        modifierTaps.interrupt()

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let action = comboAction(keyCode: keyCode, flags: flags) {
            perform(action)
            return false
        }
        // ⌃Space / ⌃⌥Space switch the input source: the caret stays, so keep what we know.
        if keyCode == KeyCode.space, flags.contains(.maskControl), !flags.contains(.maskCommand) {
            return true
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
            || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            reset()
            return true
        }
        if keyCode == KeyCode.backspace {
            return handleBackspace()
        }
        if keyCode == KeyCode.escape, flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty,
           onEscape() {
            return false
        }
        if keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter,
           flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty,
           onReturn() {
            return false
        }

        // Something new is typed: the latest fix is no longer "just made", and redo is off.
        recentFix?.immediate = false
        undone = nil
        guard let pair = currentPair() else {
            reset()
            return true
        }
        // The layout changed during the word: the user switched it (Klavko locks words it switches itself).
        // Its letters were typed in the old layout and the choice is theirs, so leave the word alone.
        if !buffer.isEmpty, let typedIn = bufferLayoutID, typedIn != pair.current.map.id {
            wordLocked = true
        }
        bufferLayoutID = pair.current.map.id
        if recentLayoutIDs.first != pair.current.map.id {
            recentLayoutIDs.removeAll { $0 == pair.current.map.id }
            recentLayoutIDs.insert(pair.current.map.id, at: 0)
        }
        let keystroke = Keystroke(keyCode: keyCode, shift: flags.contains(.maskShift),
                                  capsLock: flags.contains(.maskAlphaShift))

        switch keyCode {
        case KeyCode.space:
            return handleSpace(keystroke, pair)
        case KeyCode.tab, KeyCode.returnKey, KeyCode.keypadEnter:
            return handleLineBreak(keyCode, shift: flags.contains(.maskShift), pair)
        default:
            break
        }

        guard let typedCharacter = pair.current.map.character(for: keystroke),
              let alternativeCharacter = pair.alternative.map.character(for: keystroke) else {
            // Arrows, Esc, function keys: the caret may jump, start over.
            reset()
            return true
        }
        if typedCharacter == "\"" && formattingAllowed(config.smartQuotes) {
            return handleStraightQuote(pair)
        }
        if pair.current.map.isWordCharacter(keystroke) || alternatives.contains(where: { $0.map.isWordCharacter(keystroke) }) {
            return handleWordCharacter(keystroke, typedCharacter, pair)
        }
        return handlePunctuation(keystroke, typedCharacter, alternativeCharacter, pair)
    }

    private func formattingAllowed(_ enabled: Bool) -> Bool { enabled && !excludedNow }

    private func handleWordCharacter(_ keystroke: Keystroke, _ typedCharacter: String, _ pair: Pair) -> Bool {
        lastWord = []
        defer { typedSinceJump = true }
        // After a click, app switch or restart we don't know what's before the caret: look.
        if buffer.isEmpty && visible.isEmpty { readContextBeforeCaret() }
        if buffer.isEmpty { claimRejectedSpot() }

        var keystroke = keystroke
        var character = typedCharacter
        let before = String(visible.suffix(80))
        // "Привіт,як": the space after the comma was forgotten.
        let addSpace = buffer.isEmpty && formattingAllowed(config.spaceAfterPunctuation)
            && character.count == 1 && Spacing.needsSpace(before: before, next: character.first!)
        // "так. ні": a sentence starts with a capital letter.
        var capitalized = false
        // "S? " may yet become "І, ": while that's undecided, its "?" doesn't start a sentence.
        let markUndecided = loneLetter?.mark != nil
        if buffer.isEmpty, !markUndecided, formattingAllowed(config.autoCapitalize), character.count == 1,
           let letter = character.first, letter.isLetter, letter.isLowercase,
           Capitalization.startsSentence(before: addSpace ? before + " " : before,
                                         atFieldStart: atFieldStart && visible.isEmpty) {
            let shifted = Keystroke(keyCode: keystroke.keyCode, shift: !keystroke.shift, capsLock: keystroke.capsLock)
            if let upper = pair.current.map.character(for: shifted), upper == character.uppercased() {
                keystroke = shifted
                character = upper
                capitalized = true
            }
        }

        if addSpace { appendVisible(" ") }
        appendVisible(character)
        buffer.append(keystroke)
        if addSpace || capitalized {
            // A one-letter word can't be converted yet, so just type what's due.
            if addSpace {
                TextInjector.type(" ")
                Log.engine.notice("Added a space after punctuation")
            }
            if capitalized {
                apply(Conversion(original: typedCharacter, converted: character, from: pair.current, to: nil,
                                 automatic: true, scope: .word, isFormatting: true),
                      onScreen: 0)
                Log.engine.notice("Capitalized a sentence start")
            } else {
                TextInjector.type(character)
            }
            return false
        }
        // "..." in the English layout, where "." is a letter key of the Ukrainian one.
        if replaceTypedSequence(pair) {
            endWord()
            return false
        }
        return !convertWhileTyping(pair)
    }

    /// A straight `"` becomes «» (Ukrainian) or “” (English). It also ends the word before it.
    private func handleStraightQuote(_ pair: Pair) -> Bool {
        // A word the user has just typed: the quote closes it.
        let closesTypedWord = !buffer.isEmpty && typedSinceJump
        // Otherwise the caret may have moved back into existing text ("|Привіт"): look around it.
        // A letter right after the caret means the quote opens.
        let opensWord = !closesTypedWord
            && (CaretContext.textAfterCaret(limit: 1)?.first.map { $0.isLetter || $0.isNumber } ?? false)
        if buffer.isEmpty && visible.isEmpty { readContextBeforeCaret() }
        typedSinceJump = true
        // Only a word just typed gets checked; one picked up from the surrounding text is the user's own.
        let word = closesTypedWord ? buffer : []
        let locked = wordLocked
        let caseOnly = onlyCaseLeft
        endWord()
        lastWord = []
        appendVisible("\"")
        let fixed = config.triggers.contains(.punctuation) && finishWord(locked: locked, caseOnly: caseOnly, word, pair, typedTrail: "\"", alternativeTrail: { _ in "\"" })
        let language = pair.current.map.language
        let quote = closesTypedWord ? Typography.quote(after: "x", language: language)
            : opensWord ? Typography.quote(after: "", language: language)
            : Typography.quote(after: String(visible.dropLast().suffix(10)), language: language)
        apply(Conversion(original: "\"", converted: String(quote), from: pair.current, to: nil,
                         automatic: true, scope: .word, isFormatting: true),
              onScreen: fixed ? 1 : 0)
        return false
    }

    /// Replaces a just-completed sequence ("...", "(c)", or the user's own like ":)") as soon as it's typed.
    /// The key being typed is its last character and hasn't reached the screen. Returns true if replaced.
    private func replaceTypedSequence(_ pair: Pair) -> Bool {
        var rules = config.replacements.filter { !$0.isWord }
        if formattingAllowed(config.symbols) { rules += Typography.builtIn }
        guard !excludedNow, !rules.isEmpty,
              let rule = Typography.immediateMatch(in: String(visible.suffix(20)), rules: rules) else { return false }
        apply(Conversion(original: rule.from, converted: rule.to, from: pair.current, to: nil,
                         automatic: true, scope: .word, isFormatting: true),
              onScreen: rule.from.count - 1)
        Log.engine.notice("Replaced a typed sequence")
        return true
    }

    private func handleBackspace() -> Bool {
        // Formatting (a capital letter, «») isn't undone by Backspace: there it should just delete.
        if config.backspaceUndo, let fix = recentFix, fix.immediate, !fix.conversion.isFormatting {
            undo(fix)
            return false
        }
        undone = nil
        lastWord = []
        if !buffer.isEmpty {
            buffer.removeLast()
            if !visible.isEmpty { visible.removeLast() }
            contextLength = min(contextLength, visible.count)
        } else if !visible.isEmpty {
            visible.removeLast()
            contextLength = min(contextLength, visible.count)
            // Back at the end of the previous word (or at the start of what we've seen): pick it up again.
            resumeWordBeforeCaret()
            // Going back into a finished word is editing it: it's the user's word now, no automatic fixes.
            if !buffer.isEmpty { markEditedByUser() }
        } else {
            // Deleting into text typed before we started watching: we don't know its letters,
            // and the user is editing it by hand. Leave it alone until the next word.
            wordLocked = true
        }
        if let lone = loneLetter, visible.count <= lone.index + 1 { loneLetter = nil }
        // Deleting into the latest fix: it's the user's text now, and Klavko doesn't fix it again
        // (a word it doesn't know would otherwise be "fixed" each time it's retyped).
        if let fix = recentFix, visible.count < fix.end {
            recentFix = nil
            markEditedByUser()
            let start = min(max(0, fix.end - fix.conversion.converted.count), visible.count)
            rejectedFix = (String(visible[..<start].suffix(30)), Date())
        }
        return true
    }

    /// A word starts where the user deleted Klavko's fix a moment ago: it's their word, leave it as typed.
    private func claimRejectedSpot() {
        guard let rejected = rejectedFix else { return }
        guard Date().timeIntervalSince(rejected.at) < 60 else { rejectedFix = nil; return }
        if String(visible.suffix(30)) == rejected.before {
            rejectedFix = nil
            markEditedByUser()
        }
    }

    private func markEditedByUser() {
        editedByUser = true
        wordLocked = true
    }

    private func handleSpace(_ keystroke: Keystroke, _ pair: Pair) -> Bool {
        typedSinceJump = true
        let word = buffer
        let locked = wordLocked
        let caseOnly = onlyCaseLeft
        endWord()
        appendVisible(" ")
        if config.triggers.contains(.space), finishWord(locked: locked, caseOnly: caseOnly, word, pair, typedTrail: " ", alternativeTrail: { _ in " " }) {
            settleLoneLetter(afterFixedWord: true, word, pair, pendingCharacters: 0)
            return false
        }
        if settleLoneLetter(afterFixedWord: false, word, pair, pendingCharacters: 1) {
            return false
        }
        // "так - ні" → "так — ні".
        if formattingAllowed(config.dashes) {
            let hyphens = Typography.dashHyphens(before: String(visible.dropLast().suffix(20)))
            if hyphens > 0 {
                apply(Conversion(original: String(repeating: "-", count: hyphens) + " ", converted: "— ",
                                 from: pair.current, to: nil, automatic: true, scope: .word, isFormatting: true),
                      onScreen: hyphens)
                return false
            }
        }
        if !locked { rememberLoneLetter(word, pair, mark: nil) }
        lastWord = word
        return true
    }

    private func handleLineBreak(_ keyCode: UInt16, shift: Bool, _ pair: Pair) -> Bool {
        let word = buffer
        let locked = wordLocked
        let caseOnly = onlyCaseLeft
        let trigger: SwitchTrigger = keyCode == KeyCode.tab ? .tab : .enter
        // Read the line before anything is retyped: the list marker at its start doesn't change.
        let list = keyCode != KeyCode.tab && !shift && formattingAllowed(config.listContinuation) && !appContinuesLists()
            ? currentLineBeforeCaret().flatMap(ListContinuation.action) : nil
        let fixed = config.triggers.contains(trigger) && finishWord(locked: locked, caseOnly: caseOnly, word, pair, typedTrail: "", alternativeTrail: { _ in "" })
        let letterSettled = settleLoneLetter(afterFixedWord: fixed, word, pair, pendingCharacters: 0)
        reset()

        let pass: Bool
        switch list {
        case .endList(let count) where !fixed && !letterSettled:
            // Enter on an empty item ends the list: remove the marker instead of a new line.
            TextInjector.replace(deleting: count, with: "")
            Log.engine.notice("Ended a list")
            pass = false
        case .continueWith(let marker):
            TextInjector.pressKey(CGKeyCode(keyCode))
            TextInjector.type(marker)
            Log.engine.notice("Continued a list")
            startLine(with: marker)
            return false
        default:
            if fixed || letterSettled {
                // Re-send the key after the retyped text (Shift+Enter stays a soft line break).
                TextInjector.pressKey(CGKeyCode(keyCode), flags: shift ? .maskShift : [])
            }
            pass = !(fixed || letterSettled)
        }
        // We know what's before the caret now: a new line. (Asking the app right away could get the old text:
        // it may not have taken in our typing yet.)
        if keyCode != KeyCode.tab { startLine(with: "") }
        return pass
    }

    /// The caret is at the start of a new line, after `marker` (a list marker or nothing).
    private func startLine(with marker: String) {
        visible = Array("\n" + marker)
        contextLength = visible.count
    }

    /// The text of the current line before the caret, if known: from the app (Accessibility),
    /// or from what we've seen since a line break.
    private func currentLineBeforeCaret() -> String? {
        let limit = 300
        if let before = CaretContext.textBeforeCaret(limit: limit) {
            if let newline = before.lastIndex(where: \.isNewline) {
                return String(before[before.index(after: newline)...])
            }
            return before.count < limit ? before : nil
        }
        if let newline = visible.lastIndex(where: \.isNewline) {
            return String(visible[(newline + 1)...])
        }
        return nil
    }

    /// Punctuation or a digit ends the word. After a layout fix, the mark is typed as the new layout has it
    /// ("ghbdsn?" -> "привіт,").
    private func handlePunctuation(_ keystroke: Keystroke, _ typedCharacter: String, _ alternativeCharacter: String,
                                   _ pair: Pair) -> Bool {
        typedSinceJump = true
        let word = buffer
        let locked = wordLocked
        let caseOnly = onlyCaseLeft
        endWord()
        lastWord = []
        appendVisible(typedCharacter)
        if config.triggers.contains(.punctuation),
           finishWord(locked: locked, caseOnly: caseOnly, word, pair, typedTrail: typedCharacter,
                           alternativeTrail: { $0.character(for: keystroke) ?? alternativeCharacter }) {
            settleLoneLetter(afterFixedWord: true, word, pair, pendingCharacters: 0)
            return false
        }
        if settleLoneLetter(afterFixedWord: false, word, pair, pendingCharacters: 1) {
            return false
        }
        if replaceTypedSequence(pair) {
            return false
        }
        if !locked, !typedCharacter.contains(where: \.isNumber),
           let typedMark = typedCharacter.first, let convertedMark = alternativeCharacter.first {
            rememberLoneLetter(word, pair, mark: (typedMark, convertedMark))
        }
        return true
    }

    // MARK: - One-letter word at the start of a sentence

    /// "z " or "S?": could be "я" or "І,", but a single letter is too ambiguous on its own,
    /// so the next word decides ("ш love" → "I love"). `mark`: the punctuation typed right after it, if any.
    private func rememberLoneLetter(_ word: [Keystroke], _ pair: Pair,
                                    mark: (typed: Character, converted: Character)?) {
        guard autoSwitchAllowed, word.count == 1, let typed = pair.current.map.render(word),
              // The first layout where the key is a word ("э" is "'" in English but "є" in Ukrainian).
              let alternative = automaticAlternatives.first(where: { layout in
                  layout.map.render(word).map {
                      ShortWords.isLoneLetterCandidate(typed: typed, typedLanguage: pair.current.map.language,
                                                       alternative: $0, alternativeLanguage: layout.map.language)
                  } ?? false
              }),
              let converted = alternative.map.render(word),
              let typedCharacter = typed.first,
              let convertedCharacter = Self.englishI(converted, language: alternative.map.language).first
        else { return }
        loneLetter = LoneLetter(index: visible.count - 2, typed: typedCharacter, converted: convertedCharacter,
                                mark: mark, language: alternative.map.language)
    }

    /// A word after a lone letter is finished (or was just converted). If it is in the letter's
    /// other language, switch the letter too ("э у мене" → "є у мене"); a word of both languages ("у")
    /// leaves it to the next ones. `pendingCharacters`: how many characters at the end of
    /// `visible` haven't reached the screen yet (the Space being typed); Klavko then types them itself.
    /// Returns true when it retyped text (the key being typed must then be swallowed).
    @discardableResult
    private func settleLoneLetter(afterFixedWord fixed: Bool, _ word: [Keystroke], _ pair: Pair,
                                  pendingCharacters: Int) -> Bool {
        // A space or more punctuation after the letter isn't the next word yet.
        guard var lone = loneLetter, fixed || !word.isEmpty else { return false }
        loneLetter = nil
        guard lone.index < visible.count, visible[lone.index] == lone.typed else { return false }

        let language: String
        if fixed {
            language = recentFix?.conversion.to?.map.language ?? pair.current.map.language
        } else {
            guard let typed = pair.current.map.render(word) else { return false }
            let core = TextRules.coreWord(typed)
            guard !core.isEmpty else { return false }
            func known(_ language: String) -> Bool {
                spellChecker.isValid(core, language: language) || ShortWords.isCommon(core.lowercased(), language: language)
            }
            let inTyped = known(pair.current.map.language)
            // Ukrainian and Russian share most letters: "мене" typed in the Russian layout is a Ukrainian word as it is.
            let inLetters = known(lone.language)
            if inLetters != inTyped {
                language = inLetters ? lone.language : pair.current.map.language
            } else {
                // A word of both (or a typo): the next words may still tell.
                lone.wordsLeft -= 1
                if lone.wordsLeft > 0 { loneLetter = lone }
                return false
            }
            // The text goes on in the letter's language: so does the layout.
            if language == lone.language, let target = layouts.first(where: { $0.map.language == language }) {
                SystemLayouts.select(target.source)
            }
        }
        guard language == lone.language else { return false }

        var after = Array(visible[(lone.index + 1)...])
        if let mark = lone.mark, after.first == mark.typed {
            after[0] = mark.converted
        }
        TextInjector.replace(deleting: 1 + after.count - pendingCharacters, with: String(lone.converted) + String(after))
        visible.replaceSubrange(lone.index..., with: [lone.converted] + after)
        if !fixed { onFix(.layout) }
        Log.engine.notice("Switched a one-letter word after the next word")
        return true
    }

    private func comboAction(keyCode: UInt16, flags: CGEventFlags) -> HotkeyAction? {
        let modifiers = Self.modifiers(flags)
        guard !modifiers.isEmpty else { return nil }
        let held = ModifierSide.held(in: flags.rawValue)
        return shortcutsBySide.first { $0.value.matches(keyCode: keyCode, modifiers: modifiers, held: held) }?.key
    }

    /// Shortcuts that name a side first: "right ⌘" wins over a plain "⌘" pressed with the right key.
    private var shortcutsBySide: [(key: HotkeyAction, value: Shortcut)] {
        config.shortcuts.sorted { $0.value.sides.count > $1.value.sides.count }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard ModifierKey(keyCode: keyCode) != nil else {
            // Caps Lock.
            modifierTaps.interrupt()
            return
        }
        var held = Self.modifiers(event.flags)
        // Fn counts only as a key of its own here: arrow and function keys carry its flag too.
        if event.flags.contains(.maskSecondaryFn) { held.insert(.function) }
        let taps = modifierTaps.modifiersChanged(held, sides: ModifierSide.held(in: event.flags.rawValue),
                                                 at: ProcessInfo.processInfo.systemUptime)
        for tap in taps {
            if let action = shortcutsBySide.first(where: { $0.value.matches(tap) })?.key {
                perform(action)
            }
        }
    }

    private static func modifiers(_ flags: CGEventFlags) -> Set<ModifierKey> {
        var result: Set<ModifierKey> = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    // MARK: - Automatic fixes

    /// A wrong layout first; if the layout is fine, maybe a spelling mistake.
    /// `alternativeTrail`: the trigger key as the layout converted into types it.
    private func fixFinishedWord(_ word: [Keystroke], _ pair: Pair, typedTrail: String,
                                 alternativeTrail: (LayoutMap) -> String) -> Bool {
        if replaceWholeWord(word, pair, trail: typedTrail)
            || capitalizeEnglishI(word, pair, trail: typedTrail)
            || autoConvert(word, pair, typedTrail: typedTrail, alternativeTrail: alternativeTrail) {
            return true
        }
        // The text is right but the layout isn't: no spelling "fix" in the wrong language. The key goes on as typed.
        if switchLayoutQuietly(word, pair, trail: typedTrail) { return false }
        return correctSpelling(word, pair, trail: typedTrail)
    }

    /// "что" typed in the Ukrainian layout looks the same in the Russian one: there is nothing to retype,
    /// but the word is Russian, so the next ones are typed in the Russian layout. Returns true when it switched.
    private func switchLayoutQuietly(_ word: [Keystroke], _ pair: Pair, trail: String) -> Bool {
        guard autoSwitchAllowed, let typed = pair.current.map.render(word) else { return false }
        let core = TextRules.coreWord(typed)
        // Cheap checks first: most words read differently in every other layout (Ukrainian vs English).
        let same = automaticAlternatives.filter { $0.map.render(word) == typed }
        // Short words are too often words of both; a capitalized word mid-sentence is likely a name;
        // the user's exceptions are never touched.
        guard !same.isEmpty, core.count > ShortWords.maxLength, !core.contains(where: \.isNumber),
              !config.exceptions.contains(core.lowercased()),
              core.first?.isUppercase != true || isSentenceStart(beforeLast: typed.count + trail.count),
              !spellChecker.isValid(core, language: pair.current.map.language),
              let target = same.first(where: { spellChecker.isValid(core, language: $0.map.language) }),
              // A word the typed language's dictionary lacks (a name, a typo, a rare word) in the middle of text
              // in that language doesn't make the text Russian: switching would turn the next "є" into "э".
              !languageContext(beforeLast: typed.count + trail.count).favors(pair.current.map.language, over: target.map.language)
        else { return false }
        SystemLayouts.select(target.source)
        onFix(.layout)
        Log.engine.notice("Switched layout without retyping \(pair.current.map.language, privacy: .public)→\(target.map.language, privacy: .public), \(word.count) chars")
        return true
    }

    /// English "i" on its own is always "I".
    private static func englishI(_ word: String, language: String) -> String {
        language == "en" && word == "i" ? "I" : word
    }

    /// "i" typed as a word in English → "I".
    private func capitalizeEnglishI(_ word: [Keystroke], _ pair: Pair, trail: String) -> Bool {
        guard formattingAllowed(config.autoCapitalize), pair.current.map.language == "en",
              pair.current.map.render(word) == "i" else { return false }
        apply(Conversion(original: "i" + trail, converted: "I" + trail, from: pair.current, to: nil,
                         automatic: true, scope: .word, isFormatting: true),
              onScreen: 1)
        return true
    }

    /// The user's own word replacements ("сп" → "спасибі").
    private func replaceWholeWord(_ word: [Keystroke], _ pair: Pair, trail: String) -> Bool {
        guard !excludedNow, !word.isEmpty, let typed = pair.current.map.render(word),
              let rule = Typography.wordMatch(typed, rules: config.replacements) else { return false }
        apply(Conversion(original: typed + trail, converted: rule.to + trail, from: pair.current, to: nil,
                         automatic: true, scope: .word, isFormatting: true),
              onScreen: typed.count)
        Log.engine.notice("Replaced a word with the user's text")
        return true
    }

    /// The word is finished. Returns true when it was converted; the trigger key is then typed by us.
    private func autoConvert(_ word: [Keystroke], _ pair: Pair, typedTrail: String,
                             alternativeTrail: (LayoutMap) -> String) -> Bool {
        guard autoSwitchAllowed, !word.isEmpty, let typed = pair.current.map.render(word) else { return false }
        let context = languageContext(beforeLast: typed.count + typedTrail.count)
        // The first layout in which the keys spell a real word.
        guard let found = candidates(for: word, pair, automatic: true).first(where: { option in
            analyzer.shouldConvert(typed: typed, typedLanguage: option.pair.current.map.language,
                                   alternative: option.text, alternativeLanguage: option.pair.alternative.map.language,
                                   context: context,
                                   sameScript: option.pair.alternative.map.script == pair.current.map.script)
        }) else { return false }
        let (pair, alternative) = found

        var converted = Self.englishI(alternative, language: pair.alternative.map.language)
        // "GHbdsn" → "Привіт", not "ПРивіт": the stuck Shift goes with the wrong layout.
        if spellingAllowed { converted = Self.stuckShiftFixed(converted) }
        apply(Conversion(original: typed + typedTrail, converted: converted + alternativeTrail(pair.alternative.map),
                         from: pair.current, to: pair.alternative, automatic: true, scope: .word),
              onScreen: typed.count)
        Log.engine.notice("Auto-converted word \(pair.current.map.language, privacy: .public)→\(pair.alternative.map.language, privacy: .public), \(word.count) chars")
        return true
    }

    private func correctSpelling(_ word: [Keystroke], _ pair: Pair, trail: String) -> Bool {
        // Greek, Hebrew, Arabic: each check is a completions lookup, too slow for hundreds of candidates.
        guard spellingAllowed, !word.isEmpty, !MacSpellChecker.knownByCompletions.contains(pair.current.map.language),
              let typed = pair.current.map.render(word) else { return false }
        let before = visibleText(beforeLast: typed.count + trail.count)
        guard !Self.looksLikeAddressOrCode(before: before, trail: trail),
              let fixed = spelling.correction(for: typed, language: pair.current.map.language,
                                              layout: pair.current.map,
                                              allowCapitalized: isSentenceStart(beforeLast: typed.count + trail.count),
                                              context: Self.sentenceContext(before))
        else { return false }

        apply(Conversion(original: typed + trail, converted: fixed + trail, from: pair.current, to: nil,
                         automatic: true, scope: .word),
              onScreen: typed.count)
        Log.engine.notice("Corrected spelling in \(pair.current.map.language, privacy: .public), \(word.count) chars")
        return true
    }

    /// A letter was just added to `buffer` and hasn't reached the app yet.
    /// Returns true when the word was converted (the letter is then typed by us).
    private func convertWhileTyping(_ pair: Pair) -> Bool {
        // Past a few letters the end-of-word check is enough, and every letter here costs a dictionary lookup.
        guard autoSwitchAllowed, config.switchWhileTyping, !wordLocked,
              buffer.count >= analyzer.minimumPrefixLength, buffer.count <= 7,
              let typed = pair.current.map.render(buffer),
              // `visible` already ends with the whole word, this letter included: the context is before it.
              // (Counting one letter less would read the word's first letter, "і" or "в", as a word of its own.)
              case let context = languageContext(beforeLast: typed.count),
              case let fitting = candidates(for: buffer, pair, automatic: true).filter({ option in
                  analyzer.shouldConvertPrefix(typed: typed, typedLanguage: option.pair.current.map.language,
                                               alternative: option.text, alternativeLanguage: option.pair.alternative.map.language,
                                               context: context)
              }),
              // Three letters often start words in several languages ("auo…": Greek "αθο…", French "quo…"):
              // switch now only if they all read the same ("при…" in Ukrainian and Russian), else at the word's end.
              let found = fitting.first, fitting.allSatisfy({ $0.text == found.text })
        else { return false }
        let (pair, alternative) = found

        apply(Conversion(original: typed, converted: alternative, from: pair.current,
                         to: pair.alternative, automatic: true, scope: .word),
              onScreen: typed.count - 1)
        wordLocked = true
        convertedMidWord = true
        // The word after "z " turned out Ukrainian: the letter is "я".
        if loneLetter?.language == pair.alternative.map.language {
            settleLoneLetter(afterFixedWord: true, buffer, pair, pendingCharacters: 0)
        }
        Log.engine.notice("Converted while typing \(pair.current.map.language, privacy: .public)→\(pair.alternative.map.language, privacy: .public) after \(self.buffer.count) chars")
        return true
    }

    // MARK: - Hotkeys

    private func perform(_ action: HotkeyAction) {
        Log.engine.notice("Hotkey: \(action.rawValue, privacy: .public)")
        switch action {
        case .convertWord:
            if let fix = recentFix, fix.immediate, !fix.conversion.isFormatting {
                if !cycleToNextLayout(fix) { undo(fix) }
            } else if let fix = undone, fix.conversion.scope == .word {
                redo(fix)
            } else {
                convertWord()
            }
        case .convertText:
            if let fix = recentFix, fix.immediate, fix.conversion.scope == .phrase {
                undo(fix)
            } else if let fix = undone, fix.conversion.scope == .phrase {
                redo(fix)
            } else if visible.count > contextLength {
                convertPhrase()
            } else {
                // Selecting text needs the mouse, arrows or ⌘A, all of which clear what we track.
                reset()
                SelectionConverter.convert(layouts: layouts) { [weak self] in self?.onFix(.layout) }
            }
        case .undo:
            if let fix = recentFix {
                undo(fix)
            } else if let fix = undone {
                redo(fix)
            }
        case .changeCase:
            changeCase()
        case .translate:
            reset()
            onTranslate()
        case .screenText:
            reset()
            onScreenText()
        case .clipboard:
            reset()
            onClipboard()
        case .voice:
            reset()
            onVoice()
        }
    }

    /// малі → Перша велика → ВЕЛИКІ → малі: the word being typed, the word just finished, or the selection.
    private func changeCase() {
        guard let pair = currentPair() else { return }
        if !buffer.isEmpty, visible.count - contextLength >= buffer.count {
            let word = String(visible.suffix(buffer.count))
            let changed = CaseCycle.next(word)
            guard changed != word else { return }
            apply(Conversion(original: word, converted: changed, from: pair.current, to: nil,
                             automatic: false, scope: .word, isFormatting: true),
                  onScreen: word.count)
            // Keystrokes now carry the new Shift state.
            resumeWordBeforeCaret()
        } else if !lastWord.isEmpty, visible.last == " ", visible.count - contextLength >= lastWord.count + 1 {
            let word = String(visible.dropLast().suffix(lastWord.count))
            let changed = CaseCycle.next(word)
            guard changed != word else { return }
            apply(Conversion(original: word + " ", converted: changed + " ", from: pair.current, to: nil,
                             automatic: false, scope: .word, isFormatting: true),
                  onScreen: word.count + 1)
            // Keep it the "word just finished", so the next press goes on cycling.
            let keystrokes = changed.compactMap { pair.current.map.keystroke(for: String($0)) }
            lastWord = keystrokes.count == changed.count ? keystrokes : []
        } else {
            reset()
            SelectionConverter.transform { CaseCycle.next($0) } onDone: { [weak self] in self?.onFix(.formatting) }
        }
    }

    /// ⇧⇧ again right after a layout fix, with more than two layouts: the next likeliest layout instead
    /// ("ghbdsn" → "привіт" → "привыт"); after the last one, the next press goes back to what was typed.
    private func cycleToNextLayout(_ placed: PlacedFix) -> Bool {
        let fix = placed.conversion
        guard fix.kind == .layout, fix.scope == .word, let current = fix.to, placed.end == visible.count,
              fix.original.count == fix.converted.count else { return false }
        let order = LayoutChoice.alternatives(to: fix.from.map, among: layouts.map(\.map), recent: recentLayoutIDs)
        guard let index = order.firstIndex(where: { $0.id == current.map.id }) else { return false }
        for map in order.dropFirst(index + 1) {
            guard let next = layouts.first(where: { $0.map.id == map.id }) else { continue }
            let converted = LayoutConverter.convert(fix.original, from: fix.from.map, to: next.map)
            guard converted.count == fix.converted.count, converted != fix.converted, converted != fix.original else { continue }
            // Moving off an automatic fix says it was wrong, as switching it back by hand does.
            let revertedAt = manualRevertStart(within: fix.converted.count)
            apply(Conversion(original: fix.original, converted: converted, from: fix.from, to: next,
                             automatic: false, scope: .word),
                  onScreen: fix.converted.count)
            // Mid-word the rest of the word is typed in the new layout; a finished word leaves the next one free.
            if !buffer.isEmpty { wordLocked = true }
            reportRevertInWord()
            if revertedAt != nil { reportRevert(of: TextRules.coreWord(converted)) }
            Log.engine.notice("Switched the word on to the next layout: \(next.map.language, privacy: .public)")
            return true
        }
        return false
    }

    private func convertWord() {
        guard var pair = currentPair() else { return }
        pair = likeliestPair(for: buffer.isEmpty ? lastWord : buffer, pair)

        if !buffer.isEmpty {
            // Mid-word: the same keystrokes now render in the new layout, so the buffer stays valid.
            guard let typed = pair.current.map.render(buffer),
                  let alternative = pair.alternative.map.render(buffer) else { return }
            _ = manualRevertStart(within: buffer.count)
            apply(Conversion(original: typed, converted: alternative, from: pair.current,
                             to: pair.alternative, automatic: false, scope: .word),
                  onScreen: typed.count)
            wordLocked = true
            reportRevertInWord()
        } else if !lastWord.isEmpty {
            guard let typed = pair.current.map.render(lastWord),
                  let alternative = pair.alternative.map.render(lastWord) else { return }
            let reverted = manualRevertStart(within: lastWord.count + 1) != nil
            apply(Conversion(original: typed + " ", converted: alternative + " ", from: pair.current,
                             to: pair.alternative, automatic: false, scope: .word),
                  onScreen: typed.count + 1)
            if reverted { reportRevert(of: alternative) }
        }
    }

    /// Everything typed since the caret last jumped, into the other layout.
    private func convertPhrase() {
        guard var pair = currentPair() else { return }
        let text = String(visible[contextLength...])
        if let best = LayoutChoice.best(for: text, from: pair.current.map, among: alternatives.map(\.map),
                                        spellChecker: spellChecker),
           let layout = alternatives.first(where: { $0.map.id == best.id }) {
            pair = (pair.current, layout)
        }
        let converted = LayoutConverter.convert(text, from: pair.current.map, to: pair.alternative.map)
        guard !text.isEmpty, converted != text, converted.count == text.count else { return }
        let revertedAt = manualRevertStart(within: text.count)
        apply(Conversion(original: text, converted: converted, from: pair.current,
                         to: pair.alternative, automatic: false, scope: .phrase),
              onScreen: text.count)
        wordLocked = true
        reportRevertInWord()
        if let revertedAt { reportRevert(of: word(at: revertedAt)) }
    }

    /// The user is about to switch the last `count` characters to the other layout by hand.
    /// If that undoes Klavko's automatic layout fix, it counts as a revert of that word:
    /// for the word still being typed it's reported when the word ends; otherwise this returns
    /// where the word starts, for the caller to report once the switch is on screen.
    private func manualRevertStart(within count: Int) -> Int? {
        guard let fix = recentFix, fix.conversion.automatic, fix.conversion.kind == .layout,
              !fix.conversion.redone, fix.end <= visible.count,
              fix.end - fix.conversion.converted.count >= visible.count - count
        else { return nil }
        let start = fix.end - fix.conversion.converted.count
        recentFix = nil
        if isInCurrentWord(start) {
            revertedInWord = true
            return nil
        }
        return start
    }

    // MARK: - Applying and undoing

    /// `onScreen`: how many characters of `conversion.original` are actually on screen
    /// (a swallowed Space or the key being typed is not yet).
    private func apply(_ conversion: Conversion, onScreen count: Int) {
        TextInjector.replace(deleting: count, with: conversion.converted)
        if replaceVisibleSuffix(conversion.original.count, with: conversion.converted) {
            recentFix = PlacedFix(conversion: conversion, end: visible.count)
        } else {
            recentFix = nil
        }
        if let target = conversion.to { SystemLayouts.select(target.source) }
        undone = nil
        lastWord = []
        onFix(conversion.kind)
    }

    private func undo(_ placed: PlacedFix) {
        let fix = placed.conversion
        let start = placed.end - fix.converted.count
        guard start >= 0, placed.end <= visible.count,
              String(visible[start..<placed.end]) == fix.converted else {
            recentFix = nil
            return
        }
        let reportable = fix.automatic && fix.scope == .word && !fix.redone && !fix.isFormatting
        recentFix = nil

        // A layout fix inside the word still being typed: switch the whole word back
        // (letters typed after the fix are in the new layout too).
        if fix.kind == .layout, !placed.immediate, isInCurrentWord(start),
           let text = fix.from.map.render(buffer) {
            TextInjector.replace(deleting: buffer.count, with: text)
            visible.replaceSubrange((visible.count - buffer.count)..., with: Array(text))
            SystemLayouts.select(fix.from.source)
            if reportable { revertedInWord = true }
            wordLocked = true
            undone = nil
            reportRevertInWord()
            Log.engine.notice("Undid fix in the current word")
            return
        }

        // A layout fix made mid-word ("ghb" -> "при") that the user then finished ("привіт"):
        // the letters typed after it are in the new layout too, so switch the rest of the word back as well.
        var regionEnd = placed.end
        var restored = fix.original
        if fix.kind == .layout, let target = fix.to, fix.converted.last?.isLetter == true {
            while regionEnd < visible.count && (visible[regionEnd].isLetter || visible[regionEnd] == "'") { regionEnd += 1 }
            restored += LayoutConverter.convert(String(visible[placed.end..<regionEnd]), from: target.map, to: fix.from.map)
        }
        let replaced = String(visible[start..<regionEnd])
        let after = String(visible[regionEnd...])
        TextInjector.replace(deleting: visible.count - start, with: restored + after)
        visible.replaceSubrange(start..., with: Array(restored + after))
        // Typing continues in the layout of the text before the caret.
        if fix.kind == .layout && after.isEmpty { SystemLayouts.select(fix.from.source) }

        if reportable {
            if isInCurrentWord(start) {
                revertedInWord = true
            } else {
                reportRevert(of: word(at: start))
            }
        }
        if isInCurrentWord(start) { wordLocked = true }
        reportRevertInWord()
        // Redo swaps the same span back (the whole word, if it was extended above).
        var restoredFix = Conversion(original: restored, converted: replaced, from: fix.from, to: fix.to,
                                     automatic: fix.automatic, scope: fix.scope)
        restoredFix.redone = fix.redone
        restoredFix.isFormatting = fix.isFormatting
        undone = PlacedFix(conversion: restoredFix, end: start + restored.count)
        lastWord = []
        Log.engine.notice("Undid \(fix.automatic ? "automatic" : "manual", privacy: .public) fix, \(after.count) chars after it")
    }

    /// The undo hotkey pressed again: put the fix back.
    private func redo(_ placed: PlacedFix) {
        var fix = placed.conversion
        let start = placed.end - fix.original.count
        guard start >= 0, placed.end <= visible.count,
              String(visible[start..<placed.end]) == fix.original else {
            undone = nil
            return
        }
        fix.redone = true
        let after = String(visible[placed.end...])
        TextInjector.replace(deleting: visible.count - start, with: fix.converted + after)
        visible.replaceSubrange(start..., with: Array(fix.converted + after))
        if let target = fix.to, after.isEmpty { SystemLayouts.select(target.source) }
        recentFix = PlacedFix(conversion: fix, end: start + fix.converted.count, immediate: after.isEmpty)
        undone = nil
        onFix(fix.kind)
        Log.engine.notice("Re-applied fix")
    }

    // MARK: - Bookkeeping

    private func reportRevert(of text: String) {
        let word = TextRules.coreWord(text)
        guard !word.isEmpty, !config.exceptions.contains(word.lowercased()) else { return }
        onRevert(word)
    }

    /// Whether `index` in `visible` falls inside the word still being typed.
    private func isInCurrentWord(_ index: Int) -> Bool {
        !buffer.isEmpty && index >= visible.count - buffer.count
    }

    /// The word in `visible` around `index`.
    private func word(at index: Int) -> String {
        guard index >= 0, index < visible.count else { return "" }
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0 == "'" || $0 == "’" }
        var start = index, end = index
        while start > 0 && isWordCharacter(visible[start - 1]) { start -= 1 }
        while end < visible.count && isWordCharacter(visible[end]) { end += 1 }
        return String(visible[start..<end])
    }

    /// Reports the word under the caret, as it reads now, if its automatic fix was just reverted.
    /// Done right away (not at the end of the word), so the exception offer appears immediately.
    private func reportRevertInWord() {
        guard revertedInWord else { return }
        revertedInWord = false
        if let pair = currentPair(), let typed = pair.current.map.render(buffer) {
            reportRevert(of: typed)
        }
    }

    /// Reads what's before the caret into `visible` as context, so we know whether this is the start
    /// of a sentence and whether the caret sits right after a word (then that word is picked up).
    /// If the app doesn't expose its text, nothing changes (a word after a blind Backspace stays locked).
    private func readContextBeforeCaret() {
        guard let before = CaretContext.textBeforeCaret() else { return }
        visible = Array(before)
        contextLength = visible.count
        atFieldStart = before.isEmpty
        resumeWordBeforeCaret()
    }

    /// After Backspace removed what followed a word, the caret is at that word's end again.
    /// Rebuild its keystrokes from what's on screen so it's tracked like a word being typed;
    /// if they can't be rebuilt (letters from the other layout), leave the word alone.
    private func resumeWordBeforeCaret() {
        endWord()
        let letters = visible.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed()
        guard !letters.isEmpty else { return }
        guard let pair = currentPair() else {
            wordLocked = true
            return
        }
        let keystrokes = letters.compactMap { pair.current.map.keystroke(for: String($0)) }
        if keystrokes.count == letters.count {
            buffer = keystrokes
        } else {
            wordLocked = true
        }
    }

    private func endWord() {
        reportRevertInWord()
        buffer = []
        wordLocked = false
        convertedMidWord = false
        editedByUser = false
    }

    /// The word is locked only by Klavko's own switch while typing: its case may still be fixed.
    private var onlyCaseLeft: Bool { wordLocked && convertedMidWord && !editedByUser }

    /// `fixFinishedWord` for an open word; after Klavko's own switch mid-word, only a stuck Shift.
    private func finishWord(locked: Bool, caseOnly: Bool, _ word: [Keystroke], _ pair: Pair, typedTrail: String,
                            alternativeTrail: (LayoutMap) -> String) -> Bool {
        if !locked { return fixFinishedWord(word, pair, typedTrail: typedTrail, alternativeTrail: alternativeTrail) }
        return caseOnly && fixStuckShift(word, pair, trail: typedTrail)
    }

    /// "ПРивіт" (the layout already switched while typing): "Привіт".
    private func fixStuckShift(_ word: [Keystroke], _ pair: Pair, trail: String) -> Bool {
        guard spellingAllowed, let typed = pair.current.map.render(word) else { return false }
        let fixed = Self.stuckShiftFixed(typed)
        guard fixed != typed else { return false }
        apply(Conversion(original: typed + trail, converted: fixed + trail, from: pair.current, to: nil,
                         automatic: true, scope: .word),
              onScreen: typed.count)
        Log.engine.notice("Fixed a stuck Shift after switching, \(word.count) chars")
        return true
    }

    /// `text` with its word's stuck Shift fixed ("ПРивіт," → "Привіт,"), or as it is.
    private static func stuckShiftFixed(_ text: String) -> String {
        let core = TextRules.coreWord(text)
        guard let fixed = TypoCorrector.stuckShiftFix(core), let range = text.range(of: core) else { return text }
        return text.replacingCharacters(in: range, with: fixed)
    }

    private func appendVisible(_ character: String) {
        guard character.count == 1, let first = character.first, visible.count < maxVisibleLength else {
            visible = []
            contextLength = 0
            recentFix = nil
            undone = nil
            return
        }
        visible.append(first)
    }

    /// Replaces the last `count` characters of `visible`; false (and tracking dropped) if they aren't there.
    @discardableResult
    private func replaceVisibleSuffix(_ count: Int, with text: String) -> Bool {
        guard count <= visible.count else {
            visible = []
            contextLength = 0
            return false
        }
        visible.replaceSubrange((visible.count - count)..., with: Array(text))
        return true
    }

    /// What the text before the last `count` characters says about its language.
    private func languageContext(beforeLast count: Int) -> LanguageContext {
        guard count >= 0, count <= visible.count else { return LanguageContext() }
        let maps = layouts.map(\.map)
        return LanguageContext.of(visible.dropLast(count).suffix(120)) { word in
            if let known = wordLanguages[word] { return known }
            if wordLanguages.count > 500 { wordLanguages.removeAll() }
            let found = LanguageContext.languages(of: word, among: maps, spellChecker: spellChecker)
            wordLanguages[word] = found
            return found
        }
    }

    /// The pair with each alternative layout in turn (likeliest first) and what the keys type in it,
    /// skipping layouts where they type exactly the same (English and German share most keys).
    /// `automatic`: only the layouts Klavko may switch into by itself.
    private func candidates(for word: [Keystroke], _ pair: Pair, automatic: Bool = false) -> [(pair: Pair, text: String)] {
        guard let typed = pair.current.map.render(word) else { return [] }
        return (automatic ? automaticAlternatives : alternatives).compactMap { layout in
            guard let text = layout.map.render(word), text != typed else { return nil }
            return ((pair.current, layout), text)
        }
    }

    /// For a switch by hand: the alternative in which the keys spell a real word (or start one),
    /// else the likeliest alternative.
    private func likeliestPair(for word: [Keystroke], _ pair: Pair) -> Pair {
        let options = candidates(for: word, pair)
        func real(_ text: String, _ language: String) -> Bool {
            let core = TextRules.coreWord(text)
            return !core.isEmpty && spellChecker.isValid(core, language: language)
        }
        func started(_ text: String, _ language: String) -> Bool {
            let core = TextRules.coreWord(text).lowercased()
            return !core.isEmpty && spellChecker.hasCompletions(core, language: language)
        }
        return options.first { real($0.text, $0.pair.alternative.map.language) }?.pair
            ?? options.first { started($0.text, $0.pair.alternative.map.language) }?.pair
            ?? options.first?.pair
            ?? pair
    }

    /// What's on screen before the last `count` characters (empty if unknown).
    private func visibleText(beforeLast count: Int) -> String {
        guard count <= visible.count else { return "" }
        return String(visible.dropLast(count))
    }

    private static let addressCharacters = Set("@/\\:_#=<>{}[]`~|$%&*+")

    /// "user@mail", "http://site", "file_name", "a=b": not prose, don't correct spelling there.
    /// True when the word is glued to such characters or one of them ends it.
    private static func looksLikeAddressOrCode(before: String, trail: String) -> Bool {
        if trail.contains(where: addressCharacters.contains) { return true }
        let glued = before.reversed().prefix { !$0.isWhitespace }
        return glued.contains(where: { addressCharacters.contains($0) || $0 == "." })
    }

    /// The current sentence before the word, as context for suggestions (at most ~80 characters).
    private static func sentenceContext(_ before: String) -> String {
        let tail = before.suffix(80)
        if let end = tail.lastIndex(where: { ".!?\n".contains($0) }) {
            return String(tail[tail.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        return String(tail).trimmingCharacters(in: .whitespaces)
    }

    /// True when nothing but sentence-ending punctuation precedes the last `count` visible characters,
    /// so a capitalized word there is just the start of a sentence, not a name.
    private func isSentenceStart(beforeLast count: Int) -> Bool {
        guard count <= visible.count else { return true }
        let before = visible.dropLast(count).reversed().drop { $0 == " " }
        guard let previous = before.first else { return true }
        return ".!?…\n".contains(previous)
    }

    /// The active layout and the likeliest one to convert into; also sets `alternatives`.
    private func currentPair() -> Pair? {
        guard let currentID = SystemLayouts.currentLayoutID() else { return nil }
        let current = layouts.first(where: { $0.map.id == currentID })
        alternatives = current.map { current in
            LayoutChoice.alternatives(to: current.map, among: layouts.map(\.map), recent: recentLayoutIDs)
                .compactMap { map in layouts.first { $0.map.id == map.id } }
        } ?? []
        guard let current, let alternative = alternatives.first else {
            if lastMissingLayoutID != currentID {
                lastMissingLayoutID = currentID
                Log.engine.notice("No second layout for current layout \(currentID, privacy: .public)")
            }
            return nil
        }
        lastMissingLayoutID = nil
        return (current, alternative)
    }
}
