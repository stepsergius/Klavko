import AppKit
import AVFoundation
import FluidAudio
import KlavkoCore
import Speech
import SwiftUI

/// Local voice input: records the microphone, recognizes speech on this Mac (macOS speech recognition,
/// on-device only — no audio leaves the computer) and types the text at the caret.
///
/// macOS runs one on-device recognition at a time, so in automatic mode it listens in the layout's
/// language and keeps the audio; when you stop, the recording is recognized again in the other language
/// and the text with more real words of its language wins. (Checking only "doubtful" results isn't enough:
/// Ukrainian speech heard as English can still be mostly English words — "Super Vika yak no soda".)
@MainActor
final class VoiceDictation: ObservableObject {
    enum Stage: Equatable {
        case idle
        case listening
        case finishing
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle {
        // With no panel during dictation, a problem still needs saying: a small one shows it.
        didSet { if case .failed = stage, shownLook.style == .hidden { showPanel() } }
    }
    /// How voice input looks (from Settings): the panel's style, where it is, whether it shows the text.
    var look: () -> VoiceLook = { VoiceLook() }
    /// The look of the current recording, taken when it starts.
    @Published private(set) var shownLook = VoiceLook()
    /// The camera notch of the screen the panel is on (zero width without one), for the Dynamic Island look.
    @Published private(set) var notch = CGSize(width: 0, height: 24)
    /// The island is out of the notch: it grows from it when shown and shrinks back into it before hiding.
    @Published private(set) var islandOut = false
    private var islandHide: DispatchWorkItem?
    @Published private(set) var text = ""
    @Published private(set) var languageTitle = ""

    /// Languages to consider ("uk", "en"); asked each time recording starts.
    var languages: () -> [String] = { ["uk", "en"] }
    /// The better recognizer, once its model is downloaded; macOS speech recognition otherwise.
    var parakeet: ParakeetEngine?
    /// Google AI, when the user chose it and saved a key: it then recognizes the finished recording
    /// (any language); the recognizers on this Mac stay the fallback.
    var google: () -> (transcriber: GeminiTranscriber, key: String, model: String, smart: Bool)? = { nil }
    /// The language to listen in first (the keyboard layout's).
    var preferredLanguage: () -> String = { "uk" }
    /// The user's spellings ("зсу" → "ЗСУ"), applied to everything recognized.
    var vocabulary: () -> [Replacement] = { [] }
    /// Called with the text after it was typed (key tracking starts afresh; corrections get watched).
    var onInserted: (String) -> Void = { _ in }
    /// The microphone to record from (a device UID); nil: the one chosen in macOS.
    var microphone: () -> String? = { nil }
    /// While listening, other sound is turned down to this share of its volume; nil: left alone.
    var duckLevel: () -> Double? = { nil }

    var isActive: Bool { stage == .listening || stage == .finishing }

    /// The microphone's loudness for the panel's wave.
    let meter = VoiceMeter()

    private let audio = AVAudioEngine()
    private let ducker = SoundDucker()
    private let fanout = AudioFanout()
    private let spellChecker = MacSpellChecker()
    private var live: Recognition?
    private var others: [String] = []
    private var panel: NSPanel?
    /// Insert when the result is ready (false: cancelled).
    private var insertOnFinish = false
    private var secondPassRunning = false
    /// Languages the user speaks (from settings) for this recording.
    private var allowed: [String] = ["uk", "en"]
    private var completed = false
    /// Numbers each recording. Timers and results check it, so a late one from an earlier recording
    /// can't finish (and insert into) the current one.
    private var session = 0
    private var finishingSince: Date?

    /// The hotkey: starts listening, or finishes and inserts what was heard.
    func toggle() {
        switch stage {
        case .listening:
            finish()
        case .finishing:
            // Recognition should take well under a second; if it's stuck, let the key start afresh.
            if let since = finishingSince, Date().timeIntervalSince(since) > 5 {
                Log.engine.notice("Voice input was stuck finishing; starting over")
                start()
            }
        case .idle, .failed:
            start()
        }
    }

    /// Return / Enter while dictating inserts what was heard (and never reaches the app, where it
    /// could send a half-written message); used up while recognizing too.
    func handleReturn() -> Bool {
        switch stage {
        case .listening:
            finish()
            return true
        case .finishing:
            return true
        case .idle, .failed:
            return false
        }
    }

    func cancel() {
        session += 1
        insertOnFinish = false
        stopAudio()
        live?.cancel()
        cleanUp()
    }

    // MARK: - Recording

    private func start() {
        cancel()
        text = ""
        completed = false
        let codes = languages()
        let first = codes.contains(preferredLanguage()) ? preferredLanguage() : (codes.first ?? "uk")
        others = codes.filter { $0 != first }
        allowed = codes
        // Load Parakeet while the user speaks.
        if let parakeet, parakeet.isDownloaded { parakeet.prepare() }
        languageTitle = Self.title(first)
        shownLook = look()
        showPanel()
        let current = session
        Task { [weak self] in
            guard let self else { return }
            let permitted = await Self.requestPermissions()
            guard session == current else { return }
            guard permitted else {
                stage = .failed(tr("Немає доступу до мікрофона або розпізнавання мовлення. Дозвольте його в System Settings → Privacy & Security.",
                                     "No access to the microphone or speech recognition. Allow it in System Settings → Privacy & Security."))
                return
            }
            begin(first)
        }
    }

    private func begin(_ preferred: String) {
        // macOS may not have the on-device model for a language yet: listen in the next one the user speaks.
        var code = preferred
        if Self.recognizer(code) == nil, let available = others.first(where: { Self.recognizer($0) != nil }) {
            others = others.filter { $0 != available }
            code = available
            languageTitle = Self.title(code)
        }
        // Google AI hears any language: if macOS has none of the chosen ones, record with any recognizer
        // (its text is only the preview and the fallback).
        if Self.recognizer(code) == nil, google() != nil, let any = ["en", "uk"].first(where: { Self.recognizer($0) != nil }) {
            code = any
        }
        guard let recognizer = Self.recognizer(code) else {
            stage = .failed(tr("Розпізнавання мовлення на пристрої недоступне. Увімкніть Диктування в System Settings → Keyboard, щоб macOS завантажила мовні моделі.",
                           "On-device speech recognition isn’t available. Turn on Dictation in System Settings → Keyboard so macOS downloads the language models."))
            return
        }
        let recognition = Recognition(language: code, recognizer: recognizer, fanout: fanout,
                                      isListening: { [weak self] in self?.stage == .listening },
                                      changed: { [weak self] in self?.update() })
        live = recognition
        fanout.startRecording(keep: !others.isEmpty || parakeet?.isDownloaded == true || google() != nil)
        let meter = meter
        fanout.onLevel = { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { meter.push(level) } }
        }
        Self.use(microphone(), for: audio.inputNode)
        Self.feed(audio.inputNode, into: fanout)
        recognition.startSegment()
        audio.prepare()
        do {
            try audio.start()
        } catch {
            stage = .failed(tr("Не вдалося увімкнути мікрофон: ", "Couldn’t turn on the microphone: ") + error.localizedDescription)
            return
        }
        insertOnFinish = true
        stage = .listening
        if let level = duckLevel() { ducker.duck(to: level) }
        schedulePreview(after: 1.0)
        Log.engine.notice("Voice input started (\(code, privacy: .public))")
    }

    private func update() {
        guard let live else { return }
        // With Parakeet the panel shows its text (in whatever language is spoken), not macOS's guess.
        if !(parakeet?.isDownloaded == true && parakeetUsable) { text = VoiceVocabulary.apply(live.text, rules: vocabulary()) }
        if live.failedForGood, stage == .listening {
            stopAudio()
            stage = .failed(tr("Розпізнавання мовлення не працює. Перевірте мікрофон і Диктування в System Settings → Keyboard.",
                               "Speech recognition isn’t working. Check the microphone and Dictation in System Settings → Keyboard."))
            return
        }
        if stage == .finishing, live.isDone { liveFinished() }
    }

    /// Stop listening; the recognizer then delivers its final text.
    private func finish() {
        stage = .finishing
        finishingSince = Date()
        stopAudio()
        live?.endAudio()
        // If no final result comes (e.g. nothing was said), don't hang.
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, session == current, stage == .finishing, !secondPassRunning else { return }
            liveFinished()
        }
    }

    private func liveFinished() {
        guard !completed, !secondPassRunning, let live else { return }
        let heard = live.text
        if let google = google(), fanout.hasRecording {
            finishWithGoogle(google, liveResult: (language: live.language, text: heard))
            return
        }
        if let parakeet, parakeet.isDownloaded, parakeetUsable, fanout.hasRecording {
            finishWithParakeet(parakeet, liveResult: (language: live.language, text: heard))
            return
        }
        guard let other = others.first, fanout.hasRecording else {
            complete(with: heard, language: live.language)
            return
        }
        recognizeAgain(in: other, comparingWith: (language: live.language, text: heard))
    }

    /// Recognizes the whole recording with Google AI. If that fails (no internet, quota), Parakeet or the
    /// live macOS result is used, so the dictation is never lost.
    private func finishWithGoogle(_ google: (transcriber: GeminiTranscriber, key: String, model: String, smart: Bool),
                                  liveResult: (language: String, text: String)) {
        guard let file = fanout.writeRecording() else {
            complete(with: liveResult.text, language: liveResult.language)
            return
        }
        secondPassRunning = true
        languageTitle = "Google AI"
        let words = vocabulary().map(\.to)
        let current = session
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let text = try await google.transcriber.transcribe(file: file, key: google.key, model: google.model,
                                                                    smart: google.smart, vocabulary: words)
                guard let self, session == current else { return }
                guard text.isEmpty else { return complete(with: text, language: "google") }
                Log.engine.notice("Google AI heard nothing; using this Mac's result")
                fallBack(from: liveResult)
            } catch {
                Log.engine.error("Google AI failed: \(error.localizedDescription, privacy: .public)")
                guard let self, session == current else { return }
                fallBack(from: liveResult)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, session == current else { return }
            complete(with: liveResult.text, language: liveResult.language)
        }
    }

    /// Google AI gave nothing: Parakeet if it knows the languages, else the live macOS text.
    private func fallBack(from liveResult: (language: String, text: String)) {
        if let parakeet, parakeet.isDownloaded, parakeetUsable {
            finishWithParakeet(parakeet, liveResult: liveResult)
        } else {
            complete(with: liveResult.text, language: liveResult.language)
        }
    }

    /// Recognizes the whole recording with Parakeet. It may hear Ukrainian as Russian; unless Russian is one
    /// of the chosen languages, such a result is redone by the macOS Ukrainian recognizer.
    private func finishWithParakeet(_ parakeet: ParakeetEngine, liveResult: (language: String, text: String)) {
        guard let file = fanout.writeRecording() else {
            complete(with: liveResult.text, language: liveResult.language)
            return
        }
        secondPassRunning = true
        let ukrainianAllowed = allowed.contains("uk")
        let russianAllowed = allowed.contains("ru")
        let hint = parakeetHint
        let current = session
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                guard let self else { return }
                var text = try await parakeetText(parakeet, file: file, hint: hint)
                var language = "parakeet"
                if (LanguageGuess.looksRussian(text) && !russianAllowed) || (text.isEmpty && ukrainianAllowed) {
                    Log.engine.notice("Parakeet result unusable; redoing with the Ukrainian recognizer")
                    text = ukrainianAllowed ? await Self.recognize(file: file, language: "uk") : ""
                    language = "uk (macOS)"
                }
                guard session == current else { return }
                complete(with: text, language: language)
            } catch {
                Log.engine.error("Parakeet failed: \(error.localizedDescription, privacy: .public)")
                guard let self, session == current else { return }
                complete(with: liveResult.text, language: liveResult.language)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, session == current else { return }
            complete(with: liveResult.text, language: liveResult.language)
        }
    }

    /// Parakeet's text of a recording, in Ukrainian or English. Left to pick the language itself, it now and
    /// then hears Ukrainian as another Latin-script language ("Přiby v texті z opisu zhádku"); then the
    /// recording is recognized again as Ukrainian, and for plain Latin text that isn't clearly English the
    /// version with more real words wins.
    private func parakeetText(_ parakeet: ParakeetEngine, file: URL, hint: Language?) async throws -> String {
        let text = try await parakeet.transcribe(file: file, language: hint)
        // The checks below are for telling Ukrainian from English; with other languages, Parakeet's own pick stands.
        guard Set(allowed).isSubset(of: ["uk", "en"]) else { return text }
        guard hint == nil, allowed.contains("uk"), !text.isEmpty, !LanguageGuess.looksRussian(text) else { return text }
        let foreign = LanguageGuess.looksForeignLatin(text)
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        if !foreign && cyrillic { return text }
        if !foreign && LanguageGuess.wordShare(text, language: "en", spellChecker: spellChecker) >= 0.6 { return text }
        let ukrainian = try await parakeet.transcribe(file: file, language: .ukrainian)
        // Asked for Ukrainian, it is Ukrainian unless it has letters only Russian uses (a short phrase
        // without і, ї, є, ґ is still fine here).
        let russian = ukrainian.lowercased().contains { "ыэъё".contains($0) }
        guard !ukrainian.isEmpty, !russian else { return foreign ? "" : text }
        if foreign {
            Log.engine.notice("Parakeet heard another Latin-script language; using its Ukrainian pass")
            return ukrainian
        }
        return LanguageGuess.best([(language: "en", text: text), (language: "uk", text: ukrainian)],
                                  preferred: preferredLanguage(), spellChecker: spellChecker)?.text ?? text
    }

    /// Developer check: Parakeet's own guess for a recording and the text Klavko would insert.
    func checkParakeet(file: URL) async -> String {
        guard let parakeet else { return "no parakeet" }
        allowed = ["uk", "en"]
        let raw = (try? await parakeet.transcribe(file: file, language: nil)) ?? "error"
        let ukrainian = (try? await parakeet.transcribe(file: file, language: .ukrainian)) ?? "error"
        let final = (try? await parakeetText(parakeet, file: file, hint: nil)) ?? "error"
        return "auto: \(raw)\nuk: \(ukrainian)\nfinal: \(final)"
    }

    /// Languages Parakeet recognizes (of those voice input offers).
    private static let parakeetLanguages: Set<String> = ["uk", "en", "ru", "de", "fr", "es", "it", "pt", "pl", "el"]

    /// Parakeet knows a language the user speaks (not just Turkish, Hebrew or Arabic).
    private var parakeetUsable: Bool { allowed.contains(where: Self.parakeetLanguages.contains) }

    /// All languages spoken share one alphabet: rule out the others outright (that's all the hint does).
    private var parakeetHint: Language? {
        let spoken = allowed.filter(Self.parakeetLanguages.contains)
        let languages = spoken.compactMap(Language.init(rawValue:))
        guard let first = languages.first, languages.allSatisfy({ $0.script == first.script }) else { return nil }
        return first
    }

    /// While listening, recognizes the recording so far with Parakeet again and again, for the panel.
    /// Each pass waits a bit longer than the last one took, so long dictation doesn't hog the Mac.
    private func schedulePreview(after delay: TimeInterval) {
        guard let parakeet, parakeet.isDownloaded, parakeetUsable else { return }
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, session == current, stage == .listening else { return }
            guard let file = fanout.writeRecording() else { return schedulePreview(after: 0.5) }
            let hint = parakeetHint
            let started = Date()
            Task { [weak self] in
                defer { try? FileManager.default.removeItem(at: file) }
                let heard = (try? await self?.parakeetText(parakeet, file: file, hint: hint)) ?? ""
                guard let self, session == current, stage == .listening else { return }
                if !heard.isEmpty, !LanguageGuess.looksRussian(heard) || allowed.contains("ru") {
                    text = VoiceVocabulary.apply(heard, rules: vocabulary())
                }
                schedulePreview(after: max(0.7, Date().timeIntervalSince(started) * 1.5))
            }
        }
    }

    private func recognizeAgain(in code: String, comparingWith first: (language: String, text: String)) {
        guard let file = fanout.writeRecording() else {
            complete(with: first.text, language: first.language)
            return
        }
        languageTitle = tr("перевіряю: ", "checking: ") + Self.title(code)
        secondPassRunning = true
        let current = session
        Task { [weak self] in
            let heard = await Self.recognize(file: file, language: code)
            try? FileManager.default.removeItem(at: file)
            guard let self, session == current else { return }
            let best = LanguageGuess.best([first, (language: code, text: heard)],
                                          preferred: first.language, spellChecker: spellChecker) ?? first
            Log.engine.notice("Voice input compared \(first.language, privacy: .public) with \(code, privacy: .public)")
            complete(with: best.text, language: best.language)
        }
        // Don't wait forever for the second opinion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, session == current else { return }
            complete(with: first.text, language: first.language)
        }
    }

    private func complete(with result: String, language: String) {
        guard !completed else { return }
        completed = true
        session += 1  // anything still pending belongs to a finished recording now
        if insertOnFinish && !result.isEmpty {
            insert(result)
            Log.engine.notice("Voice input chose \(language, privacy: .public)")
        }
        live?.cancel()
        cleanUp()
    }

    private func insert(_ heard: String) {
        insertOnFinish = false
        let text = VoiceVocabulary.apply(heard, rules: vocabulary())
        // Separate from the word before the caret, if there is one.
        let before = CaretContext.textBeforeCaret(limit: 1) ?? ""
        let spaced = (before.last.map { !$0.isWhitespace } ?? false) ? " " + text : text
        TextInjector.type(spaced)
        onInserted(text)
        Log.engine.notice("Voice input inserted \(text.count) chars")
    }

    private func stopAudio() {
        ducker.restore()
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        fanout.onLevel = nil
        meter.reset()
    }

    private func cleanUp() {
        live = nil
        secondPassRunning = false
        fanout.reset()
        if case .failed = stage { return }  // keep the message on screen until closed
        stage = .idle
        hidePanel()
    }

    /// Recognizes a whole recording. macOS reports each phrase after a pause from scratch, so partial
    /// results are joined like in live recognition. "" if nothing was heard or the language is unavailable.
    static func recognize(file: URL, language code: String) async -> String {
        guard let recognizer = recognizer(code) else { return "" }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        return await withCheckedContinuation { continuation in
            let joiner = PhraseCollector()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let heard = result?.bestTranscription.formattedString { joiner.add(heard) }
                if result?.isFinal == true || error != nil {
                    joiner.finish { continuation.resume(returning: $0) }
                }
            }
        }
    }

    /// Developer check: recognizes an audio file in Ukrainian, then English, and prints both with the choice.
    static func check(file: URL) async -> String {
        guard await requestPermissions() else { return "no permission" }
        var results: [(language: String, text: String)] = []
        for code in ["uk", "en"] {
            results.append((code, await recognize(file: file, language: code)))
        }
        let checker = MacSpellChecker()
        let lines = results.map { "\($0.language) [\(String(format: "%.2f", LanguageGuess.wordShare($0.text, language: $0.language, spellChecker: checker)))]: \($0.text)" }
        let best = LanguageGuess.best(results, preferred: "en", spellChecker: checker)
        return (lines + ["chosen (layout en): \(best?.language ?? "-")"]).joined(separator: "\n")
    }

    private static func recognizer(_ code: String) -> SFSpeechRecognizer? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locales[code] ?? code)),
              recognizer.supportsOnDeviceRecognition else { return nil }
        return recognizer
    }

    private static let locales = ["uk": "uk-UA", "en": "en-US", "ru": "ru-RU", "de": "de-DE", "fr": "fr-FR", "es": "es-ES",
                                  "it": "it-IT", "pt": "pt-BR", "pl": "pl-PL", "tr": "tr-TR", "el": "el-GR", "he": "he-IL",
                                  "ar": "ar-SA"]

    /// The language's name in the interface language ("українська", "Russian").
    private static func title(_ code: String) -> String {
        AppLanguage.current.locale.localizedString(forLanguageCode: code) ?? code
    }

    // Audio and recognition callbacks come on background threads, so they're built outside the main actor.

    /// Records from the chosen microphone, or from the one chosen in macOS when it's unset or unplugged.
    private static func use(_ uid: String?, for input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        guard var device = uid.flatMap(AudioDevices.deviceID(uid:)) ?? AudioDevices.defaultInput else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { Log.engine.error("Microphone not set: \(status)") }
    }

    /// Sends the microphone's audio to the running recognition (and the recording).
    private nonisolated static func feed(_ input: AVAudioInputNode, into fanout: AudioFanout) {
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            fanout.append(buffer)
        }
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Indicator

    /// Developer check of the indicator's look: renders it while listening, with sample text.
    func snapshot(to url: URL) {
        stage = .listening
        languageTitle = "українська"
        text = "Привіт, я диктую цей текст голосом, а Klavko вставить його туди, де стоїть курсор."
        for index in 0..<VoiceMeter.count { meter.push(Float(0.02 + 0.1 * abs(sin(Double(index) / 3)))) }
        shownLook = look()
        if shownLook.style == .island { notch = Self.notch(of: NSScreen.main) }
        let view = NSHostingView(rootView: VoicePanelView(dictation: self, meter: meter)
            .background(Color(white: 0.9)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Developer check of the panel on screen: shows it as while listening, with sample text, for a few seconds.
    func demo(seconds: Double = 8) {
        shownLook = look()
        stage = .listening
        text = "Привіт, я диктую цей текст голосом, а Klavko вставить його туди, де стоїть курсор. "
            + "Коли тексту багато, перші рядки ховаються вгорі, а видно останні — те, що ви щойно сказали."
        for index in 0..<VoiceMeter.count { meter.push(Float(0.02 + 0.1 * abs(sin(Double(index) / 3)))) }
        showPanel()
        // The end of a recording too: recognizing for a moment, then away.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds - 1.5) { [weak self] in self?.stage = .finishing }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.stage = .idle
            self?.hidePanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.text = "" }
        }
    }

    fileprivate func closeFailure() {
        stage = .idle
        hidePanel()
    }

    private var resizeObserver: NSObjectProtocol?

    private var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    private func showPanel() {
        // "No window": nothing on screen while dictating (a problem is still shown).
        guard shownLook.style != .hidden || isFailed else { return hidePanel() }
        if panel == nil {
            let hosting = NSHostingController(rootView: VoicePanelView(dictation: self, meter: meter))
            hosting.sizingOptions = [.preferredContentSize]
            let panel = IndicatorPanel(contentViewController: hosting)
            panel.styleMask = [.nonactivatingPanel, .borderless]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false  // the capsule and the bubble draw their own
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none  // the island animates itself; no system fade on top
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
            // The text grows the panel upwards; keep it centred at the bottom.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placePanel() }
            }
        }
        // The island sits over the menu bar, under the notch; the windows stay below it.
        panel?.level = shownLook.style == .island && !isFailed ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .statusBar
        if let screen = targetScreen() { notch = Self.notch(of: screen) }
        (panel as? IndicatorPanel)?.keepsTop = (shownLook.style == .island && !isFailed) || shownLook.position == .top
        placePanel()
        // Never takes the keyboard: typing goes on in the app where the text will be inserted.
        islandHide?.cancel()
        islandHide = nil
        panel?.orderFrontRegardless()
        if !islandOut { DispatchQueue.main.async { self.islandOut = true } }
    }

    /// The screen with the mouse (the panel's own while it's shown).
    private func targetScreen() -> NSScreen? {
        if let panel, panel.isVisible { return panel.screen ?? NSScreen.main }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// The camera notch: its width (0 without one) and the height of the menu bar.
    static func notch(of screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 0, height: 24) }
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: max(right.minX - left.maxX, 0), height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 0, height: barHeight)
    }

    /// Centred: at the bottom above the Dock, at the top under the menu bar, or, as an island, at the very
    /// top under the camera notch. It grows away from the edge it is at.
    private func placePanel() {
        guard let panel, let screen = targetScreen() else { return }
        let frame = screen.visibleFrame
        var origin = NSPoint(x: (frame.midX - panel.frame.width / 2).rounded(), y: frame.minY + 24)
        if shownLook.style == .island && !isFailed {
            var centre = screen.frame.midX
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
                centre = screen.frame.minX + (left.maxX + right.minX) / 2
            }
            origin = NSPoint(x: (centre - panel.frame.width / 2).rounded(), y: screen.frame.maxY - panel.frame.height)
        } else if shownLook.position == .top {
            origin.y = frame.maxY - panel.frame.height - 6
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible, shownLook.style == .island, !isFailed, islandOut else {
            islandOut = false
            self.panel?.orderOut(nil)
            return
        }
        // Back into the notch first, then away.
        islandOut = false
        let hide = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.islandHide = nil
        }
        islandHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandIndicator.closing, execute: hide)
    }
}

/// Recent microphone loudness, newest last, each 0…1; drives the panel's wave.
@MainActor
final class VoiceMeter: ObservableObject {
    static let count = 28
    @Published private(set) var levels = [CGFloat](repeating: 0, count: VoiceMeter.count)

    /// `rms` of one audio buffer.
    func push(_ rms: Float) {
        // Speech sits around -50…-10 dB; map that range to 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        let level = CGFloat(min(max((decibels + 52) / 40, 0), 1))
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.count)
    }
}

/// Its buttons take a click without activating Klavko.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// At the top of the screen the panel grows and shrinks downwards: its top edge stays where it is,
    /// so a change of height never makes it jump (AppKit would keep the bottom edge instead).
    var keepsTop = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if keepsTop, isVisible, rect.height != frame.height { rect.origin.y = frame.maxY - rect.height }
        super.setFrame(rect, display: flag)
    }
}

/// Klavko's icon colours, for the voice panel's glow.
enum Neon {
    static let blue = Color(red: 0.01, green: 0.47, blue: 0.99)
    static let sky = Color(red: 0.22, green: 0.66, blue: 1.0)
    static let cyan = Color(red: 0.55, green: 0.88, blue: 1.0)
    static let yellow = Color(red: 1.0, green: 0.79, blue: 0.12)
    static let navy = LinearGradient(colors: [Color(red: 0.04, green: 0.10, blue: 0.26),
                                              Color(red: 0.01, green: 0.04, blue: 0.14)],
                                     startPoint: .top, endPoint: .bottom)
    static let rim = LinearGradient(colors: [cyan.opacity(0.9), blue.opacity(0.9), sky.opacity(0.6)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let bar = LinearGradient(colors: [.white, cyan, sky], startPoint: .top, endPoint: .bottom)
}

/// The panel in the look chosen in Settings.
private struct VoicePanelView: View {
    @ObservedObject var dictation: VoiceDictation
    @ObservedObject var meter: VoiceMeter

    var body: some View {
        if dictation.shownLook.style == .island, !isFailed {
            IslandIndicator(dictation: dictation, meter: meter)
        } else {
            VoiceIndicator(dictation: dictation, meter: meter,
                           metrics: dictation.shownLook.style == .large ? .large : .small,
                           atTop: dictation.shownLook.position == .top)
        }
    }

    private var isFailed: Bool {
        if case .failed = dictation.stage { return true }
        return false
    }
}

/// Sizes of the panel: the large one, and the small one, about half of it.
private struct IndicatorMetrics {
    let width: CGFloat
    let waveWidth: CGFloat
    let waveHeight: CGFloat
    let bars: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let button: CGFloat
    let symbol: CGFloat
    let dot: CGFloat
    let text: CGFloat
    let hint: CGFloat
    let showsHint: Bool
    let lines: Int
    let corner: CGFloat
    let padding: CGFloat
    /// Between the buttons, the dot and the wave in the capsule.
    let gap: CGFloat

    static let large = IndicatorMetrics(width: 440, waveWidth: 150, waveHeight: 28, bars: 28, barWidth: 3, barSpacing: 3,
                                        button: 26, symbol: 11, dot: 6, text: 14, hint: 11, showsHint: true, lines: 4,
                                        corner: 14, padding: 14, gap: 9.8)
    static let small = IndicatorMetrics(width: 230, waveWidth: 34, waveHeight: 16, bars: 9, barWidth: 2, barSpacing: 2,
                                        button: 18, symbol: 8, dot: 4, text: 12, hint: 9.5, showsHint: false, lines: 3,
                                        corner: 10, padding: 9, gap: 4)
}

/// A glowing navy capsule with a live wave and a bubble with what is being heard: above the capsule when the
/// panel is at the bottom, below it when the panel is at the top.
private struct VoiceIndicator: View {
    @ObservedObject var dictation: VoiceDictation
    @ObservedObject var meter: VoiceMeter
    let metrics: IndicatorMetrics
    let atTop: Bool

    private var showsBubble: Bool {
        if case .failed = dictation.stage { return true }
        return dictation.shownLook.showText
    }

    var body: some View {
        VStack(spacing: metrics.padding * 0.7) {
            if !atTop && showsBubble { bubble }
            capsule
            if atTop && showsBubble { bubble }
        }
        .frame(width: showsBubble ? metrics.width : nil)
        .padding(.vertical, 18)
        .padding(.horizontal, 22)  // room for the glow
    }

    /// How loud it is right now, 0…1: the glow breathes with the voice.
    private var loudness: CGFloat {
        guard dictation.stage == .listening else { return dictation.stage == .finishing ? 0.4 : 0 }
        let recent = meter.levels.suffix(4)
        return recent.reduce(0, +) / CGFloat(max(recent.count, 1))
    }

    // MARK: Bubble with the text

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: metrics.padding * 0.4) {
            if case .failed(let message) = dictation.stage {
                Text(message)
                    .font(.system(size: metrics.text - 1))
                    .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LastLinesText(text: dictation.text.isEmpty ? tr("Говоріть…", "Speak…") : dictation.text,
                              size: metrics.text, width: metrics.width - 2 * metrics.padding, lines: metrics.lines,
                              opacity: dictation.text.isEmpty ? 0.55 : 0.96)
                if metrics.showsHint {
                    Text(hint)
                        .font(.system(size: metrics.hint))
                        .foregroundStyle(Neon.cyan.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.vertical, metrics.padding * 0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: metrics.corner, style: .continuous).fill(Neon.navy).opacity(0.94))
        .overlay(RoundedRectangle(cornerRadius: metrics.corner, style: .continuous).strokeBorder(Neon.rim, lineWidth: 1).opacity(0.55))
        .shadow(color: Neon.blue.opacity(0.35), radius: 12)
    }

    private var hint: String {
        switch dictation.stage {
        case .finishing: tr("Розпізнаю…", "Recognizing…")
        default: tr("Enter або гаряча клавіша — вставити · Esc — скасувати", "Return or the hotkey — insert · Esc — cancel")
        }
    }

    // MARK: Capsule with the wave

    private var capsule: some View {
        HStack(spacing: metrics.gap) {
            VoiceButton(kind: .cancel, size: metrics.button, symbol: metrics.symbol, dictation: dictation)
            // The yellow dot from the icon: on while listening.
            Circle()
                .fill(Neon.yellow)
                .frame(width: metrics.dot, height: metrics.dot)
                .shadow(color: Neon.yellow.opacity(0.9), radius: 4)
                .opacity(dictation.stage == .listening ? 1 : 0.3)
            VoiceWave(dictation: dictation, meter: meter, bars: metrics.bars, barWidth: metrics.barWidth,
                      spacing: metrics.barSpacing, height: metrics.waveHeight)
                .frame(width: metrics.waveWidth, height: metrics.waveHeight)
            if dictation.stage == .listening {
                VoiceButton(kind: .insert, size: metrics.button, symbol: metrics.symbol, dictation: dictation)
            } else {
                Color.clear.frame(width: metrics.button, height: metrics.button)
            }
        }
        .padding(.horizontal, metrics.padding * 0.5)
        .padding(.vertical, metrics.padding * 0.43)
        .background(Capsule().fill(Neon.navy))
        .overlay(Capsule().strokeBorder(Neon.rim, lineWidth: 1.2))
        // Neon glow that swells as you speak.
        .shadow(color: Neon.blue.opacity(0.45 + 0.45 * loudness), radius: 6 + 14 * loudness)
        .shadow(color: Neon.cyan.opacity(0.25 * loudness), radius: 3)
        .animation(.easeOut(duration: 0.12), value: loudness)
    }
}

/// Like the iPhone's Dynamic Island: a black pill coming out of the camera notch at the top of the screen,
/// with the dot and the wave beside the notch, and the text heard so far growing out below it.
private struct IslandIndicator: View {
    @ObservedObject var dictation: VoiceDictation
    @ObservedObject var meter: VoiceMeter

    private var showsText: Bool { dictation.shownLook.showText }
    private var notch: CGSize { dictation.notch }
    /// What fits on each side of the notch.
    private static let side: CGFloat = 88
    /// How far the top corners curve out into the top edge of the screen, like the notch's own.
    private static let flare: CGFloat = 10

    private var width: CGFloat { notch.width + 2 * Self.side + (showsText ? 60 : 0) + 2 * Self.flare }
    /// How long the island takes to go back into the notch.
    static let closing = 0.32

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                VoiceButton(kind: .cancel, size: 18, symbol: 8, dictation: dictation)
                Circle()
                    .fill(Neon.yellow)
                    .frame(width: 5, height: 5)
                    .shadow(color: Neon.yellow.opacity(0.9), radius: 3)
                    .opacity(dictation.stage == .listening ? 1 : 0.3)
                Spacer(minLength: max(notch.width, 16))
                VoiceWave(dictation: dictation, meter: meter, bars: 10, barWidth: 2, spacing: 2, height: 14)
                    .frame(width: 40, height: 14)
                if dictation.stage == .listening {
                    VoiceButton(kind: .insert, size: 18, symbol: 8, dictation: dictation)
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: notch.height)
            if showsText {
                // While recognizing, the text stays (dimmed) so the island keeps its size.
                LastLinesText(text: !dictation.text.isEmpty ? dictation.text
                              : dictation.stage == .finishing ? tr("Розпізнаю…", "Recognizing…") : tr("Говоріть…", "Speak…"),
                              size: 12.5, width: width - 2 * Self.flare - 32, lines: 3,
                              opacity: dictation.text.isEmpty || dictation.stage == .finishing ? 0.55 : 0.95)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, Self.flare)
        // The content comes in once the island has room for it and goes before it shrinks.
        .opacity(dictation.islandOut ? 1 : 0)
        .scaleEffect(dictation.islandOut ? 1 : 0.92, anchor: .top)
        .animation(dictation.islandOut ? .easeOut(duration: 0.25).delay(0.12) : .easeIn(duration: 0.12),
                   value: dictation.islandOut)
        .frame(width: width)
        .background(
            // The island itself stays solid black: it grows out of the notch and shrinks back into it.
            // Without a notch it comes down from the top edge.
            IslandShape(flare: Self.flare, corner: 18).fill(.black)
                .scaleEffect(x: dictation.islandOut ? 1 : notch.width > 0 ? notch.width / width : 0.4,
                             y: dictation.islandOut ? 1 : notch.width > 0 ? (showsText ? 0.3 : 1) : 0.01,
                             anchor: .top)
                .animation(dictation.islandOut ? .spring(duration: 0.5, bounce: 0.18) : .easeIn(duration: Self.closing),
                           value: dictation.islandOut)
        )
        .animation(.spring(duration: 0.3), value: showsText)
    }
}

/// The island's outline: the top corners curve outwards into the top edge of the screen (no right angles
/// where it meets the menu bar), the bottom corners are rounded.
private struct IslandShape: Shape {
    let flare: CGFloat
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(corner, (h - flare) / 2)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: flare, y: flare), control: CGPoint(x: flare, y: 0))
        path.addLine(to: CGPoint(x: flare, y: h - r))
        path.addQuadCurve(to: CGPoint(x: flare + r, y: h), control: CGPoint(x: flare, y: h))
        path.addLine(to: CGPoint(x: w - flare - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w - flare, y: h - r), control: CGPoint(x: w - flare, y: h))
        path.addLine(to: CGPoint(x: w - flare, y: flare))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - flare, y: 0))
        path.closeSubpath()
        return path
    }
}

/// The text heard so far, at most `lines` lines: when there is more, the latest lines show and the earlier
/// ones move up out of sight, fading at the top. With the pointer over it, the text scrolls back to show
/// what was said before; once the pointer leaves, it goes back to the latest lines.
private struct LastLinesText: View {
    let text: String
    let size: CGFloat
    let width: CGFloat
    let lines: Int
    let opacity: Double

    @State private var hovering = false

    private var font: NSFont { .systemFont(ofSize: size) }
    private var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }
    private var fullHeight: CGFloat {
        ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: [.font: font]).height)
    }

    var body: some View {
        let limit = lineHeight * CGFloat(lines)
        let overflows = fullHeight > limit + 1
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: size))
                    .foregroundStyle(.white.opacity(opacity))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .leading)
                    .id("text")
            }
            .scrollDisabled(!overflows)
            .scrollIndicators(hovering && overflows ? .automatic : .hidden)
            .defaultScrollAnchor(.bottom)
            .frame(width: width, height: overflows ? limit : fullHeight + 2)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(overflows && !hovering ? 0 : 1), .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: lineHeight * 0.8)
                    Color.black
                }
            }
            .onHover { inside in
                hovering = inside
                // Back to what is being said now.
                if !inside { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("text", anchor: .bottom) } }
            }
            // While the user reads earlier lines, new words don't pull the text away from under the pointer.
            .onChange(of: text) {
                guard !hovering else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("text", anchor: .bottom) }
            }
            // The panel can open with the text already long: start at its end once it is laid out.
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("text", anchor: .bottom) } }
            .onChange(of: overflows) { DispatchQueue.main.async { proxy.scrollTo("text", anchor: .bottom) } }
        }
    }
}

/// The ✕ (cancel, or close a problem) and ✓ (insert) buttons.
private struct VoiceButton: View {
    enum Kind { case cancel, insert }
    let kind: Kind
    let size: CGFloat
    let symbol: CGFloat
    @ObservedObject var dictation: VoiceDictation

    var body: some View {
        Button {
            switch kind {
            case .cancel: if case .failed = dictation.stage { dictation.closeFailure() } else { dictation.cancel() }
            case .insert: dictation.toggle()
            }
        } label: {
            Image(systemName: kind == .cancel ? "xmark" : "checkmark")
                .font(.system(size: symbol, weight: .bold))
                .foregroundStyle(.white.opacity(kind == .cancel ? 0.8 : 1))
                .frame(width: size, height: size)
                .background(Circle().fill(kind == .cancel ? AnyShapeStyle(.white.opacity(0.12))
                                          : AnyShapeStyle(LinearGradient(colors: [Neon.sky, Neon.blue], startPoint: .top, endPoint: .bottom))))
                .shadow(color: kind == .insert ? Neon.sky.opacity(0.8) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
        .help(kind == .cancel ? tr("Скасувати (Esc)", "Cancel (Esc)") : tr("Вставити (Enter)", "Insert (Return)"))
    }
}

/// The live wave while listening, a travelling one while recognizing.
private struct VoiceWave: View {
    @ObservedObject var dictation: VoiceDictation
    @ObservedObject var meter: VoiceMeter
    let bars: Int
    let barWidth: CGFloat
    let spacing: CGFloat
    let height: CGFloat

    var body: some View {
        if dictation.stage == .finishing {
            ThinkingWave(bars: bars, barWidth: barWidth, spacing: spacing, height: height)
        } else {
            Waveform(levels: Array(meter.levels.suffix(bars)), muted: dictation.stage != .listening,
                     barWidth: barWidth, spacing: spacing, height: height)
        }
    }
}

/// Bars that follow the voice: the newest loudness in the middle, older ones fading out to the sides.
private struct Waveform: View {
    let levels: [CGFloat]
    let muted: Bool
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var height: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<levels.count, id: \.self) { index in
                Capsule()
                    .fill(Neon.bar)
                    .frame(width: barWidth, height: barHeight(index))
            }
        }
        .opacity(muted ? 0.4 : 1)
        .shadow(color: Neon.sky.opacity(0.9), radius: 3)
        .animation(.easeOut(duration: 0.09), value: levels)
    }

    /// Bars mirror around the centre, which shows the latest level.
    private func barHeight(_ index: Int) -> CGFloat {
        let half = levels.count / 2
        let distance = abs(index - half)
        let level = levels[max(levels.count - 1 - distance * 2, 0)]
        let taper = 1 - CGFloat(distance) / CGFloat(half + 2)
        return 3 + (height - 3) * level * taper
    }
}

/// A gentle travelling wave while the recording is being recognized.
private struct ThinkingWave: View {
    var bars = VoiceMeter.count
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var height: CGFloat = 28

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { index in
                    let phase = sin(time * 5 - Double(index) * 0.45)
                    Capsule()
                        .fill(Neon.bar)
                        .opacity(0.5 + 0.4 * phase)
                        .frame(width: barWidth, height: 4 + (height / 2 - 4) * CGFloat(phase + 1))
                }
            }
            .shadow(color: Neon.sky.opacity(0.8), radius: 3)
        }
    }
}

/// Passes microphone audio to the current recognition request and, when asked, keeps a copy in memory
/// for a second recognition in another language (from the audio thread).
private final class AudioFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var keep = false
    private var recording: [AVAudioPCMBuffer] = []
    /// About three minutes at 48 kHz; longer dictation keeps only the live result.
    private let maxFrames: AVAudioFrameCount = 48_000 * 180
    private var recordedFrames: AVAudioFrameCount = 0
    private var levelHandler: (@Sendable (Float) -> Void)?

    /// Gets each buffer's loudness (RMS), on the audio thread.
    var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { levelHandler } }
        set { lock.withLock { levelHandler = newValue } }
    }

    var hasRecording: Bool { lock.withLock { !recording.isEmpty } }

    func set(_ request: SFSpeechAudioBufferRecognitionRequest, for language: String) {
        lock.withLock { requests[language] = request }
    }

    func startRecording(keep: Bool) {
        lock.withLock {
            self.keep = keep
            recording = []
            recordedFrames = 0
        }
    }

    func reset() {
        lock.withLock {
            requests.removeAll()
            recording = []
            recordedFrames = 0
            keep = false
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if let onLevel, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            onLevel((sum / Float(buffer.frameLength)).squareRoot())
        }
        let current = lock.withLock { () -> [SFSpeechAudioBufferRecognitionRequest] in
            if keep, recordedFrames + buffer.frameLength <= maxFrames, let copy = Self.copy(buffer) {
                recording.append(copy)
                recordedFrames += buffer.frameLength
            }
            return Array(requests.values)
        }
        current.forEach { $0.append(buffer) }
    }

    /// The recording as a temporary audio file (the caller deletes it).
    func writeRecording() -> URL? {
        let buffers = lock.withLock { recording }
        guard let format = buffers.first?.format else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("klavko-voice-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            for buffer in buffers { try file.write(from: buffer) }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}

/// One language's recognition. macOS ends a recognition after a pause in speech; while listening,
/// a new segment starts and the finished ones are kept.
@MainActor
private final class Recognition {
    let language: String
    private let recognizer: SFSpeechRecognizer
    private let fanout: AudioFanout
    private let isListening: () -> Bool
    private let changed: () -> Void

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var segment = ""
    /// Tells the current segment's callbacks from late ones of a segment already replaced.
    private var segmentID = 0
    /// Segments in a row that ended in an error with nothing heard.
    private var emptyFailures = 0
    /// The last segment ended after the audio stopped: nothing more will come.
    private(set) var isDone = false

    var text: String { UtteranceJoiner.join(committed, segment) }
    var failedForGood: Bool { emptyFailures > 3 }

    init(language: String, recognizer: SFSpeechRecognizer, fanout: AudioFanout,
         isListening: @escaping () -> Bool, changed: @escaping () -> Void) {
        self.language = language
        self.recognizer = recognizer
        self.fanout = fanout
        self.isListening = isListening
        self.changed = changed
    }

    func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never send audio to a server
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        fanout.set(request, for: language)

        segmentID += 1
        let id = segmentID
        segment = ""
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] heard, isFinal, error in
            self?.handle(heard: heard, isFinal: isFinal, error: error, segment: id)
        })
    }

    func endAudio() {
        request?.endAudio()
    }

    func cancel() {
        segmentID += 1
        task?.cancel()
        task = nil
        request = nil
    }

    private func handle(heard: String?, isFinal: Bool, error: String?, segment id: Int) {
        guard id == segmentID else { return }
        if let heard {
            // A new phrase after a pause, in the same recognition: keep the previous one.
            if !segment.isEmpty, UtteranceJoiner.isRestart(previous: segment, next: heard) {
                committed = UtteranceJoiner.join(committed, segment)
            }
            segment = heard
        }
        if isFinal || error != nil {
            committed = text
            segment = ""
            // "No speech detected" just means a pause: not a failure.
            let silence = error?.hasSuffix("(1110)") ?? false
            if let error, !silence {
                Log.engine.notice("Voice segment (\(self.language, privacy: .public)) ended: \(error, privacy: .public)")
            }
            if isListening() {
                emptyFailures = error != nil && !silence && heard == nil ? emptyFailures + 1 : 0
                if !failedForGood { startSegment() }
            } else {
                isDone = true
            }
        }
        changed()
    }

    /// Hands each recognition update (text, final?, error) to `update` on the main thread.
    nonisolated static func resultHandler(
        _ update: @escaping @MainActor (String?, Bool, String?) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let heard = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { ($0 as NSError).localizedDescription + " (\(($0 as NSError).code))" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { update(heard, isFinal, failure) }
            }
        }
    }
}

/// Collects a file recognition's phrases (from a background thread).
private final class PhraseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = ""
    private var current = ""
    private var finished = false

    func add(_ heard: String) {
        lock.withLock {
            if !current.isEmpty, UtteranceJoiner.isRestart(previous: current, next: heard) {
                committed = UtteranceJoiner.join(committed, current)
            }
            current = heard
        }
    }

    /// Calls `done` once with everything heard.
    func finish(_ done: (String) -> Void) {
        let text: String? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return UtteranceJoiner.join(committed, current)
        }
        if let text { done(text) }
    }
}
