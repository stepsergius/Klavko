import XCTest
@testable import KlavkoCore

final class TextRulesTests: XCTestCase {
    func testCoreWordTrimsPunctuationAndNormalizesApostrophe() {
        XCTAssertEqual(TextRules.coreWord("привіт."), "привіт")
        XCTAssertEqual(TextRules.coreWord("«слово»,"), "слово")
        XCTAssertEqual(TextRules.coreWord("м’ята"), "м'ята")
        XCTAssertEqual(TextRules.coreWord(",./"), "")
    }
}

final class WordAnalyzerTests: XCTestCase {
    let analyzer = WordAnalyzer(spellChecker: MacSpellChecker())

    func testConvertsEnglishGibberishToUkrainian() {
        XCTAssertTrue(analyzer.shouldConvert(typed: "ghbdsn", typedLanguage: "en",
                                             alternative: "привіт", alternativeLanguage: "uk"))
    }

    func testConvertsUkrainianGibberishToEnglish() {
        XCTAssertTrue(analyzer.shouldConvert(typed: "руддщ", typedLanguage: "uk",
                                             alternative: "hello", alternativeLanguage: "en"))
    }

    func testKeepsValidWords() {
        XCTAssertFalse(analyzer.shouldConvert(typed: "hello", typedLanguage: "en",
                                              alternative: "руддщ", alternativeLanguage: "uk"))
        XCTAssertFalse(analyzer.shouldConvert(typed: "м'ята", typedLanguage: "uk",
                                              alternative: "v'znf", alternativeLanguage: "en"))
    }

    func testSkipsWordsWithDigitsAndIgnoredWords() {
        XCTAssertFalse(analyzer.shouldConvert(typed: "ghbdsn1", typedLanguage: "en",
                                              alternative: "привіт1", alternativeLanguage: "uk"))
        var ignoring = analyzer
        ignoring.exceptions = ["ghbdsn"]
        XCTAssertFalse(ignoring.shouldConvert(typed: "ghbdsn", typedLanguage: "en",
                                              alternative: "привіт", alternativeLanguage: "uk"))
    }
}

/// Uses the layouts enabled on this Mac; skipped when ABC/Ukrainian are missing.
final class SystemLayoutsTests: XCTestCase {
    func testRendersSameKeystrokesInBothLayouts() throws {
        let layouts = SystemLayouts.enabledLayouts().map(\.map)
        let english = try XCTUnwrap(layouts.first { $0.language == "en" }, "No English layout enabled")
        let ukrainian = try XCTUnwrap(layouts.first { $0.language == "uk" }, "No Ukrainian layout enabled")

        // Physical keys G H B D S N on an ANSI keyboard.
        let keystrokes = [5, 4, 11, 2, 1, 45].map { Keystroke(keyCode: UInt16($0)) }
        XCTAssertEqual(english.render(keystrokes), "ghbdsn")
        XCTAssertEqual(ukrainian.render(keystrokes), "привіт")

        let shifted = Keystroke(keyCode: 5, shift: true)
        XCTAssertEqual(english.character(for: shifted), "G")
        XCTAssertEqual(ukrainian.character(for: shifted), "П")
    }

    func testConvertsSelectedTextBothWays() throws {
        // Only English and Ukrainian: with more layouts enabled, a tie would depend on the order macOS lists them in.
        let layouts = SystemLayouts.enabledLayouts().map(\.map).filter { ["en", "uk"].contains($0.language) }
        let english = try XCTUnwrap(layouts.first { $0.language == "en" })
        let ukrainian = try XCTUnwrap(layouts.first { $0.language == "uk" })

        XCTAssertEqual(LayoutConverter.sourceLayout(of: "Ghbdsn cdsn", among: layouts)?.language, "en")
        XCTAssertEqual(LayoutConverter.convert("Ghbdsn cdsn", from: english, to: ukrainian), "Привіт світ")
        XCTAssertEqual(LayoutConverter.sourceLayout(of: "Руддщ 123", among: layouts)?.language, "uk")
        XCTAssertEqual(LayoutConverter.convert("Руддщ 123", from: ukrainian, to: english), "Hello 123")
        XCTAssertNil(LayoutConverter.sourceLayout(of: "123 !", among: layouts))
    }
}

final class PrefixAnalyzerTests: XCTestCase {
    let analyzer = WordAnalyzer(spellChecker: MacSpellChecker())

    func testSwitchesWhileTypingWhenOnlyTheOtherLayoutHasSuchWords() {
        XCTAssertTrue(analyzer.shouldConvertPrefix(typed: "ghb", typedLanguage: "en",
                                                   alternative: "при", alternativeLanguage: "uk"))
        XCTAssertTrue(analyzer.shouldConvertPrefix(typed: "рудд", typedLanguage: "uk",
                                                   alternative: "hell", alternativeLanguage: "en"))
    }

    func testDoesNotSwitchPlausiblePrefixes() {
        // "руд" starts real Ukrainian words (руда, рудий).
        XCTAssertFalse(analyzer.shouldConvertPrefix(typed: "руд", typedLanguage: "uk",
                                                    alternative: "hel", alternativeLanguage: "en"))
        XCTAssertFalse(analyzer.shouldConvertPrefix(typed: "the", typedLanguage: "en",
                                                    alternative: "еру", alternativeLanguage: "uk"))
        // Too short to tell.
        XCTAssertFalse(analyzer.shouldConvertPrefix(typed: "gh", typedLanguage: "en",
                                                    alternative: "пр", alternativeLanguage: "uk"))
    }

    func testRespectsExceptionsWhileTyping() {
        // "ghb" could still grow into the exception "ghbdsn", so wait for the whole word.
        var ignoring = analyzer
        ignoring.exceptions = ["ghbdsn"]
        XCTAssertFalse(ignoring.shouldConvertPrefix(typed: "ghb", typedLanguage: "en",
                                                    alternative: "при", alternativeLanguage: "uk"))
    }
}

final class AbbreviationTests: XCTestCase {
    func testSkipsAllCapsWordsUnlessEnabled() {
        var analyzer = WordAnalyzer(spellChecker: MacSpellChecker())
        XCTAssertTrue(TextRules.isAllCaps("ЗСУ"))
        XCTAssertFalse(TextRules.isAllCaps("Привіт"))
        XCTAssertFalse(TextRules.isAllCaps("A"))
        XCTAssertFalse(analyzer.shouldConvert(typed: "GHBDSN", typedLanguage: "en",
                                              alternative: "ПРИВІТ", alternativeLanguage: "uk"))
        XCTAssertFalse(analyzer.shouldConvertPrefix(typed: "GHB", typedLanguage: "en",
                                                    alternative: "ПРИ", alternativeLanguage: "uk"))
        analyzer.convertAbbreviations = true
        XCTAssertTrue(analyzer.shouldConvert(typed: "GHBDSN", typedLanguage: "en",
                                             alternative: "ПРИВІТ", alternativeLanguage: "uk"))
    }
}

final class ShortcutTests: XCTestCase {
    func testComboMatchingIgnoresModifierOrder() {
        let shortcut = Shortcut(keyCode: 49, modifiers: [.shift, .control])
        XCTAssertTrue(shortcut.matches(keyCode: 49, modifiers: [.control, .shift]))
        XCTAssertFalse(shortcut.matches(keyCode: 49, modifiers: [.control]))
        XCTAssertEqual(shortcut.displayName(layout: nil), "⌃⇧Space")
    }

    func testModifierTapShortcuts() {
        let chord = Shortcut(modifiers: [.command, .option], double: false)
        XCTAssertTrue(chord.matches(.single([.option, .command])))
        XCTAssertFalse(chord.matches(.double([.option, .command])))
        XCTAssertEqual(chord.displayName(layout: nil), "⌥⌘")
        XCTAssertEqual(Shortcut(modifiers: [.shift], double: true).displayName(layout: nil), "⇧⇧")
        AppLanguage.current = .ukrainian
        XCTAssertEqual(Shortcut(modifiers: [.option, .command], double: true).parts(layout: nil), ["двічі", "⌥", "⌘"])
        AppLanguage.current = .english
        XCTAssertEqual(Shortcut(modifiers: [.option, .command], double: true).parts(layout: nil), ["twice", "⌥", "⌘"])
        AppLanguage.current = .ukrainian
    }

    func testShortcutsSurviveJSONRoundTrip() throws {
        let stored: [String: Shortcut?] = ["a": Shortcut(modifiers: [.option], double: true),
                                           "b": Shortcut(keyCode: 6, modifiers: [.command]), "c": nil]
        let decoded = try JSONDecoder().decode([String: Shortcut?].self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(decoded, stored)
    }

    func testShortcutsSavedBeforeSidesStillLoad() throws {
        let old = #"{"voice":{"modifierTap":{"modifiers":["option"],"double":false}},"#
            + #""clipboard":{"combo":{"keyCode":9,"modifiers":["option","command"]}}}"#
        let decoded = try JSONDecoder().decode([String: Shortcut?].self, from: Data(old.utf8))
        XCTAssertEqual(decoded["voice"], Shortcut(modifiers: [.option], double: false))
        XCTAssertEqual(decoded["clipboard"], Shortcut(keyCode: 9, modifiers: [.option, .command]))
        let right = Shortcut(modifiers: [.option], double: false, sides: [.option: .right])
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(right)), right)
    }

    func testSidesFromEventFlags() {
        // Right ⌥ (0x40) with left ⌘ (0x08), plus the device-independent bits.
        XCTAssertEqual(ModifierSide.held(in: 0x0010_0000 | 0x0008_0000 | 0x40 | 0x08),
                       [.option: [.right], .command: [.left]])
    }

    func testASidedShortcutFiresOnlyFromThatKey() {
        let right = Shortcut(modifiers: [.option], double: false, sides: [.option: .right])
        XCTAssertTrue(right.matches(.single([.option], sides: [.option: [.right]])))
        XCTAssertFalse(right.matches(.single([.option], sides: [.option: [.left]])))
        XCTAssertFalse(right.matches(.single([.option])))
        // Without a side, either key works, as before.
        XCTAssertTrue(Shortcut(modifiers: [.option], double: false).matches(.single([.option], sides: [.option: [.left]])))
        let combo = Shortcut(keyCode: 9, modifiers: [.command], sides: [.command: .left])
        XCTAssertTrue(combo.matches(keyCode: 9, modifiers: [.command], held: [.command: [.left]]))
        XCTAssertFalse(combo.matches(keyCode: 9, modifiers: [.command], held: [.command: [.right]]))
        AppLanguage.current = .english
        XCTAssertEqual(right.parts(layout: nil), ["right ⌥"])
        AppLanguage.current = .ukrainian
    }

    func testRecordedSidesKeepOnlyOneSidedModifiers() {
        XCTAssertEqual(Shortcut.sides([.command: [.right], .shift: [.left, .right]]), [.command: .right])
        // A side for a modifier the shortcut doesn't use is dropped.
        XCTAssertEqual(Shortcut(modifiers: [.command], double: false, sides: [.option: .left]),
                       Shortcut(modifiers: [.command], double: false))
    }
}

final class ModifierTapDetectorTests: XCTestCase {
    /// Presses the modifiers one after another, then releases them all.
    private func tap(_ detector: inout ModifierTapDetector, _ keys: [ModifierKey], at time: TimeInterval) -> [ModifierTap] {
        var held: Set<ModifierKey> = []
        for (index, key) in keys.enumerated() {
            held.insert(key)
            _ = detector.modifiersChanged(held, at: time + Double(index) * 0.02)
        }
        return detector.modifiersChanged([], at: time + 0.1)
    }

    func testDetectsQuickDoubleTap() {
        var detector = ModifierTapDetector()
        XCTAssertEqual(tap(&detector, [.shift], at: 0), [.single([.shift])])
        XCTAssertEqual(tap(&detector, [.shift], at: 0.3), [.single([.shift]), .double([.shift])])
    }

    func testDetectsChordOfSeveralModifiers() {
        var detector = ModifierTapDetector()
        XCTAssertEqual(tap(&detector, [.command, .option], at: 0), [.single([.command, .option])])
    }

    func testIgnoresSlowTapsAndTapsInterruptedByTyping() {
        var slow = ModifierTapDetector()
        _ = tap(&slow, [.shift], at: 0)
        XCTAssertEqual(tap(&slow, [.shift], at: 2), [.single([.shift])])

        var typing = ModifierTapDetector()
        _ = typing.modifiersChanged([.shift], at: 0)
        typing.interrupt() // a capital letter typed while Shift is held
        XCTAssertEqual(typing.modifiersChanged([], at: 0.1), [])
    }

    func testDifferentChordsDoNotCombine() {
        var detector = ModifierTapDetector()
        _ = tap(&detector, [.shift], at: 0)
        XCTAssertEqual(tap(&detector, [.option], at: 0.2), [.single([.option])])
    }

    func testADoubleTapKeepsOnlyTheSidePressedBothTimes() {
        var detector = ModifierTapDetector()
        XCTAssertEqual(detector.modifiersChanged([.command], sides: [.command: [.left]], at: 0), [])
        XCTAssertEqual(detector.modifiersChanged([], at: 0.1), [.single([.command], sides: [.command: [.left]])])
        XCTAssertEqual(detector.modifiersChanged([.command], sides: [.command: [.right]], at: 0.2), [])
        XCTAssertEqual(detector.modifiersChanged([], at: 0.3), [.single([.command], sides: [.command: [.right]]),
                                                                 .double([.command], sides: [:])])
    }

    func testLeftAndRightCommandAloneAreTwoShortcuts() {
        let left = Shortcut(modifiers: [.command], double: false, sides: [.command: .left])
        let right = Shortcut(modifiers: [.command], double: false, sides: [.command: .right])
        var detector = ModifierTapDetector()
        _ = detector.modifiersChanged([.command], sides: [.command: [.right]], at: 0)
        let taps = detector.modifiersChanged([], at: 0.1)
        XCTAssertTrue(taps.contains(where: right.matches))
        XCTAssertFalse(taps.contains(where: left.matches))
        XCTAssertEqual(right.parts(layout: nil), [tr("правий ", "right ") + "⌘"])
    }
}

/// A tiny dictionary with known word frequencies, to test ranking and confidence rules exactly.
private final class FakeSpellChecker: SpellChecking {
    /// Words, most common first.
    let words: [String]
    /// Valid but too rare to show up in completions.
    var rare: Set<String> = []
    var systemFix: [String: String] = [:]

    init(_ words: [String], rare: Set<String> = []) {
        self.words = words + rare
        self.rare = rare
    }

    func isValid(_ word: String, language: String) -> Bool { words.contains(word.lowercased()) }
    func hasCompletions(_ prefix: String, language: String) -> Bool { !completions(for: prefix, language: language).isEmpty }
    func completions(for prefix: String, language: String) -> [String] {
        words.filter { $0.hasPrefix(prefix) && !rare.contains($0) }
    }
    func correction(for word: String, language: String, context: String) -> String? { systemFix[word] }
    func guesses(for word: String, language: String, context: String) -> [String] { [] }
    func validWords(among candidates: [String], language: String) -> Set<String> { Set(candidates.filter(words.contains)) }
}

final class TypoRankingTests: XCTestCase {
    private func fix(_ word: String, _ checker: FakeSpellChecker, capitalized: Bool = true) -> String? {
        TypoCorrector(spellChecker: checker).correction(for: word, language: "uk", layout: nil, allowCapitalized: capitalized)
    }

    func testFindsWordWithMissingLetterEvenWithoutSystemSuggestions() {
        XCTAssertEqual(fix("дкую", FakeSpellChecker(["дякую"])), "дякую")
        XCTAssertEqual(fix("робта", FakeSpellChecker(["робота"])), "робота")
    }

    func testCommonWordBeatsRareOneAtTheSameDistance() {
        // "робота" (letter missing) vs "рота" (letter extra): frequency decides.
        // Fillers push "рота" down the completion lists without being near "робта" themselves.
        let fillers = (1...15).flatMap { ["розмова\($0)", "ротонда\($0)"] }
        let common = ["робота"] + fillers + ["рота"]
        XCTAssertEqual(fix("робта", FakeSpellChecker(common)), "робота")
    }

    func testLeavesAmbiguousWordsAlone() {
        // Two equally common words, each one missing letter away.
        let checker = FakeSpellChecker(["мовою", "мовлю"])
        XCTAssertNil(fix("мовю", checker))
    }

    func testLeavesWordsWithoutFrequencyOrContextAlone() {
        // A rare dictionary word one letter away: found, but nothing says the user meant it.
        let checker = FakeSpellChecker([], rare: ["абвгд"])
        let corrector = TypoCorrector(spellChecker: checker)
        XCTAssertEqual(corrector.rankedCandidates(for: "абгд", language: "uk", layout: nil).first?.word, "абвгд")
        XCTAssertNil(fix("абгд", checker))
        // The same word suggested by the system for this sentence is enough.
        checker.systemFix = ["абгд": "абвгд"]
        XCTAssertEqual(fix("абгд", checker), "абвгд")
    }

    func testNeverChangesValidWords() {
        // "людна" is a word; "людина" (one letter more) is more common but must not replace it.
        XCTAssertNil(fix("людна", FakeSpellChecker(["людина", "людна"])))
    }

    func testRespectsCaseNamesAndExceptions() {
        let checker = FakeSpellChecker(["привіт"])
        XCTAssertEqual(fix("Привт", checker), "Привіт")
        XCTAssertNil(fix("Привт", checker, capitalized: false), "capitalized mid-sentence: maybe a name")
        XCTAssertNil(fix("ПРИВТ", checker), "all caps: an abbreviation")
        XCTAssertNil(fix("прuвт", checker), "Latin and Cyrillic mixed")
        XCTAssertNil(fix("привт2", checker), "digits")
        var withException = TypoCorrector(spellChecker: checker)
        withException.exceptions = ["привт"]
        XCTAssertNil(withException.correction(for: "привт", language: "uk", layout: nil, allowCapitalized: true))
    }

    func testKeepsSurroundingPunctuation() {
        XCTAssertEqual(fix("«привт»", FakeSpellChecker(["привіт"])), "«привіт»")
    }

    func testSingleEditsIncludeEveryMissingLetter() {
        let edits = TypoCorrector.singleEdits(of: "дкую", alphabet: Array("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'"))
        XCTAssertTrue(edits.contains("дякую"))
        XCTAssertFalse(edits.contains("'дкую"), "no apostrophe at the edges")
        XCTAssertFalse(edits.contains("дкую"))
    }
}

/// The same rules against the real macOS dictionaries.
final class TypoCorrectorTests: XCTestCase {
    let corrector = TypoCorrector(spellChecker: MacSpellChecker())
    lazy var layouts = SystemLayouts.enabledLayouts().map(\.map)

    private func fix(_ word: String, _ language: String, capitalized: Bool = true, context: String = "") -> String? {
        corrector.correction(for: word, language: language, layout: layouts.first { $0.language == language },
                             allowCapitalized: capitalized, context: context)
    }

    func testFixesMissingLetters() {
        let cases = ["привт": "привіт", "дкую": "дякую", "робта": "робота", "сьогоні": "сьогодні",
                     "написв": "написав", "питаня": "питання", "звичйно": "звичайно", "прогрма": "програма",
                     "потрібо": "потрібно", "дбре": "добре", "слво": "слово", "говрити": "говорити",
                     "прцює": "працює", "помика": "помилка", "текс": "текст", "вчра": "вчора",
                     "клавітура": "клавіатура", "Привт": "Привіт"]
        for (typed, expected) in cases {
            XCTAssertEqual(fix(typed, "uk"), expected, typed)
        }
        XCTAssertEqual(fix("becuase", "en"), "because")
    }

    func testFixesOtherSlips() {
        XCTAssertEqual(fix("рлбиш", "uk", context: "що ти тут"), "робиш", "л is next to о, у is far")
        XCTAssertEqual(fix("recieve", "en"), "receive")
        XCTAssertEqual(fix("wrok", "en"), "work")
        XCTAssertEqual(fix("definately", "en"), "definitely")
    }

    func testFixesStuckShift() {
        XCTAssertEqual(fix("ПРивіт", "uk"), "Привіт")
        XCTAssertEqual(fix("ПРивт", "uk"), "Привіт")
        XCTAssertEqual(fix("HEllo", "en"), "Hello")
        XCTAssertNil(TypoCorrector.stuckShiftFix("SQLite"), "three capitals: a name, not a slip")
        XCTAssertNil(TypoCorrector.stuckShiftFix("IDs"))
    }

    func testLeavesCorrectWordsAlone() {
        // Each is one letter away from a more common word (людина, піти→іти, сама, зроби, from).
        for word in ["людна", "пишу", "мама", "зробиш", "піти", "Сергій", "Київ"] {
            XCTAssertNil(fix(word, "uk"), word)
        }
        for word in ["cat", "form", "teh"] {
            XCTAssertNil(fix(word, "en"), word)
        }
    }

    func testLeavesAmbiguousWordsAlone() {
        XCTAssertNil(fix("хочш", "uk"), "хочеш, хоч or хочу")
        XCTAssertNil(fix("мовю", "uk"), "мовою, мою or мову")
        XCTAssertNil(fix("helo", "en"), "help or hello")
        XCTAssertNil(fix("tset", "en"), "test or set")
        XCTAssertNil(fix("украна", "uk"), "no confident lowercase candidate")
    }

    func testLeavesShortAndUnsafeWordsAlone() {
        XCTAssertNil(fix("npm", "en"), "too short")
        XCTAssertNil(fix("ПРТВІТ", "uk"), "all caps")
        XCTAssertNil(fix("Пртвіт", "uk", capitalized: false), "capitalized mid-sentence: maybe a name")
    }

    func testSlipDistancePrefersMissingLetters() {
        let ukrainian = layouts.first { $0.language == "uk" }
        let missing = TypoCorrector.slipDistance(typed: "сьогоні", intended: "сьогодні", layout: ukrainian)
        let neighbour = TypoCorrector.slipDistance(typed: "сьогоні", intended: "стогоні", layout: ukrainian)
        XCTAssertLessThan(missing, neighbour)
        let english = layouts.first { $0.language == "en" }
        XCTAssertEqual(TypoCorrector.slipDistance(typed: "helo", intended: "hello", layout: english), 0.5, accuracy: 0.001)
        XCTAssertEqual(TypoCorrector.slipDistance(typed: "wrok", intended: "work", layout: english), 0.7, accuracy: 0.001)
    }
}

final class ShortWordTests: XCTestCase {
    let analyzer = WordAnalyzer(spellChecker: MacSpellChecker())
    lazy var layouts = SystemLayouts.enabledLayouts().map(\.map)

    /// Types `word` as if in the other layout and asks whether Klavko would switch it back.
    private func switches(_ word: String, from language: String, context: String? = nil) -> Bool {
        let intended = layouts.first { $0.language == language }!
        let other = layouts.first { $0.language != language }!
        let typed = LayoutConverter.convert(word, from: intended, to: other)
        return analyzer.shouldConvert(typed: typed, typedLanguage: other.language,
                                      alternative: word, alternativeLanguage: language, context: LanguageContext(context))
    }

    func testSwitchesCommonTwoLetterWords() {
        // ye, ot, jq, wt, db, pf: some are "valid" English, none is a common English word.
        for word in ["ну", "ще", "ой", "це", "ви", "за", "як", "та", "не", "що"] {
            XCTAssertTrue(switches(word, from: "uk"), word)
        }
        XCTAssertTrue(switches("the", from: "en", context: "en"))
    }

    func testKeepsCommonWordsOfTheTypedLanguage() {
        // Typed on purpose: their other-layout versions aren't common words.
        for typed in ["we", "to", "is", "it", "on", "at", "no", "me", "ok", "a"] {
            let english = layouts.first { $0.language == "en" }!
            let ukrainian = layouts.first { $0.language == "uk" }!
            let alternative = LayoutConverter.convert(typed, from: english, to: ukrainian)
            XCTAssertFalse(analyzer.shouldConvert(typed: typed, typedLanguage: "en",
                                                  alternative: alternative, alternativeLanguage: "uk",
                                                  context: LanguageContext("uk")), typed)
        }
    }

    func testSingleLettersNeedContext() {
        XCTAssertFalse(switches("я", from: "uk"))
        XCTAssertTrue(switches("я", from: "uk", context: "uk"))
        XCTAssertTrue(switches("і", from: "uk", context: "uk"))
        XCTAssertTrue(switches("є", from: "uk", context: "uk"))
    }

    func testRussianEBecomesUkrainianYeInUkrainianText() {
        // "э" typed in the Russian layout, alone, after Ukrainian text: it is the Ukrainian "є" ("це є правда").
        XCTAssertTrue(ShortWords.isCommon("є", language: "uk"))
        XCTAssertTrue(ShortWords.isLoneLetterCandidate(typed: "э", typedLanguage: "ru", alternative: "є", alternativeLanguage: "uk"))
        XCTAssertTrue(analyzer.shouldConvert(typed: "э", typedLanguage: "ru", alternative: "є", alternativeLanguage: "uk",
                                             context: LanguageContext("uk"), sameScript: true))
        // After Russian text it stays.
        XCTAssertFalse(analyzer.shouldConvert(typed: "э", typedLanguage: "ru", alternative: "є", alternativeLanguage: "uk",
                                              context: LanguageContext("ru"), sameScript: true))
    }

    func testLoneLetterCandidates() {
        // z = я, s = і, d = в, p = з: wait for the next word.
        for (typed, letter) in [("z", "я"), ("s", "і"), ("d", "в"), ("p", "з"), ("e", "у")] {
            XCTAssertTrue(ShortWords.isLoneLetterCandidate(typed: typed, typedLanguage: "en",
                                                           alternative: letter, alternativeLanguage: "uk"), typed)
        }
        // "a" and "I" are English words; "ф" and "ш" aren't Ukrainian ones.
        XCTAssertFalse(ShortWords.isLoneLetterCandidate(typed: "a", typedLanguage: "en", alternative: "ф", alternativeLanguage: "uk"))
        XCTAssertFalse(ShortWords.isLoneLetterCandidate(typed: "я", typedLanguage: "uk", alternative: "z", alternativeLanguage: "en"))
    }

    func testNoCommonWordIsAnotherLanguagesCommonWordInDisguise() {
        let english = layouts.first { $0.language == "en" }!
        let ukrainian = layouts.first { $0.language == "uk" }!
        for word in ShortWords.common["uk"]! where word.count >= 2 {
            let typed = LayoutConverter.convert(word, from: ukrainian, to: english)
            XCTAssertFalse(ShortWords.isCommon(typed, language: "en"), "\(word) = \(typed)")
        }
        for word in ShortWords.common["en"]! where word.count >= 2 {
            let typed = LayoutConverter.convert(word, from: english, to: ukrainian)
            XCTAssertFalse(ShortWords.isCommon(typed, language: "uk"), "\(word) = \(typed)")
        }
    }
}

final class SpacingTests: XCTestCase {
    private func spaced(_ before: String, _ next: Character) -> Bool { Spacing.needsSpace(before: before, next: next) }

    func testAddsForgottenSpace() {
        XCTAssertTrue(spaced("Привіт,", "я"))
        XCTAssertTrue(spaced("Увага:", "т"))
        XCTAssertTrue(spaced("Так;", "н"))
        XCTAssertTrue(spaced("Що?", "Н"))
        XCTAssertTrue(spaced("Ого!?", "т"))
        XCTAssertTrue(spaced("Ну…", "д"))
        XCTAssertTrue(spaced("Так.", "Н"), "a full stop before a capital")
        XCTAssertTrue(spaced("Чекай...", "Я"))
        XCTAssertTrue(spaced("так —", "н"), "a dash set off by a space")
        XCTAssertTrue(spaced("«Так»,", "с"), "after a closing quote")
        XCTAssertTrue(spaced("Hello,", "w"))
    }

    func testLeavesOtherTextAlone() {
        XCTAssertFalse(spaced("google.", "c"), "domain")
        XCTAssertFalse(spaced("file.", "t"), "file name")
        XCTAssertFalse(spaced("т.", "д"), "abbreviation")
        XCTAssertFalse(spaced("U.S.", "A"), "initials")
        XCTAssertFalse(spaced("3,", "5"), "a number, not a letter")
        XCTAssertFalse(spaced("10:", "3"), "time")
        XCTAssertFalse(spaced("https:", "a"), "address scheme")
        XCTAssertFalse(spaced("user_name,", "a"), "code")
        XCTAssertFalse(spaced("привіт :", "D"), "emoticon")
        XCTAssertFalse(spaced("будь-", "я"), "hyphen")
        XCTAssertFalse(spaced("(", "т"), "bracket")
        XCTAssertFalse(spaced("«", "т"), "quote")
        XCTAssertFalse(spaced("Привіт,", "1"), "digits after")
        XCTAssertFalse(spaced("", "т"))
    }
}

final class VocativeTests: XCTestCase {
    let corrector = TypoCorrector(spellChecker: MacSpellChecker())
    lazy var ukrainian = SystemLayouts.enabledLayouts().map(\.map).first { $0.language == "uk" }

    private func fix(_ word: String) -> String? {
        corrector.correction(for: word, language: "uk", layout: ukrainian, allowCapitalized: true)
    }

    func testKeepsNamesInTheVocative() {
        // "Валентине" isn't in the macOS dictionary; it used to become "Валентина".
        for name in ["Валентине", "Іване", "Олеже", "Сергію", "Миколо", "Маріє", "Петре", "Василю", "Ігорю"] {
            XCTAssertNil(fix(name), name)
        }
        XCTAssertEqual(fix("ВАлентине"), "Валентине", "stuck Shift fixed, vocative kept")
    }

    func testVocativeBases() {
        XCTAssertTrue(UkrainianForms.vocativeBases(of: "Валентине").contains("Валентин"))
        XCTAssertTrue(UkrainianForms.vocativeBases(of: "Олеже").contains("Олег"))
        XCTAssertTrue(UkrainianForms.vocativeBases(of: "Сергію").contains("Сергій"))
        XCTAssertTrue(UkrainianForms.vocativeBases(of: "Миколо").contains("Микола"))
    }

    func testStillFixesRealTypos() {
        XCTAssertEqual(fix("Привт"), "Привіт")
        XCTAssertEqual(fix("сьогоні"), "сьогодні")
    }
}

final class TextFormattingTests: XCTestCase {
    func testCapitalizesSentenceStarts() {
        XCTAssertTrue(Capitalization.startsSentence(before: "Так. ", atFieldStart: false))
        XCTAssertTrue(Capitalization.startsSentence(before: "Що? ", atFieldStart: false))
        XCTAssertTrue(Capitalization.startsSentence(before: "Ура! ", atFieldStart: false))
        XCTAssertTrue(Capitalization.startsSentence(before: "рядок\n", atFieldStart: false))
        XCTAssertTrue(Capitalization.startsSentence(before: "", atFieldStart: true))
        XCTAssertTrue(Capitalization.startsSentence(before: "1. ", atFieldStart: false), "numbered item")
        XCTAssertFalse(Capitalization.startsSentence(before: "\n2) ", atFieldStart: false), "after a bracket")
        XCTAssertFalse(Capitalization.startsSentence(before: "(так) ", atFieldStart: false), "after a bracket")
    }

    func testLeavesOtherPlacesLowercase() {
        XCTAssertFalse(Capitalization.startsSentence(before: "", atFieldStart: false), "unknown start")
        XCTAssertFalse(Capitalization.startsSentence(before: "так, ", atFieldStart: false))
        XCTAssertFalse(Capitalization.startsSentence(before: "і т.д. ", atFieldStart: false), "abbreviation")
        XCTAssertFalse(Capitalization.startsSentence(before: "див. ", atFieldStart: false))
        XCTAssertFalse(Capitalization.startsSentence(before: "e.g. ", atFieldStart: false))
        XCTAssertFalse(Capitalization.startsSentence(before: "Т. ", atFieldStart: false), "initial")
        XCTAssertFalse(Capitalization.startsSentence(before: "ну... ", atFieldStart: false), "ellipsis")
        XCTAssertFalse(Capitalization.startsSentence(before: "google.", atFieldStart: false), "no space")
    }

    func testImmediateTypography() {
        XCTAssertEqual(Typography.immediateMatch(in: "Ну...", rules: Typography.builtIn)?.to, "…")
        XCTAssertEqual(Typography.immediateMatch(in: "Klavko (c)", rules: Typography.builtIn)?.to, "©")
        XCTAssertEqual(Typography.immediateMatch(in: "(tm)", rules: Typography.builtIn)?.to, "™")
        XCTAssertNil(Typography.immediateMatch(in: "func(c)", rules: Typography.builtIn), "code")
        XCTAssertNil(Typography.immediateMatch(in: "a..", rules: Typography.builtIn))
    }

    func testCustomReplacements() {
        let rules = [Replacement(from: "сп", to: "спасибі"), Replacement(from: ":)", to: "🙂")]
        XCTAssertEqual(Typography.wordMatch("сп", rules: rules)?.to, "спасибі")
        XCTAssertNil(Typography.wordMatch("спати", rules: rules))
        XCTAssertEqual(Typography.wordMatch("Сп", rules: rules)?.to, "спасибі", "any letter case")
        XCTAssertEqual(Typography.immediateMatch(in: "ок :)", rules: rules)?.to, "🙂")
    }

    func testQuotesAndDashes() {
        XCTAssertEqual(Typography.quote(after: "він сказав ", language: "uk"), "«")
        XCTAssertEqual(Typography.quote(after: "«так", language: "uk"), "»")
        XCTAssertEqual(Typography.quote(after: "", language: "en"), "“")
        XCTAssertEqual(Typography.quote(after: "“yes", language: "en"), "”")
        XCTAssertEqual(Typography.quote(after: "так «", language: "uk"), "»", "two presses give «»")
        XCTAssertEqual(Typography.quote(after: "(", language: "uk"), "«")
        XCTAssertEqual(Typography.dashHyphens(before: "так -"), 1)
        XCTAssertEqual(Typography.dashHyphens(before: "так --"), 2)
        XCTAssertEqual(Typography.dashHyphens(before: "-"), 0, "list marker")
        XCTAssertEqual(Typography.dashHyphens(before: "рядок\n-"), 0, "list marker")
        XCTAssertEqual(Typography.dashHyphens(before: "будь-"), 0, "hyphen in a word")
        XCTAssertEqual(Typography.dashHyphens(before: "git commit --"), 2, "spaced -- is a dash; '--amend' never gets here")
    }

    func testListContinuation() {
        XCTAssertEqual(ListContinuation.action(for: "- молоко"), .continueWith("- "))
        XCTAssertEqual(ListContinuation.action(for: "  • хліб"), .continueWith("  • "))
        XCTAssertEqual(ListContinuation.action(for: "1. перше"), .continueWith("2. "))
        XCTAssertEqual(ListContinuation.action(for: "9) дев'яте"), .continueWith("10) "))
        XCTAssertEqual(ListContinuation.action(for: "- "), .endList(deleting: 2))
        XCTAssertEqual(ListContinuation.action(for: "3. "), .endList(deleting: 3))
        XCTAssertNil(ListContinuation.action(for: "звичайний рядок"))
        XCTAssertNil(ListContinuation.action(for: "-5 градусів"))
        XCTAssertNil(ListContinuation.action(for: "1.5 літра"))
    }

    func testCaseCycle() {
        XCTAssertEqual(CaseCycle.next("привіт світ"), "Привіт світ")
        XCTAssertEqual(CaseCycle.next("Привіт світ"), "ПРИВІТ СВІТ")
        XCTAssertEqual(CaseCycle.next("ПРИВІТ СВІТ"), "привіт світ")
        XCTAssertEqual(CaseCycle.next("«hello»"), "«Hello»")
        XCTAssertEqual(CaseCycle.next("123"), "123")
    }
}

final class InflectionTests: XCTestCase {
    let corrector = TypoCorrector(spellChecker: MacSpellChecker())

    private func fix(_ word: String) -> String? {
        corrector.correction(for: word, language: "uk", layout: nil, allowCapitalized: true)
    }

    func testKeepsPluralFormsMissingFromTheDictionary() {
        // macOS lacks these; they used to become "налаштування" etc.
        for word in ["налаштуваннях", "налаштуваннями", "перемиканнях"] {
            XCTAssertNil(fix(word), word)
        }
    }

    func testStillFixesTyposThatLookLikeForms() {
        XCTAssertEqual(fix("питаня"), "питання", "ends in -я, but isn't a plural form")
        XCTAssertEqual(fix("робта"), "робота")
    }
}

final class LanguageGuessTests: XCTestCase {
    let checker = MacSpellChecker()

    func testPicksTheRecognizerThatHeardRealWords() {
        let candidates = [("uk", "Привіт це перевірка як воно працює"), ("en", "Prave, Prave, Kaya, Kona Praya")]
        XCTAssertEqual(LanguageGuess.best(candidates.map { (language: $0.0, text: $0.1) }, preferred: "en",
                                          spellChecker: checker)?.language, "uk")
        let english = [("uk", "Хеллоу ворлд зіс із е тест"), ("en", "Hello world, this is a test")]
        XCTAssertEqual(LanguageGuess.best(english.map { (language: $0.0, text: $0.1) }, preferred: "uk",
                                          spellChecker: checker)?.language, "en")
    }

    func testMadeUpNamesGiveAwayTheWrongLanguage() {
        // Real outputs of the macOS recognizers for the same Ukrainian recording.
        let candidates = [
            (language: "uk", text: "Привіт сьогодні я хочу перевірити довге речення Після паузи текст має залишитися повністю І ще 1 частина в самому кінці"),
            (language: "en", text: "Previous Please text my Alicia She was not just enough some McKenzie"),
        ]
        XCTAssertEqual(LanguageGuess.best(candidates, preferred: "en", spellChecker: checker)?.language, "uk")
        XCTAssertEqual(LanguageGuess.strayCapitalShare("Hello, this is a test. The weather is nice, I think."), 0)
    }

    func testCloseCallsGoToThePreferredLanguage() {
        let candidates = [(language: "uk", text: "ок"), (language: "en", text: "ok")]
        XCTAssertEqual(LanguageGuess.best(candidates, preferred: "uk", spellChecker: checker)?.language, "uk")
        XCTAssertNil(LanguageGuess.best([(language: "uk", text: " ")], preferred: "uk", spellChecker: checker))
    }
}

final class UtteranceJoinerTests: XCTestCase {
    func testSpotsANewPhraseAfterAPause() {
        XCTAssertTrue(UtteranceJoiner.isRestart(previous: "Привіт це перевірка як воно працює", next: "Сьогодні"))
        XCTAssertFalse(UtteranceJoiner.isRestart(previous: "Привіт це", next: "Привіт це перевірка"), "growing")
        XCTAssertFalse(UtteranceJoiner.isRestart(previous: "Привіт це перевірка", next: "Привіт"), "revised, same start")
        XCTAssertEqual(UtteranceJoiner.join("Привіт", "", " світ "), "Привіт світ")
        XCTAssertTrue(UtteranceJoiner.isRestart(previous: "Я працюю.\n", next: "Я сплю"), "after a line break")
        XCTAssertTrue(UtteranceJoiner.isRestart(previous: "Я працюю.", next: "Так"), "after a sentence")
        XCTAssertFalse(UtteranceJoiner.isRestart(previous: "Я працюю", next: "Я сплю"), "same start: a revision")
        XCTAssertEqual(UtteranceJoiner.join("Я працюю.\n", "Так"), "Я працюю.\nТак")
    }
}

final class RussianGuardTests: XCTestCase {
    func testSpotsRussianText() {
        XCTAssertTrue(LanguageGuess.looksRussian("Привет, это проверка, как оно работает"))
        XCTAssertTrue(LanguageGuess.looksRussian("сегодня хорошая погода и мы идем гулять"), "long, no і/ї/є/ґ")
        XCTAssertFalse(LanguageGuess.looksRussian("Привіт, це перевірка, як воно працює"))
        XCTAssertFalse(LanguageGuess.looksRussian("Hello, this is a test"))
        XCTAssertFalse(LanguageGuess.looksRussian("так"), "too short to tell")
    }
}

final class TranslationTests: XCTestCase {
    func testDirectionFollowsTheScript() {
        XCTAssertEqual(TranslationDirection(for: "Привіт, як справи?"), .ukrainianToEnglish)
        XCTAssertEqual(TranslationDirection(for: "Hello, how are you?"), .englishToUkrainian)
        XCTAssertEqual(TranslationDirection(for: "Відкрий GitHub і зроби commit"), .ukrainianToEnglish)
        XCTAssertEqual(TranslationDirection(for: "12345"), .englishToUkrainian)
        XCTAssertEqual(TranslationDirection.ukrainianToEnglish.reversed, .englishToUkrainian)
    }

    func testLinesKeepLayout() {
        let lines = TranslationLines("  Привіт, світ \n\n- пункт\n")
        XCTAssertEqual(lines.toTranslate, ["Привіт, світ", "- пункт"])
        XCTAssertEqual(lines.assemble(["Hello, world", "- item"]), "  Hello, world \n\n- item\n")
    }
}

final class TranscriptCleanupTests: XCTestCase {
    func testUnknownTokensBecomeDashesAndQuotes() {
        XCTAssertEqual(TranscriptCleanup.clean("Київ <unk> столиця України."), "Київ — столиця України.")
        XCTAssertEqual(TranscriptCleanup.clean("Він сказав <unk>привіт<unk> і пішов."), "Він сказав «привіт» і пішов.")
        XCTAssertEqual(TranscriptCleanup.clean("Книга <unk>Кобзар<unk>."), "Книга «Кобзар».")
        XCTAssertEqual(TranscriptCleanup.clean("He said <unk>hello<unk> twice"), "He said “hello” twice")
        XCTAssertEqual(TranscriptCleanup.clean("<unk> Добре."), "Добре.")
        XCTAssertEqual(TranscriptCleanup.clean("Звичайний текст, без змін."), "Звичайний текст, без змін.")
    }
}

final class VoiceVocabularyTests: XCTestCase {
    let rules = [Replacement(from: "зсу", to: "ЗСУ"), Replacement(from: "нова пошта", to: "Нова Пошта"),
                 Replacement(from: "київ", to: "київ"), Replacement(from: ":)", to: "🙂")]

    func testApplyWholeWordsIgnoringCase() {
        XCTAssertEqual(VoiceVocabulary.apply("Дякую зсу.", rules: rules), "Дякую ЗСУ.")
        XCTAssertEqual(VoiceVocabulary.apply("Зсу захищає", rules: rules), "ЗСУ захищає")
        XCTAssertEqual(VoiceVocabulary.apply("зсув ґрунту", rules: rules), "зсув ґрунту")
        XCTAssertEqual(VoiceVocabulary.apply("Відправ нова пошта завтра", rules: rules), "Відправ Нова Пошта завтра")
        XCTAssertEqual(VoiceVocabulary.apply("Київ гарний :)", rules: rules), "Київ гарний :)")
    }

    func testCorrectionsFindChangedWords() {
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Мій брат служить у зсу з весни.",
                                                   now: "Привіт! Мій брат служить у ЗСУ з весни."),
                       [Replacement(from: "зсу", to: "ЗСУ")])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Зустрінемось у кафе павлін завтра",
                                                   now: "Зустрінемось у кафе Pavlin завтра"),
                       [Replacement(from: "павлін", to: "Pavlin")])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Олег приїде завтра", now: "Олех приїде завтра"),
                       [Replacement(from: "Олег", to: "Олех")])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Я буду о десятій", now: "Я буду о десятій, домовились?"), [])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Я буду о десятій", now: "Я буду о десятій."), [])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Я буду о десятій", now: "Зовсім інший текст тут"), [])
    }

    func testOneLettersCaseIsNotACorrection() {
        // A capital put in or taken out by hand is not a spelling to learn.
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Ми були в київ вчора", now: "Ми були в Київ вчора"), [])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Ну Ми підемо завтра", now: "Ну ми підемо завтра"), [])
        // A whole word in capitals is: an abbreviation.
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Він служить у зсу давно", now: "Він служить у ЗСУ давно"),
                       [Replacement(from: "зсу", to: "ЗСУ")])
    }
}

final class VoiceCorrectionOrderTests: XCTestCase {
    func testCorrectionsComeInReadingOrder() {
        let found = VoiceVocabulary.corrections(inserted: "Привіт олег я в зсу сьогодні",
                                                now: "Привіт Олех я в ЗСУ сьогодні")
        XCTAssertEqual(found.first, Replacement(from: "олег", to: "Олех"))
        XCTAssertEqual(found.count, 2)
    }
}

final class ClipboardHistoryTests: XCTestCase {
    func testAddMovesDuplicatesUpAndKeepsPins() {
        var history = ClipboardHistory()
        history.add(ClipItem(kind: .text, text: "перший"), maxItems: 10, maxAge: nil)
        history.add(ClipItem(kind: .text, text: "другий"), maxItems: 10, maxAge: nil)
        history.togglePin(history.items[1].id)  // "перший"
        history.add(ClipItem(kind: .text, text: "перший"), maxItems: 10, maxAge: nil)
        XCTAssertEqual(history.items.map(\.text), ["перший", "другий"])
        XCTAssertTrue(history.items[0].pinned)
    }

    func testPruneKeepsPinnedAndDropsOld() {
        let now = Date()
        var history = ClipboardHistory()
        history.add(ClipItem(kind: .text, text: "старий", date: now.addingTimeInterval(-40 * 86_400)), maxItems: 10, maxAge: nil)
        history.togglePin(history.items[0].id)
        history.add(ClipItem(kind: .text, text: "давній", date: now.addingTimeInterval(-35 * 86_400)), maxItems: 10, maxAge: nil)
        for index in 0..<5 { history.add(ClipItem(kind: .text, text: "новий \(index)", date: now), maxItems: 3, maxAge: 30 * 86_400) }
        XCTAssertEqual(history.items.map(\.text), ["новий 4", "новий 3", "новий 2", "старий"])
    }

    func testSearchAndKinds() {
        var history = ClipboardHistory()
        history.add(ClipItem(kind: .link, text: "https://klavko.app"), maxItems: 10, maxAge: nil)
        history.add(ClipItem(kind: .text, text: "Зустріч у вівторок о 10"), maxItems: 10, maxAge: nil)
        XCTAssertEqual(history.search("вівторок зустріч").map(\.text), ["Зустріч у вівторок о 10"])
        XCTAssertEqual(history.search("", kind: .link).count, 1)
        history.add(ClipItem(kind: .files, text: "/Users/me/Desktop/Фото.JPG"), maxItems: 10, maxAge: nil)
        history.add(ClipItem(kind: .files, text: "/Users/me/Desktop/звіт.pdf"), maxItems: 10, maxAge: nil)
        XCTAssertEqual(history.search("", kind: .image).map(\.text), ["/Users/me/Desktop/Фото.JPG"])
        XCTAssertEqual(history.search("", kind: .files).map(\.text), ["/Users/me/Desktop/звіт.pdf"])
        XCTAssertEqual(ClipItem.kind(ofText: "https://github.com/x"), .link)
        XCTAssertEqual(ClipItem.kind(ofText: "дивись https://github.com/x"), .text)
        XCTAssertEqual(ClipItem.kind(ofText: "mailto:a@b.ua"), .link)
        XCTAssertEqual(ClipItem(kind: .text, text: "\n  Привіт\nсвіт").title, "Привіт")
    }
}

final class VoiceCorrectionSingleWordTests: XCTestCase {
    func testRewrittenPhrasesAreNotOffered() {
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Я прийду завтра зранку до офісу",
                                                   now: "Я прийду в понеділок після обіду до офісу"), [])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Я прийду завтра зранку до офісу",
                                                   now: "Я прийду завтра вранці до офісу"),
                       [Replacement(from: "зранку", to: "вранці")])
    }
}

final class ForeignLatinTests: XCTestCase {
    func testUkrainianHeardAsAnotherLatinLanguage() {
        XCTAssertTrue(LanguageGuess.looksForeignLatin("Přiby v texті z opisu zhádku."))
        XCTAssertTrue(LanguageGuess.looksForeignLatin("pryberi v texті"))
        XCTAssertFalse(LanguageGuess.looksForeignLatin("Прибери в тексті з опису згадку."))
        XCTAssertFalse(LanguageGuess.looksForeignLatin("Please remove it from the description."))
        XCTAssertFalse(LanguageGuess.looksForeignLatin("Відкрий GitHub і зроби commit"))
    }
}

final class AppVersionTests: XCTestCase {
    func testComparison() {
        XCTAssertTrue(AppVersion.isNewer("v0.12.0", than: "0.11.1"))
        XCTAssertTrue(AppVersion.isNewer("0.11.10", than: "0.11.9"))
        XCTAssertFalse(AppVersion.isNewer("0.11.1", than: "0.11.1"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("0.11.0", than: "0.11.1"))
    }
}

final class TranslationPairTests: XCTestCase {
    func testOwnAndOtherLanguage() {
        XCTAssertEqual(TranslationDirection(for: "Привіт, як справи?", own: "uk", other: "de"),
                       TranslationDirection(source: "uk", target: "de"))
        XCTAssertEqual(TranslationDirection(for: "Guten Morgen, wie geht es dir?", own: "uk", other: "de"),
                       TranslationDirection(source: "de", target: "uk"))
        XCTAssertEqual(TranslationDirection(for: "Good morning, how are you today?", own: "uk", other: "de", layouts: ["en"]),
                       TranslationDirection(source: "en", target: "uk"))
        XCTAssertEqual(TranslationDirection(for: "Hello, how are you?", own: "en", other: "uk"),
                       TranslationDirection(source: "en", target: "uk"))
        XCTAssertFalse(TranslationDirection.languages.contains("el"))
    }
}

final class ReleaseNotesTests: XCTestCase {
    func testWhatsNewList() {
        let notes = """
        Klavko — безкоштовний помічник.

        **Що нового в 0.13.0:**
        - **Текст з екрана** (⌃Q): виділіть область — Klavko прочитає й перекладе текст.
        - Переклад між будь-якими мовами, вибір мов прямо у вікні перекладу.

        **What’s new in 0.13.0:**
        - Text from the screen (⌃Q).

        **Завантаження:** файл `Klavko-0.13.0.zip` нижче.
        """
        XCTAssertEqual(ReleaseNotes.whatsNew(notes), [
            "Текст з екрана (⌃Q): виділіть область — Klavko прочитає й перекладе текст.",
            "Переклад між будь-якими мовами, вибір мов прямо у вікні перекладу.",
        ])
        XCTAssertEqual(ReleaseNotes.whatsNew(notes, english: true), ["Text from the screen (⌃Q)."])
    }

    func testHeadingWithTextAfterIt() {
        let notes = "Опис.\n\n**Що нового в 0.12.0:** автоматичні оновлення.\n\nЯкщо у вас вже стоїть старіша версія…"
        XCTAssertEqual(ReleaseNotes.whatsNew(notes), ["автоматичні оновлення."])
        XCTAssertEqual(ReleaseNotes.whatsNew(notes, english: true), ["автоматичні оновлення."])
        XCTAssertEqual(ReleaseNotes.plain("[подякувати автору](https://x.y) ❤️"), "подякувати автору ❤️")
    }
}

/// Dictionaries per language, to test the sentence rules exactly.
final class LanguageSpellChecker: SpellChecking {
    let words: [String: Set<String>]

    init(_ words: [String: Set<String>]) { self.words = words }

    func isValid(_ word: String, language: String) -> Bool { words[language]?.contains(word.lowercased()) == true }
    func hasCompletions(_ prefix: String, language: String) -> Bool { !completions(for: prefix, language: language).isEmpty }
    func completions(for prefix: String, language: String) -> [String] {
        (words[language] ?? []).filter { $0.hasPrefix(prefix.lowercased()) }.sorted()
    }
    func correction(for word: String, language: String, context: String) -> String? { nil }
    func guesses(for word: String, language: String, context: String) -> [String] { [] }
    func validWords(among candidates: [String], language: String) -> Set<String> {
        Set(candidates.filter { isValid($0, language: language) })
    }
}

final class LanguageContextTests: XCTestCase {
    func testTakesTheLastLineOnly() {
        XCTAssertEqual(LanguageContext.lastWords(of: Array("Hello there.\nЯ сегодня. Дома "), limit: 6), ["дома", "сегодня", "я"])
        XCTAssertEqual(LanguageContext.lastWords(of: Array("раз два три четыре"), limit: 2), ["четыре", "три"])
        XCTAssertEqual(LanguageContext.lastWords(of: Array("це м'ята, "), limit: 6), ["м'ята", "це"])
        XCTAssertEqual(LanguageContext.lastWords(of: Array("Готово.\n"), limit: 6), [])
        XCTAssertEqual(LanguageContext.lastWords(of: Array("Готово. "), limit: 6), ["готово"])
    }

    func testWordsOfBothLanguagesDontTipTheBalance() {
        var context = LanguageContext()
        context.add(["ru", "uk"])          // дома
        XCTAssertFalse(context.favors("ru", over: "uk"))
        XCTAssertTrue(context.favors("ru", over: "en"))
        context.add(["ru"])                // сегодня
        XCTAssertTrue(context.favors("ru", over: "uk"))
        XCTAssertFalse(LanguageContext().favors("ru", over: "en"))
    }
}

final class ContextRuleTests: XCTestCase {
    // "дгс" (a typo for "дог…") starts "luck" on the English keys.
    let checker = LanguageSpellChecker([
        "ru": ["договор", "сегодня", "я"],
        "en": ["luck", "lucky"],
    ])
    lazy var analyzer = WordAnalyzer(spellChecker: checker)
    let russian = LanguageContext("ru")

    func testWaitsForTheWholeWordInASentenceOfTheTypedLanguage() {
        XCTAssertTrue(analyzer.shouldConvertPrefix(typed: "дгс", typedLanguage: "ru", alternative: "luc", alternativeLanguage: "en"))
        XCTAssertFalse(analyzer.shouldConvertPrefix(typed: "дгс", typedLanguage: "ru", alternative: "luc",
                                                    alternativeLanguage: "en", context: russian))
        // A sentence in the other language still lets it switch early.
        XCTAssertTrue(analyzer.shouldConvertPrefix(typed: "дгс", typedLanguage: "ru", alternative: "luc",
                                                   alternativeLanguage: "en", context: LanguageContext("en")))
    }

    func testAWholeWordStillSwitchesMidSentence() {
        XCTAssertTrue(analyzer.shouldConvert(typed: "дгсл", typedLanguage: "ru", alternative: "luck",
                                             alternativeLanguage: "en", context: russian))
    }

    func testAWordDoesNotStartWithPunctuation() {
        // "бин" (a typo for "был") is ",by" on the English keys: the comma key was pressed as a letter.
        let checker = LanguageSpellChecker(["ru": ["был"], "en": ["by"]])
        XCTAssertFalse(WordAnalyzer(spellChecker: checker).shouldConvert(typed: "бинс", typedLanguage: "ru",
                                                                        alternative: ",byc", alternativeLanguage: "en"))
    }

    func testShortWordsOfOneAlphabetNeedTheSentence() {
        let both = LanguageSpellChecker(["ru": [], "uk": []])
        let analyzer = WordAnalyzer(spellChecker: both)
        let ukrainian = LanguageContext("uk")
        // "що" typed in the Russian layout is "шо"; only a Ukrainian sentence makes it Ukrainian.
        XCTAssertFalse(analyzer.shouldConvert(typed: "шо", typedLanguage: "ru", alternative: "що",
                                              alternativeLanguage: "uk", sameScript: true))
        XCTAssertTrue(analyzer.shouldConvert(typed: "шо", typedLanguage: "ru", alternative: "що",
                                             alternativeLanguage: "uk", context: ukrainian, sameScript: true))
    }
}

final class UpdateThanksTests: XCTestCase {
    func testShownOnceAfterAnUpdate() {
        XCTAssertTrue(UpdateThanks.shouldShow(lastRunVersion: "0.14.0", current: "0.15.0", usedBefore: true))
        // The same version again (a reinstall, or the next launch) or an older one: no.
        XCTAssertFalse(UpdateThanks.shouldShow(lastRunVersion: "0.15.0", current: "0.15.0", usedBefore: true))
        XCTAssertFalse(UpdateThanks.shouldShow(lastRunVersion: "0.15.0", current: "0.14.0", usedBefore: true))
    }

    func testVersionsBeforeRememberingIt() {
        // 0.13 didn't remember its version: settings saved before mean an update, none mean a first install.
        XCTAssertTrue(UpdateThanks.shouldShow(lastRunVersion: nil, current: "0.14.0", usedBefore: true))
        XCTAssertFalse(UpdateThanks.shouldShow(lastRunVersion: nil, current: "0.14.0", usedBefore: false))
    }
}

final class QRContentTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(QRContent("https://send.monobank.ua/jar/2CKJVz8jam"), .link(URL(string: "https://send.monobank.ua/jar/2CKJVz8jam")!))
        XCTAssertEqual(QRContent(" http://example.com/a?b=1 \n"), .link(URL(string: "http://example.com/a?b=1")!))
        XCTAssertEqual(QRContent("www.example.com"), .link(URL(string: "https://www.example.com")!))
    }

    func testEverythingElseIsText() {
        XCTAssertEqual(QRContent("Привіт, світе"), .text("Привіт, світе"))
        XCTAssertEqual(QRContent("WIFI:S:Home;T:WPA;P:secret;;"), .text("WIFI:S:Home;T:WPA;P:secret;;"))
        XCTAssertEqual(QRContent("mailto:someone@example.com"), .text("mailto:someone@example.com"))
        XCTAssertEqual(QRContent("https://example.com is the site"), .text("https://example.com is the site"))
        XCTAssertEqual(QRContent("http://localhost"), .text("http://localhost"))
    }
}

final class VoiceHistoryTests: XCTestCase {
    func testNewestFirstAndEmptyIgnored() {
        var history = VoiceHistory()
        history.add("Перший запис")
        history.add("  ")
        history.add(" Другий запис \n")
        XCTAssertEqual(history.entries.map(\.text), ["Другий запис", "Перший запис"])
    }

    func testRemoveAndClear() {
        var history = VoiceHistory()
        history.add("a"); history.add("b"); history.add("c")
        history.remove(history.entries[1].id)
        XCTAssertEqual(history.entries.map(\.text), ["c", "a"])
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testKeepsTheNewestWithinTheLimit() {
        var history = VoiceHistory()
        for index in 0...VoiceHistory.limit { history.add("\(index)") }
        XCTAssertEqual(history.entries.count, VoiceHistory.limit)
        XCTAssertEqual(history.entries.first?.text, "\(VoiceHistory.limit)")
        XCTAssertEqual(history.entries.last?.text, "1")
    }

    func testSearchMatchesEveryWordInAnyCase() {
        var history = VoiceHistory()
        history.add("Зустріч у понеділок о десятій")
        history.add("Купити хліб і молоко")
        history.add("Понеділок: подзвонити Олегу")
        XCTAssertEqual(history.search("понеділок").map(\.text), ["Понеділок: подзвонити Олегу", "Зустріч у понеділок о десятій"])
        XCTAssertEqual(history.search("ПОНЕДІЛОК десятій").map(\.text), ["Зустріч у понеділок о десятій"])
        XCTAssertEqual(history.search("  ").count, 3)
        XCTAssertTrue(history.search("вівторок").isEmpty)
    }

    func testRoundTrip() throws {
        var history = VoiceHistory()
        history.add("Привіт", at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try JSONDecoder().decode(VoiceHistory.self, from: JSONEncoder().encode(history)), history)
    }
}

final class TextLinksTests: XCTestCase {
    func testFindsAddressesInsideText() {
        let text = "Ось посилання: https://send.monobank.ua/jar/2CKJVz8jam — і ще www.example.com, пишіть на a@b.ua."
        let found = TextLinks.find(in: text)
        XCTAssertEqual(found.map { String(text[$0.range]) }, ["https://send.monobank.ua/jar/2CKJVz8jam", "www.example.com", "a@b.ua"])
        XCTAssertEqual(found[0].url.absoluteString, "https://send.monobank.ua/jar/2CKJVz8jam")
        XCTAssertEqual(found[2].url.scheme, "mailto")
    }

    func testPlainTextHasNone() {
        XCTAssertTrue(TextLinks.find(in: "Просто текст без адрес.").isEmpty)
    }
}

final class VoiceStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testTheFirstDayAndAPastMonth() {
        var stats = VoiceStats()
        XCTAssertNil(stats.firstDay(calendar: calendar))
        stats.addInserted("один два три", at: date(2026, 10, 1), calendar: calendar)
        stats.addInserted("чотири", at: date(2026, 10, 31), calendar: calendar)
        stats.addInserted("п’ять шість", at: date(2026, 1, 15), calendar: calendar)
        stats.addInserted("торішнє", at: date(2025, 12, 31), calendar: calendar)
        XCTAssertEqual(stats.firstDay(calendar: calendar), date(2025, 12, 31))
        // A past month or year reads as a whole, through any day in it.
        XCTAssertEqual(stats.counts(.month, now: date(2026, 10, 15), calendar: calendar).words, 4)
        XCTAssertEqual(stats.counts(.year, now: date(2025, 6, 1), calendar: calendar).words, 1)
    }

    func testWordsKeepApostrophesAndHyphens() {
        XCTAssertEqual(VoiceStats.words(in: "П’ять яблук — будь-який, 2026 рік!"), ["П’ять", "яблук", "будь-який", "2026", "рік"])
        XCTAssertEqual(VoiceStats.words(in: "Числа: 120, 35,5 і 44."), ["Числа", "120", "35,5", "і", "44"])
    }

    func testPeriodsAndTopWords() {
        var stats = VoiceStats()
        let today = date(2026, 10, 26)
        stats.addStart(at: today, calendar: calendar)
        stats.addListening(12, at: today, calendar: calendar)
        stats.addInserted("Проєкт готовий, проєкт надіслано і він на місці", at: today, calendar: calendar)
        stats.addInserted("Старий проєкт", at: date(2026, 9, 3), calendar: calendar)
        stats.addInserted("Минулий рік", at: date(2025, 12, 31), calendar: calendar)

        XCTAssertEqual(stats.counts(.day, now: today, calendar: calendar).words, 8)
        XCTAssertEqual(stats.counts(.day, now: today, calendar: calendar).starts, 1)
        XCTAssertEqual(stats.counts(.day, now: today, calendar: calendar).seconds, 12)
        XCTAssertEqual(stats.counts(.month, now: today, calendar: calendar).words, 8)
        XCTAssertEqual(stats.counts(.year, now: today, calendar: calendar).words, 10)
        XCTAssertEqual(stats.counts(.all, now: today, calendar: calendar).words, 12)
        // Words shorter than 3 letters ("і", "він" counts, "на" doesn't), case ignored.
        let top = stats.topWords(.day, now: today, calendar: calendar)
        XCTAssertEqual(top.first?.word, "проєкт")
        XCTAssertEqual(top.first?.count, 2)
        XCTAssertFalse(top.contains { $0.word == "на" || $0.word == "і" })
        XCTAssertTrue(top.contains { $0.word == "він" })
        XCTAssertEqual(stats.topWords(.year, now: today, calendar: calendar).first?.count, 3)
    }

    func testMilestonesOnceEach() {
        var stats = VoiceStats()
        let text = Array(repeating: "слово", count: 600).joined(separator: " ")
        XCTAssertNil(stats.addInserted(text))
        XCTAssertEqual(stats.addInserted(text), 1_000)
        XCTAssertNil(stats.addInserted(text))
    }

    func testTypingSpeedAndTimeSaved() {
        var stats = VoiceStats()
        XCTAssertNil(stats.measuredCharactersPerMinute)
        XCTAssertEqual(stats.charactersPerMinute, VoiceStats.defaultCharactersPerMinute)
        stats.addKey(printable: true, interval: nil)
        for _ in 0..<1_999 { stats.addKey(printable: true, interval: 0.25) }
        stats.addKey(printable: true, interval: 30)  // a pause is not typing time
        XCTAssertEqual(stats.measuredCharactersPerMinute ?? 0, 2_001 / (1_999 * 0.25) * 60, accuracy: 0.01)
        // 400 characters at 200 a minute take 2 minutes to type; dictating them took 30 s.
        let counts = VoiceStats.Counts(words: 60, characters: 400, seconds: 30, starts: 1)
        XCTAssertEqual(VoiceStats().savedSeconds(counts), 90, accuracy: 0.01)
    }
}

final class QuickTextTests: XCTestCase {
    func testCase() {
        let uk = Locale(identifier: "uk_UA")
        XCTAssertEqual(QuickText.uppercased("привіт, світ", locale: uk), "ПРИВІТ, СВІТ")
        XCTAssertEqual(QuickText.lowercased("ПРИВІТ Світ", locale: uk), "привіт світ")
        XCTAssertEqual(QuickText.capitalized("п’ять будь-яких iPhone слів", locale: uk), "П’ять Будь-яких IPhone Слів")
    }

    func testWrapKeepsOuterSpaces() {
        XCTAssertEqual(QuickText.wrapped("слово ", open: "(", close: ")"), "(слово) ")
        XCTAssertEqual(QuickText.wrapped(" два слова", open: "«", close: "»"), " «два слова»")
    }

    func testStrikeAndStats() {
        XCTAssertEqual(QuickText.struckThrough("аб в"), "а\u{0336}б\u{0336} в\u{0336}")
        XCTAssertEqual(QuickText.stats("Привіт, світе! Як ти?"), QuickText.Stats(words: 4, characters: 21, charactersWithoutSpaces: 18))
    }

    func testNumbersAndSum() {
        XCTAssertEqual(QuickText.numbers(in: "1\u{00A0}234,5 грн, 1,234.5 $, −12 і 3.75; рік2026"), [1234.5, 1234.5, -12, 3.75])
        XCTAssertEqual(QuickText.numbers(in: "100 200"), [100, 200])
        XCTAssertEqual(QuickText.sum("10 + 20,5 + 1.000.000"), Decimal(string: "1000030.5"))
        XCTAssertNil(QuickText.sum("лише 42"))
    }

    func testAnswerAfterEquals() {
        XCTAssertEqual(Calculation.answer(after: "2+3*4", language: "uk"), "14")
        XCTAssertEqual(Calculation.answer(after: "Разом: 1 250 * 3 ", language: "uk"), " 3750")
        XCTAssertEqual(Calculation.answer(after: "10/4", language: "uk"), "2,5")
        XCTAssertEqual(Calculation.answer(after: "10/4", language: "en"), "2.5")
        XCTAssertEqual(Calculation.answer(after: "1.5*3", language: "uk"), "4.5")
        XCTAssertEqual(Calculation.answer(after: "- 2+3", language: "uk"), "5")
        XCTAssertEqual(Calculation.answer(after: "(2 + 3) * 4 ", language: "uk"), " 20")
        XCTAssertEqual(Calculation.answer(after: "3-10", language: "uk"), "-7")
        XCTAssertEqual(Calculation.answer(after: "10/3", language: "en"), "3.3333333333")
        XCTAssertEqual(Calculation.answer(after: "Ціна 25*4", language: "uk"), "100")
        XCTAssertEqual(Calculation.answer(after: "Купив 3 кг по 45,5 грн, разом 3 * 45,5 ", language: "uk"), " 136,5")
        XCTAssertEqual(Calculation.answer(after: "Також 5, 2+3", language: "uk"), "5")
        XCTAssertEqual(Calculation.answer(after: "Кімната 3 4*5", language: "uk"), "20")
        XCTAssertEqual(Calculation.answer(after: "тел. 067-123-45-67 2+2", language: "uk"), "4")
        XCTAssertEqual(Calculation.answer(after: "Відповідь (2 + 3) * 4", language: "uk"), "20")
        XCTAssertNil(Calculation.answer(after: "дата 2026-11-04", language: "uk"))
        XCTAssertNil(Calculation.answer(after: "x ", language: "uk"))
        XCTAssertNil(Calculation.answer(after: "x2*3", language: "uk"))
        XCTAssertNil(Calculation.answer(after: "-5", language: "uk"))
        XCTAssertNil(Calculation.answer(after: "2026-11-04", language: "uk"))
        XCTAssertNil(Calculation.answer(after: "a ", language: "uk"))
        XCTAssertNil(Calculation.answer(after: "", language: "uk"))
    }

    func testCalculation() {
        XCTAssertEqual(Calculation.evaluate("2 + 3 * 4"), 14)
        XCTAssertEqual(Calculation.evaluate("(2 + 3) * 4 ="), 20)
        XCTAssertEqual(Calculation.evaluate("1 250 × 3"), 3750)
        XCTAssertEqual(Calculation.evaluate("10 / 4"), Decimal(string: "2.5"))
        XCTAssertEqual(Calculation.evaluate("7,5 ÷ 2,5 − 1"), 2)
        XCTAssertEqual(Calculation.evaluate("200 + 15%"), 230)
        XCTAssertEqual(Calculation.evaluate("200 - 10%"), 180)
        XCTAssertEqual(Calculation.evaluate("200 * 15%"), 30)
        XCTAssertEqual(Calculation.evaluate("-3 * -2"), 6)
        XCTAssertNil(Calculation.evaluate("5 / 0"))
        XCTAssertNil(Calculation.evaluate("2026"))
        XCTAssertNil(Calculation.evaluate("2026-11-04"))
        XCTAssertEqual(Calculation.evaluate("2026-11"), 2015)
        XCTAssertNil(Calculation.evaluate("2 + "))
        XCTAssertNil(Calculation.evaluate("Хліб 25 + молоко 40"))
        // Not an expression: the numbers are added up, as before.
        XCTAssertEqual(Calculation.of("Хліб 25, молоко 40"), .sum(65))
        XCTAssertEqual(Calculation.of("100\n200\n300"), .sum(600))
        XCTAssertEqual(Calculation.of("12 * 3"), .expression(36))
        XCTAssertNil(Calculation.of("лише 42"))
    }

    func testOfficialTransliteration() {
        let cases = [
            "Сергій Шевченко": "Serhii Shevchenko", "Згорани": "Zghorany", "Розгон": "Rozghon", "Юрій": "Yurii",
            "Їжакевич": "Yizhakevych", "Короп’є": "Koropie", "Знам'янка": "Znamianka", "Яготин": "Yahotyn",
            "Біла Церква": "Bila Tserkva", "Луцьк": "Lutsk", "Йосипівка": "Yosypivka", "Стрий": "Stryi",
            "Олексій": "Oleksii", "Україна": "Ukraina", "Щербухи": "Shcherbukhy", "Гадяч": "Hadiach",
            "Ґорґани": "Gorgany", "Єнакієве": "Yenakiieve", "Хмельницький": "Khmelnytskyi", "ЩУКА": "SHCHUKA",
            "вул. Січових Стрільців, 5": "vul. Sichovykh Striltsiv, 5",
        ]
        for (ukrainian, latin) in cases { XCTAssertEqual(Transliteration.latin(ukrainian, language: "uk"), latin, ukrainian) }
        XCTAssertTrue(Transliteration.applies(to: "Київ"))
        XCTAssertTrue(Transliteration.applies(to: "Ђорђе"))
        XCTAssertFalse(Transliteration.applies(to: "Kyiv 2026"))
    }

    func testTransliterationOfOtherLanguages() {
        let cases: [(String, String, String)] = [
            ("ru", "Юрий Щербаков", "Iurii Shcherbakov"), ("ru", "Пётр Хрущёв", "Petr Khrushchev"),
            ("ru", "Объём", "Obieem"), ("ru", "Съешь этих", "Sieesh etikh"), ("ru", "Григорий", "Grigorii"),
            ("be", "Віцебск", "Viciebsk"), ("be", "Магілёў", "Mahilioŭ"), ("be", "Гомель", "Homieĺ"),
            ("be", "Ляхавічы", "Liachavičy"), ("be", "Ельск", "Jeĺsk"), ("be", "Дзяржынск", "Dziaržynsk"),
            ("be", "Мсціслаў", "Mscislaŭ"), ("be", "Падʼезд", "Padjezd"), ("be", "Лельчыцы", "Lieĺčycy"),
            ("bg", "Щастливец", "Shtastlivets"), ("bg", "София", "Sofia"), ("bg", "Юлия Ябълкова", "Yulia Yabalkova"),
            ("bg", "България", "Bulgaria"), ("bg", "Георги Йорданов", "Georgi Yordanov"), ("bg", "Път", "Pat"),
            ("sr", "Ђорђе Чворовић", "Đorđe Čvorović"), ("sr", "Љубљана", "Ljubljana"), ("sr", "ЉУБА", "LJUBA"),
            ("sr", "Џеп", "Džep"),
            ("mk", "Ѓорѓи", "Gjorgji"), ("mk", "Ќерка", "Kjerka"), ("mk", "Ѕвезда", "Dzvezda"), ("mk", "Џамија", "Djamija"),
        ]
        for (language, cyrillic, latin) in cases {
            XCTAssertEqual(Transliteration.latin(cyrillic, language: language), latin, cyrillic)
        }
    }

    func testTransliterationLanguage() {
        XCTAssertEqual(Transliteration.language(of: "Сергій"), "uk")
        XCTAssertEqual(Transliteration.language(of: "Магілёў"), "be")
        XCTAssertEqual(Transliteration.language(of: "Мінск і Брэст"), "be")
        XCTAssertEqual(Transliteration.language(of: "Съешь ещё"), "ru")
        XCTAssertEqual(Transliteration.language(of: "Път"), "bg")
        XCTAssertEqual(Transliteration.language(of: "Ђорђе"), "sr")
        XCTAssertEqual(Transliteration.language(of: "Ѓорѓи"), "mk")
        XCTAssertEqual(Transliteration.language(of: "привет как дела") { $0 == "ru" ? 1 : 0 }, "ru")
        XCTAssertEqual(Transliteration.language(of: "объект") { $0 == "ru" ? 1 : 0 }, "ru")
        XCTAssertEqual(Transliteration.language(of: "добре") { _ in 0.5 }, "uk")
        XCTAssertEqual(Transliteration.language(of: "Стрий"), "uk")
    }

    func testWebAddresses() {
        XCTAssertEqual(SearchEngine.google.url(for: " кіт & пес ")?.absoluteString,
                       "https://www.google.com/search?q=%D0%BA%D1%96%D1%82%20%26%20%D0%BF%D0%B5%D1%81")
        XCTAssertTrue(AIService.claude.webURL(for: "hi").carriesText)
        XCTAssertFalse(AIService.gemini.webURL(for: "hi").carriesText)
        XCTAssertFalse(AIService.perplexity.webURL(for: "hi").carriesText)
        XCTAssertEqual(HotkeyAction.voiceTranslate.defaultShortcut, Shortcut(modifiers: [.function, .control], double: false))
        XCTAssertNotEqual(HotkeyAction.voiceTranslate.defaultShortcut, HotkeyAction.voice.defaultShortcut)
        XCTAssertEqual(TranslationDirection.language(of: "Привіт, як справи?", among: ["uk", "en"]), "uk")
        XCTAssertEqual(QuickText.sentenceCased("ПРИВІТ, СВІТЕ. ЯК СПРАВИ? ДОБРЕ!\nНОВИЙ РЯДОК 2 РАЗИ"),
                       "Привіт, світе. Як справи? Добре!\nНовий рядок 2 рази")
        XCTAssertEqual(QuickText.sentenceCased("  hello WORLD"), "  Hello world")
        XCTAssertEqual(AIService.claude.appLink(for: "a & b")?.absoluteString, "claude://claude.ai/new?q=a%20%26%20b&surface=chat")
        XCTAssertNil(AIService.chatGPT.appLink(for: "hi"))
        XCTAssertTrue(AIService.chatGPT.isApp(named: "ChatGPT"))
        XCTAssertFalse(AIService.chatGPT.isApp(named: "Codex"))
    }
}

final class GrammarCheckTests: XCTestCase {
    private let response = """
    {"matches":[
     {"message":"Пропущена кома","offset":13,"length":2,"replacements":[{"value":", що"}],
      "rule":{"id":"COMMA_SHCHO","issueType":"typographical","category":{"id":"PUNCTUATION"}}},
     {"message":"Помилка","offset":0,"length":6,"replacements":[{"value":"Привіт"},{"value":"Привітання"}],
      "rule":{"id":"MORFOLOGIK_RULE_UK_UA","issueType":"misspelling","category":{"id":"TYPOS"}}},
     {"message":"Перекривається","offset":2,"length":3,"replacements":[],
      "rule":{"id":"X","issueType":"grammar","category":{"id":"GRAMMAR"}}}
    ]}
    """

    func testParsesInTextOrderAndDropsOverlaps() throws {
        let issues = try GrammarCheck.issues(fromResponse: Data(response.utf8))
        XCTAssertEqual(issues.map(\.offset), [0, 13])
        XCTAssertEqual(issues[0].kind, .spelling)
        XCTAssertEqual(issues[0].replacements, ["Привіт", "Привітання"])
        XCTAssertEqual(issues[1].kind, .punctuation)
    }

    func testDictionaryWordsAreNotSpellingMistakes() {
        let text = "Klavko пам’ятає Klavka, але кома тут"
        let issues = [
            GrammarIssue(offset: 0, length: 6, message: "", replacements: [], kind: .spelling, ruleID: "A"),
            GrammarIssue(offset: 7, length: 8, message: "", replacements: [], kind: .spelling, ruleID: "A"),
            GrammarIssue(offset: 16, length: 6, message: "", replacements: [], kind: .spelling, ruleID: "A"),
            GrammarIssue(offset: 0, length: 6, message: "", replacements: [], kind: .grammar, ruleID: "B"),
        ]
        let left = GrammarCheck.withoutKnownWords(issues, in: text, words: ["klavko", "пам'ятає"])
        // Any case, any apostrophe; another form of the word and other kinds of mistake stay.
        XCTAssertEqual(left.map(\.offset), [16, 0])
        XCTAssertEqual(left.map(\.kind), [.spelling, .grammar])
        XCTAssertEqual(GrammarCheck.withoutKnownWords(issues, in: text, words: []), issues)
    }

    func testAppliesChosenFixesFromTheEnd() {
        let text = "Првіт, я знаю що ти тут"
        let issues = [
            GrammarIssue(offset: 0, length: 5, message: "", replacements: ["Привіт"], kind: .spelling, ruleID: "A"),
            GrammarIssue(offset: 13, length: 3, message: "", replacements: [", що"], kind: .punctuation, ruleID: "B"),
        ]
        XCTAssertEqual(GrammarCheck.apply([issues[0].id: "Привіт", issues[1].id: ", що"], of: issues, to: text),
                       "Привіт, я знаю, що ти тут")
        XCTAssertEqual(GrammarCheck.apply([issues[1].id: ", що"], of: issues, to: text), "Првіт, я знаю, що ти тут")
    }

    func testRangesCountUTF16LikeJava() {
        // The emoji is two UTF-16 units, so the word after it starts at 3.
        let text = "😀 слво"
        let issue = GrammarIssue(offset: 3, length: 4, message: "", replacements: ["слово"], kind: .spelling, ruleID: "A")
        XCTAssertEqual(issue.range(in: text).map { String(text[$0]) }, "слво")
        XCTAssertNil(GrammarIssue(offset: 6, length: 4, message: "", replacements: [], kind: .spelling, ruleID: "B")
            .range(in: text))
    }

    func testDictionaryFormFixesKeepTheEnding() throws {
        // As LanguageTool 6.6 answers for «у проекті»: the fix is the dictionary form.
        let text = "Я у проекті."
        let json = """
        {"matches":[{"message":"Правопис","offset":4,"length":7,"replacements":[{"value":"проєкт"}],
          "rule":{"id":"UK_SIMPLE_REPLACE_SPELLING_1992","issueType":"misspelling","category":{"id":"MISC"}}}]}
        """
        let issues = try GrammarCheck.issues(fromResponse: Data(json.utf8), text: text)
        XCTAssertEqual(issues.first?.replacements, ["проєкті"])
        XCTAssertEqual(GrammarCheck.inflected("брати", like: "приймаю"), "брати")
        XCTAssertEqual(GrammarCheck.inflected(",", like: " ,"), ",")
        XCTAssertEqual(GrammarCheck.kind(issueType: "uncategorized", category: "BARBARISM"), .style)
    }

    func testParagraphsAndTheCaret() {
        let paragraphs = GrammarCheck.paragraphs(of: "Перший 😀 рядок\n\n  \nДругий")
        XCTAssertEqual(paragraphs, [GrammarCheck.Paragraph(text: "Перший 😀 рядок", offset: 0),
                                    GrammarCheck.Paragraph(text: "Другий", offset: 20)])
        let typo = GrammarIssue(offset: 2, length: 4, message: "", replacements: [], kind: .spelling, ruleID: "A")
        let comma = GrammarIssue(offset: 2, length: 4, message: "", replacements: [], kind: .punctuation, ruleID: "B")
        XCTAssertEqual(GrammarCheck.awayFromCaret([typo, comma], caret: 6), [comma])
        XCTAssertEqual(GrammarCheck.awayFromCaret([typo], caret: 7), [typo])
        XCTAssertEqual(typo.shifted(by: 19).offset, 21)
    }

    func testLanguageCodes() {
        XCTAssertEqual(GrammarCheck.languageCode(for: "uk"), "uk-UA")
        XCTAssertEqual(GrammarCheck.languageCode(for: "fr"), "fr")
        XCTAssertEqual(GrammarCheck.languageCode(for: nil), "auto")
    }
}

final class UkrainianCommasTests: XCTestCase {
    private func fixed(_ text: String) -> String {
        let issues = UkrainianCommas.issues(in: text)
        return GrammarCheck.apply(Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0.replacements[0]) }), of: issues, to: text)
    }

    func testAddsCommasBeforeClauses() {
        XCTAssertEqual(fixed("Він сказав що прийде завтра."), "Він сказав, що прийде завтра.")
        XCTAssertEqual(fixed("Ми підемо гуляти якщо не буде дощу."), "Ми підемо гуляти, якщо не буде дощу.")
        XCTAssertEqual(fixed("Це книга яку я читав."), "Це книга, яку я читав.")
        XCTAssertEqual(fixed("Це місто в якому я живу."), "Це місто, в якому я живу.")
        XCTAssertEqual(fixed("Перевірка як воно працює"), "Перевірка, як воно працює")
        XCTAssertEqual(fixed("Вона знала де він живе."), "Вона знала, де він живе.")
        XCTAssertEqual(fixed("Я знаю як це зробити."), "Я знаю, як це зробити.")
    }

    func testLeavesAloneWhatNeedsNoComma() {
        for text in ["Що ти робиш?", "Він сказав, що прийде.", "Я прийшов тому що хотів.", "Поки що все добре.",
                     "Такий як я.", "Про що ти думаєш?", "Я і що?", "Дощ. Що далі?",
                     "Я читав а також писав."] {
            XCTAssertEqual(fixed(text), text, text)
        }
    }

    func testLanguageToolWinsOverlaps() {
        let lt = GrammarIssue(offset: 0, length: 5, message: "", replacements: [], kind: .grammar, ruleID: "LT")
        let own = GrammarIssue(offset: 3, length: 5, message: "", replacements: [], kind: .punctuation, ruleID: "K")
        let later = GrammarIssue(offset: 9, length: 2, message: "", replacements: [], kind: .punctuation, ruleID: "K2")
        XCTAssertEqual(UkrainianCommas.merged([lt], with: [own, later]).map(\.ruleID), ["LT", "K2"])
    }
}

final class ScreenTextAlignmentTests: XCTestCase {
    private func utf16Range(of word: String, in text: String) -> Range<Int> {
        let range = text.range(of: word)!
        let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        return start..<(start + word.utf16.count)
    }

    func testFindsAWordReadWrong() {
        let paragraph = "Тут **жирний текст** і ще одна перевцрка слова, яку треба виправити."
        let lines = ["Перевірка як воно працює в документі.",
                     "Тут **жирний текст** і ще одна перевцока слова, яку треба виправити.",
                     "Третій абзац де є помилка ё кома пропущена."]
        let spots = ScreenTextAlignment.spots(of: utf16Range(of: "перевцрка", in: paragraph), in: paragraph, lines: lines)
        XCTAssertEqual(spots, [.init(line: 1, characters: 31..<40)])
    }

    func testFindsAWordWithItsEndReadWrong() {
        let paragraph = "Третій абзац де є помилкаа і кома пропущена."
        let lines = ["Третій абзац де є помилка ё кома пропущена."]
        let spots = ScreenTextAlignment.spots(of: utf16Range(of: "помилкаа", in: paragraph), in: paragraph, lines: lines)
        XCTAssertEqual(spots.first?.line, 0)
        XCTAssertEqual(spots.first?.characters.lowerBound, 18)
    }

    func testSplitsAWordOverAWrappedLine() {
        let paragraph = "Перший рядок довгого абзацу, що переноситься далі."
        let lines = ["Перший рядок довгого абза-", "цу, що переноситься далі."]
        let spots = ScreenTextAlignment.spots(of: utf16Range(of: "абзацу", in: paragraph), in: paragraph, lines: lines)
        XCTAssertEqual(spots.map(\.line), [0, 1])
        XCTAssertEqual(spots.first?.characters.lowerBound, 21)
    }

    func testNothingWhenTheParagraphIsNotOnScreen() {
        let paragraph = "Цього абзацу на екрані немає."
        let lines = ["Зовсім інший текст тут."]
        XCTAssertEqual(ScreenTextAlignment.spots(of: 0..<5, in: paragraph, lines: lines), [])
    }
}

final class EmojiCatalogTests: XCTestCase {
    private func catalog(_ language: String) throws -> EmojiCatalog {
        try XCTUnwrap(EmojiCatalog.load(language: language, maxVersion: 16.0))
    }

    func testFindsByUkrainianName() throws {
        let uk = try catalog("uk")
        XCTAssertGreaterThan(uk.entries.count, 1800)
        XCTAssertTrue(uk.search("сміх").contains("😄"))
        XCTAssertEqual(uk.search("червоне серце").first, "❤️")
        XCTAssertTrue(uk.search("серц").contains("❤️"))
    }

    func testFindsByEnglishName() throws {
        let en = try catalog("en")
        XCTAssertEqual(en.search("thumbs up").first, "👍")
        XCTAssertTrue(en.search("smile").contains("😄"))
        XCTAssertNotEqual(en.search("smile").first, "😼")
        XCTAssertEqual(en.search("fire").first, "🔥")
    }

    func testSectionsAreRecentThenGroups() throws {
        let uk = try catalog("uk")
        let sections = uk.sections(recent: ["🔥", "😂"])
        XCTAssertEqual(sections.first, EmojiCatalog.Section(group: nil, emojis: ["🔥", "😂"]))
        XCTAssertEqual(sections.dropFirst().map(\.group), EmojiCatalog.Group.allCases.map { $0 })
        XCTAssertEqual(sections[1].emojis.first, "😀")
        XCTAssertTrue(try XCTUnwrap(sections.first { $0.group == .food }).emojis.contains("🍕"))
        XCTAssertTrue(try XCTUnwrap(sections.last).emojis.contains("🇺🇦"))
        // None used yet: the smileys first.
        XCTAssertEqual(uk.sections(recent: []).first?.group, .smileys)
    }

    func testRecentComeFirstAmongEquals() throws {
        let uk = try catalog("uk")
        let plain = uk.search("сміх")
        let last = try XCTUnwrap(plain.last)
        XCTAssertNotEqual(plain.first, last)
        let withRecent = uk.search("сміх", recent: [last])
        // Among the equally good ones, the one used lately goes ahead of the rest.
        XCTAssertLessThan(try XCTUnwrap(withRecent.firstIndex(of: last)), try XCTUnwrap(plain.firstIndex(of: last)))
    }

    func testWholeWordMatches() throws {
        let uk = try catalog("uk")
        XCTAssertTrue(uk.matches(word: "серце").contains("❤️"))
        XCTAssertEqual(uk.matches(word: "вогонь").first, "🔥")
        XCTAssertEqual(uk.matches(word: "серце").first, "❤️")
        XCTAssertEqual(uk.matches(word: "ще"), [])
        XCTAssertEqual(uk.matches(word: "столом"), [])
    }

    func testListedRecentFirst() throws {
        let uk = try catalog("uk")
        let listed = uk.listed(recent: ["🔥", "❤️", "not an emoji", "👍", "😄", "🎉", "🙏"])
        XCTAssertEqual(listed.recent, ["🔥", "❤️", "👍", "😄", "🎉"])
        XCTAssertFalse(listed.rest.contains("🔥"))
        XCTAssertTrue(listed.rest.contains("🙏"))
        XCTAssertEqual(listed.recent.count + listed.rest.count, uk.entries.count)
    }

    func testRecorded() {
        XCTAssertEqual(EmojiCatalog.recorded("❤️", in: ["🔥", "❤️", "👍"]), ["❤️", "🔥", "👍"])
        XCTAssertEqual(EmojiCatalog.recorded("🎉", in: ["🔥", "👍"], limit: 2), ["🎉", "🔥"])
    }

    func testEveryLanguageLoads() throws {
        for language in SystemLayouts.supportedLanguages {
            XCTAssertGreaterThan(try catalog(language).entries.count, 1800, language)
        }
        // Emoji of a newer version than the Mac has aren't offered.
        XCTAssertLessThan(try XCTUnwrap(EmojiCatalog.load(language: "en", maxVersion: 15.0)).entries.count, try catalog("en").entries.count)
    }
}

final class KeyRemapTests: XCTestCase {
    // 10: «ґ» on the Ukrainian layout (§ on the US one); 39: «є» / apostrophe; 21: 4.
    let ghe = KeyCombo(keyCode: 10)
    let apostrophe = KeyCombo(keyCode: 39)

    func testAPlainKeyBecomesAnotherAndKeepsItsModifiers() {
        let rules = [KeyRemap(from: ghe, to: apostrophe)]
        XCTAssertEqual(KeyRemapping.output(keyCode: 10, held: [], rules: rules), apostrophe)
        XCTAssertEqual(KeyRemapping.output(keyCode: 10, held: [.shift], rules: rules), KeyCombo(keyCode: 39, modifiers: [.shift]))
        XCTAssertNil(KeyRemapping.output(keyCode: 39, held: [], rules: rules))
    }

    func testACombinationCoversExactlyItsModifiers() {
        let screenshot = KeyCombo(keyCode: 21, modifiers: [.command, .shift])
        let rules = [KeyRemap(from: KeyCombo(keyCode: 10, modifiers: [.option]), to: screenshot)]
        XCTAssertEqual(KeyRemapping.output(keyCode: 10, held: [.option], rules: rules), screenshot)
        XCTAssertNil(KeyRemapping.output(keyCode: 10, held: [], rules: rules))
        XCTAssertNil(KeyRemapping.output(keyCode: 10, held: [.option, .shift], rules: rules))
    }

    func testARuleForTheCombinationWinsOverThePlainKey() {
        let special = KeyCombo(keyCode: 21, modifiers: [.command])
        let rules = [KeyRemap(from: ghe, to: apostrophe), KeyRemap(from: KeyCombo(keyCode: 10, modifiers: [.command]), to: special)]
        XCTAssertEqual(KeyRemapping.output(keyCode: 10, held: [.command], rules: rules), special)
        XCTAssertEqual(KeyRemapping.output(keyCode: 10, held: [.option], rules: rules), KeyCombo(keyCode: 39, modifiers: [.option]))
    }

    func testFnIsIgnoredAndSwapsWorkBothWays() {
        let rules = [KeyRemap(from: ghe, to: apostrophe), KeyRemap(from: ghe, to: apostrophe).reversed]
        XCTAssertEqual(KeyRemapping.output(keyCode: 39, held: [.function], rules: rules), ghe)
        XCTAssertEqual(KeyRemapping.adding(KeyRemap(from: ghe, to: ghe), to: rules).filter { $0.from == ghe }.count, 1)
    }
}

final class VoiceCorrectionApostropheTests: XCTestCase {
    func testAnotherApostropheIsNotACorrection() {
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "Десять дев'ять, вісім.", now: "Десять дев’ять, вісім."), [])
        XCTAssertEqual(VoiceVocabulary.corrections(inserted: "п'ять дев'ять", now: "пʼять девять").map(\.to), ["девять"])
    }
}

final class MergingStoredDataTests: XCTestCase {
    func testVoiceHistoryMergeKeepsBothNewestFirst() {
        var stored = VoiceHistory()
        stored.add("старе", at: Date(timeIntervalSince1970: 100))
        var fresh = VoiceHistory()
        fresh.add("нове", at: Date(timeIntervalSince1970: 200))
        let merged = fresh.merged(with: stored)
        XCTAssertEqual(merged.entries.map(\.text), ["нове", "старе"])
        XCTAssertEqual(merged.merged(with: stored).entries.count, 2)
    }

    func testClipboardMergeKeepsOneCopyAndItsPin() {
        var stored = ClipboardHistory()
        var pinned = ClipItem(kind: .text, text: "a", date: Date(timeIntervalSince1970: 100))
        pinned.pinned = true
        stored.add(pinned, maxItems: 10, maxAge: nil)
        stored.add(ClipItem(kind: .text, text: "b", date: Date(timeIntervalSince1970: 150)), maxItems: 10, maxAge: nil)
        var fresh = ClipboardHistory()
        fresh.add(ClipItem(kind: .text, text: "a", date: Date(timeIntervalSince1970: 300)), maxItems: 10, maxAge: nil)
        let merged = fresh.merged(with: stored)
        XCTAssertEqual(merged.items.map(\.text), ["a", "b"])
        XCTAssertTrue(merged.items[0].pinned)
    }

    func testVoiceStatsMergeAddsCounts() {
        let day = Date(timeIntervalSince1970: 1_793_600_000)
        var stored = VoiceStats()
        stored.addStart(at: day)
        stored.addInserted("привіт світ", at: day)
        stored.addKey(printable: true, interval: 0.5)
        var fresh = VoiceStats()
        fresh.addStart(at: day)
        fresh.addInserted("привіт", at: day)
        let merged = stored.merged(with: fresh)
        XCTAssertEqual(merged.counts(.all, now: day).words, 3)
        XCTAssertEqual(merged.counts(.all, now: day).starts, 2)
        XCTAssertEqual(merged.typedCharacters, 1)
        XCTAssertEqual(merged.topWords(.day, now: day).first?.word, "привіт")
        XCTAssertEqual(merged.topWords(.day, now: day).first?.count, 2)
    }
}

final class SettingsBackupTests: XCTestCase {
    private let remap = KeyRemap(from: KeyCombo(keyCode: 50), to: KeyCombo(keyCode: 10))

    func testRoundTripsThroughAFile() throws {
        let backup = SettingsBackup(keyRemaps: [remap], exceptions: ["npm"], excludedApps: ["com.apple.Terminal"],
                                    replacements: [Replacement(from: "зсу", to: "ЗСУ")],
                                    voiceVocabulary: [Replacement(from: "клавко", to: "Klavko")])
        XCTAssertEqual(try SettingsBackup.read(backup.data()), backup)
    }

    func testAddsTheSpellingDictionaryFromAFile() throws {
        var restored = SettingsBackup()
        restored.grammarWords = ["Klavko", "npm", " "]
        var mine = SettingsBackup()
        mine.grammarWords = ["npm"]
        let read = try SettingsBackup.read(restored.data())
        XCTAssertEqual(read.grammarWords, ["Klavko", "npm", " "])
        let (merged, changes) = mine.merged(with: read)
        XCTAssertEqual(merged.grammarWords, ["klavko", "npm"])
        XCTAssertEqual(changes, 1)
    }

    func testKeepsEveryKindOfSettingThroughAFile() throws {
        let shortcuts = Data(#"{"undo":null,"switch":{"keyCode":49,"modifiers":["option"]}}"#.utf8)
        let values: [String: Any] = ["playSound": true, "duckLevel": 0.2, "clipboardKeepDays": 30, "soundName": "Pop",
                                     "voiceLanguages": ["uk", "en"], "counts": ["так": 2], "shortcuts.v2": shortcuts]
        var backup = SettingsBackup()
        for (key, value) in values { backup.preferences[key] = JSONValue(defaultsValue: value) }
        let read = try SettingsBackup.read(backup.data())
        XCTAssertEqual(read.preferences["playSound"]?.defaultsValue as? Bool, true)
        XCTAssertEqual(read.preferences["duckLevel"]?.defaultsValue as? Double, 0.2)
        XCTAssertEqual(read.preferences["clipboardKeepDays"]?.defaultsValue as? Int, 30)
        XCTAssertEqual(read.preferences["soundName"]?.defaultsValue as? String, "Pop")
        XCTAssertEqual(read.preferences["voiceLanguages"]?.defaultsValue as? [String], ["uk", "en"])
        XCTAssertEqual(read.preferences["counts"]?.defaultsValue as? [String: Int], ["так": 2])
        let data = try XCTUnwrap(read.preferences["shortcuts.v2"]?.defaultsValue as? Data)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: shortcuts) as? NSDictionary)
        XCTAssertTrue(String(decoding: try backup.data(), as: UTF8.self).contains(#""$json""#))
    }

    func testTakesOnlyTheWordsFromAWindowsFile() throws {
        let file = try SettingsBackup.read(Data(#"""
            {"app": "Klavko", "format": 1, "system": "windows", "exceptions": ["Ye"],
             "replacements": [{"from": "кл", "to": "Klavko"}], "voiceVocabulary": [], "startsWithWindows": true,
             "settings": {"LayoutSound": "Pop", "KeyRemaps": [{"From": {"VirtualKey": 192}}]}}
            """#.utf8))
        XCTAssertFalse(file.isFromThisSystem)
        XCTAssertEqual(file.exceptions, ["Ye"])
        XCTAssertEqual(file.replacements, [Replacement(from: "кл", to: "Klavko")])
        XCTAssertTrue(file.preferences.isEmpty && file.keyRemaps.isEmpty && file.launchAtLogin == nil)
        XCTAssertTrue(try SettingsBackup.read(SettingsBackup().data()).isFromThisSystem)
    }

    func testRefusesOtherFiles() {
        XCTAssertThrowsError(try SettingsBackup.read(Data(#"{"exceptions": ["npm"]}"#.utf8)))
        XCTAssertThrowsError(try SettingsBackup.read(Data(#"{"app": "Klavko", "format": 99}"#.utf8)))
        XCTAssertEqual(try SettingsBackup.read(Data(#"{"app": "Klavko", "exceptions": ["ye"]}"#.utf8)).exceptions, ["ye"])
    }

    func testRestoringAddsAndTakesTheFilesRuleForTheSameWord() {
        let mine = SettingsBackup(keyRemaps: [remap], exceptions: ["npm"],
                                  replacements: [Replacement(from: "кл", to: "Клавко")],
                                  voiceVocabulary: [Replacement(from: "Зсу", to: "зсу")])
        let file = SettingsBackup(keyRemaps: [KeyRemap(from: remap.from, to: remap.to)], exceptions: ["NPM", "ye", ""],
                                  excludedApps: ["com.apple.Terminal"],
                                  replacements: [Replacement(from: "кл", to: "Klavko")],
                                  voiceVocabulary: [Replacement(from: "зсу", to: "ЗСУ")])
        let (merged, changes) = mine.merged(with: file)
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(merged.keyRemaps, [remap])
        XCTAssertEqual(merged.exceptions, ["npm", "ye"])
        XCTAssertEqual(merged.excludedApps, ["com.apple.Terminal"])
        XCTAssertEqual(merged.replacements, [Replacement(from: "кл", to: "Klavko")])
        XCTAssertEqual(merged.voiceVocabulary, [Replacement(from: "зсу", to: "ЗСУ")])
        XCTAssertEqual(merged.merged(with: file).changes, 0)
    }
}

final class AppLayoutsTests: XCTestCase {
    private let ukrainian = "com.apple.keylayout.Ukrainian-PC", english = "com.apple.keylayout.ABC"

    func testEachAppGetsTheLayoutLastUsedThere() {
        var layouts = AppLayouts()
        XCTAssertNil(layouts.layout(for: "ru.keepcoder.Telegram"))
        layouts.remember(ukrainian, in: "ru.keepcoder.Telegram")
        layouts.remember(english, in: "com.apple.Terminal")
        layouts.remember(english, in: "ru.keepcoder.Telegram")
        layouts.remember(ukrainian, in: "ru.keepcoder.Telegram")
        XCTAssertEqual(layouts.layout(for: "ru.keepcoder.Telegram"), ukrainian)
        XCTAssertEqual(layouts.layout(for: "com.apple.Terminal"), english)
        XCTAssertEqual(layouts.remembered.map(\.app), ["com.apple.Terminal", "ru.keepcoder.Telegram"])
    }

    func testAPinnedLayoutWins() {
        var layouts = AppLayouts(pinned: ["com.apple.Terminal": english])
        layouts.remember(ukrainian, in: "com.apple.Terminal")
        XCTAssertEqual(layouts.layout(for: "com.apple.Terminal"), english)
    }

    func testForgetsTheLongestUnusedAppsAndRemovedLayouts() {
        var layouts = AppLayouts(pinned: ["com.apple.Terminal": "gone"])
        for index in 0...AppLayouts.limit { layouts.remember(english, in: "app\(index)") }
        XCTAssertEqual(layouts.remembered.count, AppLayouts.limit)
        XCTAssertNil(layouts.layout(for: "app0"))
        layouts.remember(ukrainian, in: "app5")
        layouts.keepOnly(layouts: [ukrainian])
        XCTAssertEqual(layouts.remembered.map(\.app), ["app5"])
        XCTAssertTrue(layouts.pinned.isEmpty)
    }
}

final class VoiceCommandsTests: XCTestCase {
    private func apply(_ text: String) -> String { VoiceCommands.apply(text, languages: ["uk", "en"]) }

    func testPunctuationSticksToTheWordBefore() {
        XCTAssertEqual(apply("привіт кома як справи знак питання"), "привіт, як справи?")
        XCTAssertEqual(apply("до завтра крапка дякую"), "до завтра. Дякую")
        XCTAssertEqual(apply("увага знак оклику"), "увага!")
        XCTAssertEqual(apply("список двокрапка хліб кома молоко крапка з комою"), "список: хліб, молоко;")
        XCTAssertEqual(apply("see you comma Anna period"), "see you, Anna.")
    }

    func testThePausesTheRecognizerMarkedGo() {
        XCTAssertEqual(apply("Привіт. Кома. Як справи"), "Привіт, як справи")
        XCTAssertEqual(apply("Привіт, кома, як справи. Знак питання."), "Привіт, як справи?")
        XCTAssertEqual(apply("До завтра. Крапка."), "До завтра.")
    }

    func testLinesAndParagraphs() {
        XCTAssertEqual(apply("до завтра крапка новий абзац дякую"), "до завтра.\n\nДякую")
        XCTAssertEqual(apply("перше новий рядок друге"), "перше\nДруге")
        XCTAssertEqual(apply("Новий абзац. Дякую"), "\n\nДякую")
        XCTAssertEqual(apply("hello new line world"), "hello\nWorld")
        XCTAssertEqual(apply("я працюю крапка новий рядок так"), "я працюю.\nТак")
        XCTAssertEqual(apply("Я працюю. Крапка. Новий рядок. Так"), "Я працюю.\nТак")
    }

    func testDashesQuotesAndBrackets() {
        XCTAssertEqual(apply("Київ тире столиця"), "Київ — столиця")
        XCTAssertEqual(apply("Це мені підходить, даре, і я хочу це зробити крапко."), "Це мені підходить — і я хочу це зробити.")
        XCTAssertEqual(apply("Це мені підходить тере і я хочу"), "Це мені підходить — і я хочу")
        XCTAssertEqual(apply("він сказав відкрити лапки так закрити лапки"), "він сказав «так»")
        XCTAssertEqual(apply("Я перевіряю відкриті лапки, слово закрите лапки."), "Я перевіряю «слово».")
        XCTAssertEqual(apply("Я перевіряю, відкрила бки слово закрила бки."), "Я перевіряю «слово».")
        XCTAssertEqual(apply("Він сказав відкрити лапки так закрити лапки. Далі"), "Він сказав «так». Далі")
        XCTAssertEqual(apply("слово відкрити дужку пояснення закрити дужку далі"), "слово (пояснення) далі")
        XCTAssertEqual(apply("Зроби так відкрити душку, вибрати закрити душку."), "Зроби так (вибрати).")
        XCTAssertEqual(apply("he said open quote yes close quote"), "he said “yes”")
    }

    func testOtherFormsAndNounsStayText() {
        XCTAssertEqual(apply("поставив крапку в кінці"), "поставив крапку в кінці")
        XCTAssertEqual(apply("тут потрібна кома"), "тут потрібна кома")
        XCTAssertEqual(apply("a period of time"), "a period of time")
        XCTAssertEqual(apply("комар і кома"), "комар і кома")
        XCTAssertEqual(apply("комарі літають"), "комарі літають")
    }

    func testLiterallyWritesTheWord() {
        XCTAssertEqual(apply("слово буквально кома означає знак"), "слово кома означає знак")
        XCTAssertEqual(apply("буквально новий рядок і далі"), "новий рядок і далі")
    }

    func testCommandsOnTheirOwnAndInARow() {
        XCTAssertEqual(apply("Крапка."), ".")
        XCTAssertEqual(apply("кома"), ",")
        XCTAssertEqual(apply("Як справи? Знак питання. Новий абзац. Добре"), "Як справи?\n\nДобре")
    }

    func testOnlyTheChosenLanguages() {
        XCTAssertEqual(VoiceCommands.apply("hello comma world", languages: ["uk"]), "hello comma world")
        XCTAssertEqual(VoiceCommands.apply("привіт кома", languages: ["de"]), "привіт кома")
    }
}
