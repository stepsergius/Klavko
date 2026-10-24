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
