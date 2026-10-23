import AppKit
import FluidAudio
import ApplicationServices
import Carbon
import KlavkoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private let recorder = ShortcutRecorder()
    private let engine = SwitchEngine()
    private let exceptionPrompt = ExceptionPrompt()
    private let correctionWatcher = VoiceCorrectionWatcher()
    private let learnPrompt = VoiceLearnPrompt()
    private let clipboard = ClipboardManager()
    private let updater = Updater()
    private let updatePrompt = UpdatePrompt()
    let voiceHistory = VoiceHistoryStore()
    private let voiceHistoryWindow = VoiceHistoryWindow()
    private let supportWindow = SupportWindow()
    private lazy var clipboardWindow = ClipboardWindow(manager: clipboard)
    private let translator = Translator()
    private let screenText = ScreenTextCapture()
    private let qrPanel = QRCodePanel()
    private let dictation = VoiceDictation()
    private let parakeet = ParakeetEngine()
    private let google = GeminiTranscriber()
    private var monitor: KeyboardMonitor?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var watchdogTimer: Timer?
    private var flagTimer: Timer?
    private var shownLayoutID: String?
    private var secureInputActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        engine.isPaused = { [unowned self] in
            MainActor.assumeIsolated { recorder.recording != nil }
        }
        engine.isExcluded = { [unowned self] in
            MainActor.assumeIsolated {
                guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
                return settings.isExcluded(bundleID)
            }
        }
        engine.appContinuesLists = {
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
            return Self.appsWithOwnLists.contains(bundleID)
        }
        dictation.languages = { [unowned self] in
            settings.voiceLanguages
        }
        // Between two plausible results, the one in the layout's language.
        dictation.preferredLanguage = { SystemLayouts.currentLanguage() ?? "uk" }
        dictation.vocabulary = { [unowned self] in settings.voiceRules }
        dictation.microphone = { [unowned self] in settings.microphoneUID }
        dictation.duckLevel = { [unowned self] in settings.duckSound ? settings.duckLevel : nil }
        dictation.onInserted = { [unowned self] text in
            engine.reset()
            if settings.saveVoiceHistory { voiceHistory.add(text) }
            if settings.offerVoiceCorrections { correctionWatcher.watch(inserted: text) }
        }
        // A dictated word fixed by hand: offer to spell it that way from now on.
        correctionWatcher.known = { [unowned self] in settings.voiceRules }
        // One word at a time: only the first correction is offered.
        correctionWatcher.onFound = { [unowned self] corrections in
            guard let first = corrections.first else { return }
            learnPrompt.show([first]) { [unowned self] in
                settings.setVoiceSpelling(heard: first.from, written: first.to)
            }
        }
        engine.onUserKey = { [unowned self] in
            MainActor.assumeIsolated { correctionWatcher.userTyped() }
        }
        // Used once its model is downloaded (opt-in, from Settings → Voice input); macOS recognition until then.
        dictation.parakeet = parakeet
        dictation.google = { [unowned self] in
            guard settings.voiceEngine == "google", let key = GeminiKey.load() else { return nil }
            return (google, key, settings.googleModel ?? GeminiTranscriber.fallbackModel, settings.googleSmart)
        }
        clipboard.isEnabled = { [unowned self] in settings.clipboardEnabled }
        clipboard.keepDays = { [unowned self] in settings.clipboardKeepDays }
        clipboard.ignoredApps = { [unowned self] in settings.clipboardIgnoredApps }
        clipboard.onCopied = { [unowned self] in
            if settings.playCopySound { playSound(named: settings.copySoundName) }
        }
        clipboard.prune()
        updater.autoCheck = { [unowned self] in settings.checkForUpdates }
        updater.skippedVersion = { [unowned self] in settings.skippedUpdateVersion }
        updater.onAvailable = { [unowned self] release in offerUpdate(release) }
        updater.start()
        showThanksAfterUpdate()
        clipboard.start()
        engine.onClipboard = { [unowned self] in
            MainActor.assumeIsolated { clipboardWindow.toggle() }
        }
        screenText.languages = { [unowned self] in
            [settings.translationOwn, settings.translationOther] + SystemLayouts.enabledLayouts().map(\.map.language)
        }
        screenText.onText = { [unowned self] text, point in translator.show(screenText: text, at: point) }
        screenText.onProblem = { [unowned self] message, point in translator.showProblem(message, at: point) }
        screenText.onCodes = { [unowned self] payloads, point in translator.close(); qrPanel.show(payloads, at: point) }
        screenText.onUnreadableCode = { [unowned self] point in translator.close(); qrPanel.showUnreadable(at: point) }
        engine.onScreenText = { [unowned self] in
            MainActor.assumeIsolated { screenText.start() }
        }
        translator.defaultPair = { [unowned self] in (settings.translationOwn, settings.translationOther) }
        engine.onTranslate = { [unowned self] in
            MainActor.assumeIsolated { translator.start() }
        }
        engine.onVoice = { [unowned self] in
            MainActor.assumeIsolated { dictation.toggle() }
        }
        engine.onReturn = { [unowned self] in
            MainActor.assumeIsolated {
                if dictation.handleReturn() { return true }
                // "Remember this spelling?" on screen: Return confirms it first (and doesn't reach the app).
                if learnPrompt.isVisible {
                    learnPrompt.confirm()
                    return true
                }
                // Return may send the message and empty the field: look at the corrections first.
                correctionWatcher.checkNow()
                return false
            }
        }
        engine.onEscape = { [unowned self] in
            MainActor.assumeIsolated {
                // "Remember this spelling?" on screen: Esc declines it (and doesn't reach the app).
                if learnPrompt.isVisible {
                    learnPrompt.close()
                    return true
                }
                guard dictation.isActive else { return false }
                dictation.cancel()
                return true
            }
        }
        engine.onFix = { [unowned self] kind in
            MainActor.assumeIsolated { playFixSound(kind) }
        }
        engine.onRevert = { [unowned self] word in
            MainActor.assumeIsolated {
                guard settings.recordRevert(of: word) else { return }
                Log.engine.notice("Offering to add a reverted word to exceptions")
                exceptionPrompt.show(word: word,
                                     onAdd: { [unowned self] in settings.addException(word) },
                                     onDecline: { [unowned self] in settings.declineException(word) })
            }
        }
        settings.onChange = { [unowned self] in applySettings() }
        applySettings()
        engine.reloadLayouts()
        // Load the dictionaries and sounds now, not on the first word typed.
        DispatchQueue.main.async { [weak self, engine] in
            engine.warmUp()
            guard let self else { return }
            soundPlayer.preload(settings.soundName)
            soundPlayer.preload(settings.spellingSoundName)
            soundPlayer.preload(settings.copySoundName)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.reloadLayouts() }
            }
        // Flag in the menu bar follows the active layout.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFlag() }
            }
        // Typing in another app starts from scratch.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.reset() }
            }

        monitor = KeyboardMonitor { [weak self, engine] type, event in
            let pass = engine.handle(type, event)
            // The layout notification sometimes doesn't arrive; layout shortcuts are key events, so check after them.
            if type == .keyDown || type == .flagsChanged {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshFlag() } }
            }
            return pass
        }
        startMonitoring(prompt: true)

        // Developer check of the exception card's look: open Klavko with --demo-exception-prompt.
        if CommandLine.arguments.contains("--demo-exception-prompt") {
            exceptionPrompt.show(word: "ghbdsn", onAdd: {}, onDecline: {})
        }
        // Developer check of speech recognition: --voice-check <audio file> <output.txt>.
        if let index = CommandLine.arguments.firstIndex(of: "--voice-check"), index + 2 < CommandLine.arguments.count {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { [parakeet] in
                var report = await VoiceDictation.check(file: file)
                for (name, hint) in [("parakeet auto", nil), ("parakeet uk-only", Language.ukrainian)] as [(String, Language?)] {
                    let started = Date()
                    let text = (try? await parakeet.transcribe(file: file, language: hint)) ?? "(failed)"
                    let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                    report += "\n\(name) [\(seconds) s, russian=\(LanguageGuess.looksRussian(text))]: \(text)"
                }
                try? report.write(to: output, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        // Developer check of the voice indicator: --snapshot-voice <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-voice"), index + 1 < CommandLine.arguments.count {
            dictation.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil)
        }
        // Developer check of the translator: --translate-check <text> <out.txt> writes the translation and quits.
        if let index = CommandLine.arguments.firstIndex(of: "--translate-check"), index + 2 < CommandLine.arguments.count {
            translator.check(CommandLine.arguments[index + 1], writeTo: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        }
        // Developer check of updating: --update-test <test copy of Klavko.app> <report.txt> installs the latest
        // release over that copy (never over the running app) and quits.
        if let index = CommandLine.arguments.firstIndex(of: "--update-test"), index + 2 < CommandLine.arguments.count {
            updater.installForTest(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                   report: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        }
        // Developer check of Parakeet's language handling: --parakeet-check <audio> <out.txt>.
        if let index = CommandLine.arguments.firstIndex(of: "--parakeet-check"), index + 2 < CommandLine.arguments.count {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let out = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor [dictation] in
                let result = await dictation.checkParakeet(file: file)
                try? result.write(to: out, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        // Developer check of the window shown after an update: --snapshot-support <file.png>, or --show-support.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-support"), index + 1 < CommandLine.arguments.count {
            SupportWindow.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), version: updater.currentVersion)
        }
        if CommandLine.arguments.contains("--show-support") {
            supportWindow.show(version: updater.currentVersion)
        }
        // Developer checks of QR codes: --qr-check <image> <out.txt>; --snapshot-qr <file.png> [payload]; --show-qr <payload>.
        if let index = CommandLine.arguments.firstIndex(of: "--qr-check"), index + 2 < CommandLine.arguments.count {
            ScreenTextCapture.checkCodes(URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                         writeTo: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        }
        // --show-qr <payload> (or "" for the unreadable note): the real panel at the mouse, to try its keys.
        if let index = CommandLine.arguments.firstIndex(of: "--show-qr"), index + 1 < CommandLine.arguments.count {
            let payload = CommandLine.arguments[index + 1]
            if payload.isEmpty { qrPanel.showUnreadable(at: NSEvent.mouseLocation) } else { qrPanel.show([payload], at: NSEvent.mouseLocation) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-qr"), index + 1 < CommandLine.arguments.count {
            QRCodePanel.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                 payload: index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : "")
        }
        // Developer check of turning sound down while dictating: --duck-check <out.txt> notes the output volume
        // before, while turned down to 20 % and after, then quits.
        if let index = CommandLine.arguments.firstIndex(of: "--duck-check"), index + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let ducker = SoundDucker()
            func volume() -> String { AudioDevices.defaultOutput.map { "\(AudioDevices.volume(of: $0))" } ?? "no output" }
            var report = "microphones: \(AudioDevices.microphones().map(\.name))\nbefore: \(volume())\n"
            ducker.duck(to: 0.2)
            report += "ducked: \(volume())\n"
            ducker.restore()
            report += "after: \(volume())\n"
            try? report.write(to: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        // Developer check of the update prompt: --snapshot-update <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-update"), index + 1 < CommandLine.arguments.count {
            UpdatePrompt.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        // Developer check of the translation panel: --snapshot-translation <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-translation"), index + 1 < CommandLine.arguments.count {
            translator.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        // Developer check of screen text recognition: --ocr-check <image> <out.txt>.
        if let index = CommandLine.arguments.firstIndex(of: "--ocr-check"), index + 2 < CommandLine.arguments.count {
            ScreenTextCapture.check(URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                                    writeTo: URL(fileURLWithPath: CommandLine.arguments[index + 2]),
                                    languages: ["uk", "en"])
        }
        // Developer check of the clipboard window: --snapshot-clipboard <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-clipboard"), index + 1 < CommandLine.arguments.count {
            clipboardWindow.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        // Developer check of the "remember this spelling?" card: --snapshot-learn <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-learn"), index + 1 < CommandLine.arguments.count {
            VoiceLearnPrompt.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil)
        }
        // Developer check of the settings layout: --snapshot-settings <file.png> renders the window and quits.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
           index + 1 < CommandLine.arguments.count {
            snapshotSettings(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }
        // Layout changed by the mouse (Input menu) or another app: no key event to catch it.
        flagTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFlag() }
        }
    }

    private func applySettings() {
        settingsWindow?.title = tr("Klavko — Налаштування", "Klavko Settings")
        engine.config = SwitchEngine.Config(shortcuts: settings.shortcuts,
                                            autoSwitch: settings.isEnabled,
                                            triggers: settings.triggers,
                                            switchWhileTyping: settings.switchWhileTyping,
                                            backspaceUndo: settings.backspaceUndo,
                                            convertAbbreviations: settings.convertAbbreviations,
                                            correctSpelling: settings.correctSpelling,
                                            spaceAfterPunctuation: settings.spaceAfterPunctuation,
                                            autoCapitalize: settings.autoCapitalize,
                                            dashes: settings.dashes,
                                            smartQuotes: settings.smartQuotes,
                                            symbols: settings.symbols,
                                            listContinuation: settings.listContinuation,
                                            replacements: settings.replacements,
                                            exceptions: Set(settings.exceptions),
                                            manualLanguages: Set(settings.manualLanguages))
        updateIcon()
    }

    // MARK: - Sound

    private let soundPlayer = SoundPlayer()

    private func playFixSound(_ kind: FixKind) {
        switch kind {
        case .layout where settings.playSound: playSound(named: settings.soundName)
        case .spelling where settings.playSpellingSound: playSound(named: settings.spellingSoundName)
        default: break
        }
    }

    private func playSound(named name: String) {
        soundPlayer.play(name)
    }

    // MARK: - Permissions and health

    private func startMonitoring(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), monitor?.start() == true {
            permissionTimer?.invalidate()
            permissionTimer = nil
            updateIcon()
            return
        }
        guard permissionTimer == nil else { return }
        // Wait until the user grants access in System Settings.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMonitoring(prompt: false) }
        }
        updateIcon()
    }

    private func watchdog() {
        monitor?.ensureEnabled()

        // While another app holds Secure Input (password fields, "Secure Keyboard Entry"),
        // macOS hides all keystrokes from Klavko.
        let secure = IsSecureEventInputEnabled()
        if secure != secureInputActive {
            secureInputActive = secure
            Log.monitor.notice("Secure input \(secure ? "on" : "off", privacy: .public), owner: \(Self.secureInputOwner() ?? "-", privacy: .public)")
            updateIcon()
        }
    }

    private static func secureInputOwner() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32 ?? (session["kCGSSessionSecureInputPID"] as? Int).map(Int32.init),
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName ?? app.bundleIdentifier
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The layouts, as in the macOS input menu but with Klavko's flags: a click switches to one by hand.
        let layouts = SystemLayouts.allLayouts()
        let currentLayout = SystemLayouts.currentLayoutID()
        for layout in layouts {
            let mark = layout.language.flatMap { Self.flag(language: $0, layoutID: layout.id) }
                ?? layout.language?.uppercased() ?? "⌨︎"
            let entry = item(mark + "  " + layout.name, #selector(selectLayout(_:)))
            entry.representedObject = layout.id
            entry.state = layout.id == currentLayout ? .on : .off
            menu.addItem(entry)
        }
        if layouts.isEmpty { menu.addItem(disabledItem("Klavko")) }

        if monitor?.isRunning != true {
            menu.addItem(.separator())
            menu.addItem(item(tr("⚠️ Надайте доступ у «Універсальний доступ»…", "⚠️ Allow Accessibility access…"), #selector(openAccessibilitySettings)))
        } else if secureInputActive {
            menu.addItem(.separator())
            let owner = Self.secureInputOwner().map { "«\($0)»" } ?? tr("іншій програмі", "another app")
            menu.addItem(disabledItem(trFormat("⚠️ Захищене введення в %@", "⚠️ Secure input in %@", owner)))
            menu.addItem(disabledItem(tr("     Klavko зараз не бачить клавіатуру", "     Klavko can’t see the keyboard now")))
        }

        menu.addItem(.separator())
        let toggle = item(tr("Автоматично виправляти розкладку", "Fix Layout Automatically"), #selector(toggleEnabled))
        toggle.state = settings.isEnabled ? .on : .off
        menu.addItem(toggle)
        let spelling = item(tr("Виправляти помилки", "Fix Typos"), #selector(toggleSpelling))
        spelling.state = settings.correctSpelling ? .on : .off
        menu.addItem(spelling)

        if let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            let exclude = item(trFormat("Не виправляти в «%@»", "Don’t Fix in “%@”", app.localizedName ?? bundleID), #selector(toggleExcluded(_:)))
            exclude.representedObject = bundleID
            exclude.state = settings.isExcluded(bundleID) ? .on : .off
            menu.addItem(exclude)
        }

        menu.addItem(.separator())
        // The actions themselves are on their hotkeys; the menu keeps only what has no hotkey.
        let updateItem = updater.available.map {
            item(trFormat("⬆︎ Оновити Klavko до %@", "⬆︎ Update Klavko to %@", $0.version), #selector(installUpdate))
        } ?? item(tr("Перевірити оновлення…", "Check for Updates…"), #selector(checkForUpdates))
        let settingsItem = item(tr("Налаштування…", "Settings…"), #selector(showSettings))
        let quitItem = item(tr("Вийти з Klavko", "Quit Klavko"), #selector(quit))
        Self.showShortcuts([(updateItem, nil), (settingsItem, "⌘,"), (quitItem, "⌘Q")])
        menu.addItem(updateItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        if AboutInfo.donateURL != nil {
            let thanks = item(tr("Подякувати", "Say Thanks"), #selector(openDonate))
            thanks.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
            menu.addItem(thanks)
        }
        menu.addItem(quitItem)
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let layout = SystemLayouts.allLayouts().first(where: { $0.id == id }) else { return }
        SystemLayouts.select(layout.source)
        // Switched by hand: what was typed so far stays as it is.
        engine.reset()
        updateIcon()
    }

    @objc private func openDonate() {
        if let donate = AboutInfo.donateURL { NSWorkspace.shared.open(donate) }
    }

    /// Puts each shortcut at the right edge of its item, in grey, all in one column. (Real key equivalents
    /// can't show double taps like ⌘⌘ or fn, so every item shows its shortcut the same way.)
    private static func showShortcuts(_ items: [(NSMenuItem, String?)]) {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let titles = items.map { width($0.0.title) }.max() ?? 0
        let shortcuts = items.compactMap { $0.1 }.map(width).max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titles + 36 + shortcuts))]
        for (item, shortcut) in items {
            let title = NSMutableAttributedString(string: item.title, attributes: [.font: font, .paragraphStyle: paragraph])
            if let shortcut {
                title.append(NSAttributedString(string: "\t" + shortcut, attributes: [
                    .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            item.attributedTitle = title
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func toggleSpelling() {
        settings.correctSpelling.toggle()
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        settings.toggleExcluded(bundleID)
    }

    /// The first launch of a newer version: thank the user and show how to support Klavko, once.
    /// Not after a first install, and not when started for a developer check.
    private func showThanksAfterUpdate() {
        guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
        let current = updater.currentVersion
        if UpdateThanks.shouldShow(lastRunVersion: settings.lastRunVersion, current: current, usedBefore: settings.usedBefore) {
            // A moment after launch, so it doesn't come up together with the permission prompts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.supportWindow.show(version: current)
            }
        }
        settings.lastRunVersion = current
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, recorder: recorder, parakeet: parakeet, clipboard: clipboard, updater: updater,
                                    voiceHistory: voiceHistory, showVoiceHistory: { [weak self] in self?.showVoiceHistory() },
                                    keyLayout: englishLayout(),
                                    previewSound: { [weak self] name in self?.playSound(named: name) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = tr("Klavko — Налаштування", "Klavko Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Renders every tab into `<name>-<tab>.png` next to `url`, then quits.
    private func snapshotSettings(to url: URL, tabs: [SettingsTab] = SettingsTab.allCases) {
        guard let tab = tabs.first else { return NSApp.terminate(nil) }
        var view = SettingsView(settings: settings, recorder: recorder, parakeet: parakeet, clipboard: clipboard, updater: updater,
                                    voiceHistory: voiceHistory, showVoiceHistory: { [weak self] in self?.showVoiceHistory() },
                                    keyLayout: englishLayout(),
                                previewSound: { _ in })
        view.initialTab = tab
        view.height = 900
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.orderBack(nil)
        settingsWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let view = self?.settingsWindow?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = url.deletingPathExtension().lastPathComponent + "-\(tab.rawValue).png"
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: url.deletingLastPathComponent().appendingPathComponent(name))
            }
            self?.settingsWindow?.close()
            self?.snapshotSettings(to: url, tabs: Array(tabs.dropFirst()))
        }
    }

    @objc private func toggleVoice() {
        // After the menu closes, so the text lands in the app that was in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.dictation.toggle() }
    }

    @objc private func installUpdate() {
        updater.install()
    }

    private func offerUpdate(_ release: Updater.Release) {
        updatePrompt.show(release, current: updater.currentVersion,
                          onUpdate: { [unowned self] in updater.install() },
                          onSkip: { [unowned self] in settings.skippedUpdateVersion = release.version })
    }

    /// From the menu: checks now and says what it found (a newer version is offered as usual).
    @objc private func checkForUpdates() {
        Task { @MainActor in
            await updater.check(userInitiated: true)
            let alert = NSAlert()
            switch updater.state {
            case .available(let release):
                return offerUpdate(release)
            case .upToDate:
                alert.messageText = tr("У вас остання версія Klavko", "You have the latest version of Klavko")
                alert.informativeText = tr("Версія", "Version") + " " + updater.currentVersion
            case .failed(let message):
                alert.messageText = tr("Не вдалося перевірити оновлення", "Couldn’t check for updates")
                alert.informativeText = message
            default:
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func showVoiceHistory() {
        voiceHistoryWindow.show(voiceHistory)
    }

    @objc private func captureScreenText() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.screenText.start() }
    }

    @objc private func showClipboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.clipboardWindow.show() }
    }

    @objc private func startTranslation() {
        // The menu has taken focus from the app with the selection; give it back first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.translator.start() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func englishLayout() -> LayoutMap? {
        SystemLayouts.enabledLayouts().first { $0.map.language == "en" }?.map
    }

    private static func flag(language: String, layoutID: String?) -> String? {
        language == "pt" && layoutID?.contains("Brazilian") == true ? "🇧🇷" : LanguageFlags.emoji[language]
    }

    /// Apps that continue "- " and "1." lists themselves.
    private static let appsWithOwnLists: Set<String> = [
        "com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word", "com.microsoft.onenote.mac",
        "notion.id", "md.obsidian", "com.tinyspeck.slackmacgap", "net.shinyfrog.bear", "com.lukilabs.lukiapp",
    ]

    private func refreshFlag() {
        let current = SystemLayouts.currentLayoutID()
        guard current != shownLayoutID else { return }
        updateIcon()
    }

    private func updateIcon() {
        guard let item = statusItem, let button = item.button else { return }
        shownLayoutID = SystemLayouts.currentLayoutID()
        button.appearsDisabled = !settings.isEnabled

        // Problems take priority over the flag.
        let warning: String? = monitor?.isRunning != true ? "keyboard.badge.exclamationmark"
            : secureInputActive ? "lock.circle" : nil
        if warning == nil, settings.showFlag, let language = SystemLayouts.currentLanguage() {
            let flag = Self.flag(language: language, layoutID: shownLayoutID)
            item.length = NSStatusItem.variableLength
            button.image = nil
            button.title = flag ?? language.uppercased()
            button.font = flag == nil ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 15)
            return
        }

        item.length = NSStatusItem.squareLength
        button.title = ""
        let image = NSImage(systemSymbolName: warning ?? "keyboard", accessibilityDescription: "Klavko")
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Klavko")
        image?.isTemplate = true
        button.image = image
    }
}
