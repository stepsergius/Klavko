import AppKit
import Carbon
import KlavkoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var parakeet: ParakeetEngine
    @ObservedObject var grammar: GrammarChecker
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var updater: Updater
    @ObservedObject var voiceHistory: VoiceHistoryStore
    let showVoiceHistory: () -> Void
    @ObservedObject var voiceStats: VoiceStatsStore
    let showVoiceStats: () -> Void
    /// English layout, used to name letter keys in shortcuts.
    let keyLayout: LayoutMap?
    let previewSound: (String) -> Void
    /// Taller only for a full-length snapshot of the window.
    var height: CGFloat = 620

    @State private var newException = ""
    /// The first key of a remapping rule being added, once recorded.
    @State private var newRemapFrom: KeyCombo?
    @State private var newRemapTo: KeyCombo?
    @State private var newReplacementFrom = ""
    @State private var newReplacementTo = ""
    /// The Quick Actions row a dragged row is over.
    @State private var quickActionDropTarget: QuickAction?
    @State private var newSpellingHeard = ""
    @State private var newSpellingWritten = ""
    @State private var googleKey = GeminiKey.load() ?? ""
    @State private var googleStatus: (text: String, ok: Bool)?
    @State private var checkingGoogleKey = false
    private static let googleCheck = GeminiTranscriber()
    @State private var tab: SettingsTab = .general
    /// The languages of the enabled layouts (all of them, not only those Klavko switches between), kept up to date.
    @State private var layoutLanguages: [String] = []
    /// The tab shown first (for snapshots).
    var initialTab: SettingsTab = .general

    /// Saves the Google AI key once Google accepts it, and picks the speech model it can reach.
    private func checkGoogleKey() {
        let key = googleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            GeminiKey.save("")
            googleStatus = nil
            return
        }
        checkingGoogleKey = true
        Task {
            do {
                let model = try await Self.googleCheck.check(key: key)
                settings.googleModel = model
                googleStatus = GeminiKey.save(key)
                    ? (tr("Ключ працює", "The key works") + " · " + model, true)
                    : (tr("Не вдалося зберегти ключ у Keychain.", "Couldn’t save the key in the Keychain."), false)
            } catch {
                googleStatus = (error.localizedDescription, false)
            }
            checkingGoogleKey = false
        }
    }

    /// Saves every setting to a file the user chooses; the Google AI key only if they tick the box.
    private func saveBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = tr("Klavko налаштування", "Klavko settings") + ".json"
        let withKey = NSButton(checkboxWithTitle: tr("Додати ключ Google AI (не давайте такий файл іншим)",
                                                     "Include the Google AI key (don’t give such a file to others)"),
                               target: nil, action: nil)
        if GeminiKey.load()?.isEmpty == false {
            withKey.frame.size = withKey.fittingSize
            let box = NSView(frame: NSRect(x: 0, y: 0, width: withKey.frame.width + 40, height: withKey.frame.height + 16))
            withKey.frame.origin = NSPoint(x: 20, y: 8)
            box.addSubview(withKey)
            panel.accessoryView = box
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.backup(withGoogleKey: withKey.state == .on).data().write(to: url, options: .atomic)
        } catch {
            alert(tr("Не вдалося зберегти файл", "Couldn’t save the file"), error.localizedDescription)
        }
    }

    /// Takes the settings from a file saved by «Зберегти у файл», then starts Klavko again with them.
    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let restored: SettingsBackup
        do {
            restored = try SettingsBackup.read(Data(contentsOf: url))
        } catch SettingsBackup.Failure.newerFormat {
            return alert(tr("Файл із новішої версії Klavko", "The file is from a newer Klavko"),
                         tr("Оновіть Klavko й спробуйте ще раз.", "Update Klavko and try again."))
        } catch {
            return alert(tr("Це не файл налаштувань Klavko", "This isn’t a Klavko settings file"),
                         tr("Виберіть файл, збережений кнопкою «Зберегти у файл».", "Choose a file saved with “Save to File”."))
        }
        let confirm = NSAlert()
        confirm.messageText = tr("Відновити налаштування з файлу?", "Restore settings from the file?")
        confirm.informativeText = restored.isFromThisSystem
            ? tr("Усі налаштування стануть такими, як у файлі; правила з файлу додадуться до ваших. Klavko перезапуститься.",
                 "All settings become as in the file; the file’s rules are added to yours. Klavko will restart.")
            : tr("Це файл Klavko для Windows: з нього додадуться винятки, заміни слів і словник голосового вводу. Klavko перезапуститься.",
                 "This is a Klavko for Windows file: its exceptions, word replacements and voice input vocabulary will be added. Klavko will restart.")
        confirm.addButton(withTitle: tr("Відновити", "Restore"))
        confirm.addButton(withTitle: tr("Скасувати", "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        settings.restore(restored)
        Self.restartKlavko()
    }

    /// Opens Klavko again once this process has quit.
    private static func restartKlavko() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; "
                             + "/usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func alert(_ message: String, _ details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }

    private func addException() {
        // Several words at once: "npm, ye ок".
        let words = newException.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" })
        for word in words { settings.addException(String(word)) }
        newException = ""
    }

    /// Lets the user pick apps in /Applications; `add` gets each one not yet in `existing`.
    private func pickApps(adding existing: [String], add: (String) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.application]
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.allowsMultipleSelection = true
        guard openPanel.runModal() == .OK else { return }
        for url in openPanel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !existing.contains(bundleID) { add(bundleID) }
        }
    }

    /// Apps as small chips with their icons, wrapping onto new lines, and an "Add App…" button.
    private func appList(_ bundleIDs: [String], remove: @escaping (String) -> Void, add: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if bundleIDs.isEmpty {
                Text(tr("Немає", "None")).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(bundleIDs, id: \.self) { bundleID in
                        AppChip(name: Self.appName(bundleID), icon: Self.appIcon(bundleID)) { remove(bundleID) }
                    }
                }
            }
            Button(tr("Додати програму…", "Add App…"), action: add)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func addSpelling() {
        if settings.setVoiceSpelling(heard: newSpellingHeard, written: newSpellingWritten) {
            newSpellingHeard = ""
            newSpellingWritten = ""
        }
    }

    @ViewBuilder private var quickActionsTab: some View {
        Section {
            Toggle(tr("Показувати після виділення тексту мишкою", "Show after selecting text with the mouse"),
                   isOn: $settings.quickActionsEnabled)
            Picker(tr("Де показувати", "Where"), selection: $settings.quickActionsPosition) {
                ForEach(QuickActionsPosition.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(tr("Швидкі дії", "Quick Actions"))
        } footer: {
            Text(tr("Виділіть текст мишкою (або двічі клацніть слово) — над ним з’явиться панелька з діями. Клік деінде чи будь-яка клавіша її ховає. Для тексту, виділеного з клавіатури, задайте гарячу клавішу «Швидкі дії для виділеного» на вкладці «Клавіші».",
                    "Select text with the mouse (or double-click a word) and a bar with actions appears over it. A click elsewhere or any key hides it. For text selected with the keyboard, set the “Quick Actions for the selection” hotkey in the Hotkeys tab.") + " " + tr("Утримайте кнопку миші в полі для тексту — з’явиться «Вставити».",
                       "Hold the mouse button down in a text field and “Paste” appears."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            ForEach(settings.quickActionOrder, id: \.self) { action in
                quickActionRow(action)
                    .contentShape(Rectangle())
                    .draggable(action.rawValue) { Text(action.title).padding(6) }
                    .dropDestination(for: String.self) { items, _ in
                        quickActionDropTarget = nil
                        return moveQuickAction(items.first, onto: action)
                    } isTargeted: { over in
                        if over { quickActionDropTarget = action } else if quickActionDropTarget == action { quickActionDropTarget = nil }
                    }
                    // Where the row will land.
                    .overlay(alignment: .top) {
                        if quickActionDropTarget == action {
                            Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -5)
                        }
                    }
            }
        } header: {
            Text(tr("Дії на панельці", "Actions on the bar"))
        } footer: {
            Text(tr("Перетягніть рядок, щоб змінити порядок. «Відкрити посилання» з’являється лише для посилання і завжди першою. Дії, що змінюють текст, видно лише там, де його можна редагувати; «Сума чисел» — коли виділено щонайменше два числа.",
                    "Drag a row to change the order. “Open Link” appears only for a link, and always first. Actions that change the text show only where it can be edited; “Sum of Numbers” when at least two numbers are selected."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Picker(tr("Шукати в інтернеті через", "Search the web with"), selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack(spacing: 14) {
                Text(tr("Відкривати в ШІ", "Open in AI"))
                Spacer()
                ForEach(AIService.allCases) { service in
                    Toggle(service.title, isOn: Binding(
                        get: { settings.aiServices.contains(service) },
                        set: { on in
                            settings.aiServices = AIService.allCases.filter {
                                $0 == service ? on : settings.aiServices.contains($0)
                            }
                        }))
                    .toggleStyle(.checkbox)
                }
            }
        } footer: {
            Text(tr("Якщо програма ШІ встановлена на цьому Mac (Claude, ChatGPT, Perplexity), виділене вставляється в неї; якщо ні — відкривається сайт із текстом. Кілька вибраних — на панельці з’явиться вибір.",
                    "If the AI’s app is on this Mac (Claude, ChatGPT, Perplexity), the selection is pasted into it; otherwise its website opens with the text. With several chosen, the bar offers a choice."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section(tr("Не показувати в програмах", "Don’t show in these apps")) {
            appList(settings.quickActionsIgnoredApps, remove: { settings.toggleQuickActionsIgnored($0) },
                    add: { pickApps(adding: settings.quickActionsIgnoredApps) { settings.toggleQuickActionsIgnored($0) } })
        }
    }

    /// LanguageTool: downloaded once on request, then the check works offline.
    private var grammarSection: some View {
        Section {
            HStack {
                switch grammar.state {
                case .notDownloaded:
                    Text(tr("Не завантажено", "Not downloaded")).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Завантажити (~300 МБ)", "Download (~300 MB)")) { grammar.download() }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(maxWidth: 220)
                    Text("\(Int(fraction * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                case .ready:
                    Label(tr("Готово, працює без інтернету", "Ready, works offline"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: GrammarChecker.downloadedSize(), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button(tr("Видалити", "Delete")) { grammar.deleteDownload() }
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button(tr("Ще раз", "Try Again")) { grammar.download() }
                }
            }
            Toggle(isOn: $settings.liveGrammar) {
                Text(tr("Підкреслювати помилки під час набору", "Underline mistakes while typing"))
                Text(tr("Наведіть мишку на підкреслене слово — з’являться виправлення. Працює в програмах, які показують свій текст системі (Нотатки, Пошта, Повідомлення, TextEdit, Safari…), і в Google Docs з підтримкою дисплея Брайля (Klavko запропонує її ввімкнути).",
                        "Point at an underlined word to see the fixes. Works in apps that show their text to the system (Notes, Mail, Messages, TextEdit, Safari…) and in Google Docs with braille support on (Klavko offers to turn it on)."))
            }
            .disabled(!grammar.isDownloaded)
            LabeledContent {
                if settings.googleDocsAnswer == "later" {
                    Button(tr("Запропонувати знову", "Offer Again")) { settings.googleDocsAnswer = "" }
                }
            } label: {
                Text("Google Docs")
                Text(tr("Google Docs показує свій текст іншим програмам лише з підтримкою дисплея Брайля. Klavko запропонує її ввімкнути, коли ви клацнете в документ. Або ввімкніть самі: ⌘⌥H у документі чи Інструменти → Доступність.",
                        "Google Docs shows its text to other apps only with braille support on. Klavko offers to turn it on when you click in a document. Or turn it on yourself: ⌘⌥H in the document, or Tools → Accessibility."))
            }
            .disabled(!grammar.isDownloaded || !settings.liveGrammar)
            if let shortcut = settings.shortcuts[.checkText] {
                LabeledContent(tr("Перевірити виділене", "Check the selection"), value: shortcut.displayName(layout: keyLayout))
            }
        } header: {
            Text(tr("Перевірка правопису", "Spelling and grammar"))
        } footer: {
            Text(tr("LanguageTool перевіряє правопис, граматику й пунктуацію українською, англійською та ще понад 20 мовами — на цьому Mac, текст нікуди не надсилається. Виділіть текст і натисніть гарячу клавішу або «Перевірити правопис» на панельці швидких дій.",
                    "LanguageTool checks spelling, grammar and punctuation in Ukrainian, English and over 20 more languages — on this Mac; the text goes nowhere. Select text and press the hotkey, or “Check Spelling” on the Quick Actions bar."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func quickActionRow(_ action: QuickAction) -> some View {
        HStack(spacing: 10) {
            // Only the box is the checkbox: the rest of the row is for dragging.
            Toggle(action.title, isOn: Binding(
                get: { !settings.quickActionsOff.contains(action) },
                set: { on in
                    if on { settings.quickActionsOff.remove(action) } else { settings.quickActionsOff.insert(action) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            HStack(spacing: 8) {
                Group {
                    if let symbol = action.symbol {
                        Image(systemName: symbol)
                    } else {
                        Text(action.label).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                }
                .frame(width: 58, alignment: .center)
                .foregroundStyle(.secondary)
                Text(action.title)
            }
            Spacer()
            // The handle shows the row can be dragged (it can be taken anywhere outside the checkbox).
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }
    }

    /// The dragged action takes the place of the one it was dropped on (that one moves down).
    private func moveQuickAction(_ raw: String?, onto target: QuickAction) -> Bool {
        guard let raw, let moved = QuickAction(rawValue: raw), moved != target,
              let from = settings.quickActionOrder.firstIndex(of: moved),
              let to = settings.quickActionOrder.firstIndex(of: target) else { return false }
        withAnimation(.easeOut(duration: 0.15)) {
            settings.quickActionOrder.move(fromOffsets: [from], toOffset: to)
        }
        return true
    }

    private func addReplacement() {
        if settings.setReplacement(from: newReplacementFrom, to: newReplacementTo) {
            newReplacementFrom = ""
            newReplacementTo = ""
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $tab)
            Divider()
            Form {
                switch tab {
                case .general:
                    Section {
                        // Named in both languages, so it can be found whichever is on.
                        Picker("Мова програми · Language", selection: $settings.interfaceLanguage) {
                            ForEach(Self.interfaceLanguages(), id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle(tr("Запускати під час входу в систему", "Open at login"), isOn: $settings.launchAtLogin)
                        Toggle(tr("Показувати прапор розкладки в меню", "Show the layout flag in the menu bar"), isOn: $settings.showFlag)
                        // One setting, in one row: what the light shows, for which language, and on/off.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("Лампочка Caps Lock показує мову", "The Caps Lock light shows the language"))
                                Text(tr("Світиться, коли ввімкнена вибрана мова; не світиться — інша. Коли ввімкнено сам Caps Lock, лампочка світиться, як завжди.",
                                        "Lit when the chosen language is on, off for any other. With Caps Lock itself on, the light is lit as usual."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker("", selection: $settings.capsLockLanguage) {
                                ForEach(capsLockLanguages, id: \.self) { code in
                                    Text(Translator.plainName(code)).tag(code)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            .disabled(!settings.capsLockShowsLanguage)
                            Toggle("", isOn: $settings.capsLockShowsLanguage)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        soundRow(tr("Звук під час зміни розкладки", "Sound when the layout is fixed"), isOn: $settings.playSound, sound: $settings.soundName)
                        soundRow(tr("Звук під час виправлення помилок", "Sound when a typo is fixed"), isOn: $settings.playSpellingSound,
                                 sound: $settings.spellingSoundName)
                    }

                    Section(tr("Не виправляти автоматично в програмах", "Don’t fix automatically in these apps")) {
                        appList(settings.excludedApps, remove: { settings.toggleExcluded($0) },
                                add: { pickApps(adding: settings.excludedApps) { settings.toggleExcluded($0) } })
                    }

                    Section {
                        HStack {
                            Button(tr("Зберегти у файл…", "Save to File…"), action: saveBackup)
                            Button(tr("Відновити з файлу…", "Restore from File…"), action: restoreBackup)
                        }
                    } header: {
                        Text(tr("Перенесення налаштувань", "Moving settings"))
                    } footer: {
                        Text(tr("У файлі — усі налаштування Klavko: гарячі клавіші, звуки, голосовий ввід, швидкі дії, буфер, "
                                + "заміна клавіш, винятки, заміни слів і словник. Зручно для нового Mac або щоб поділитися з колегою. "
                                + "Відновлення додає правила з файлу до ваших, а решту налаштувань бере з файлу; з файлу Klavko для Windows беруться лише слова. "
                                + "Історія буфера й голосу у файл не потрапляє; дозволи macOS і завантажені моделі потрібні на новому Mac знову.",
                                "The file holds all of Klavko’s settings: hotkeys, sounds, voice input, Quick Actions, clipboard, "
                                + "key remapping, exceptions, word replacements and the vocabulary. Handy for a new Mac or to share with a colleague. "
                                + "Restoring adds the file’s rules to yours and takes every other setting from the file; from a Klavko for Windows file only the words are taken. "
                                + "Clipboard and voice history aren’t in the file; a new Mac needs the macOS permissions and downloaded models again."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .layout:
                    Section {
                        Toggle(tr("Автоматично виправляти розкладку", "Fix the keyboard layout automatically"), isOn: $settings.isEnabled)
                        Toggle(tr("Перемикати вже під час набору слова", "Switch while the word is still being typed"), isOn: $settings.switchWhileTyping)
                            .disabled(!settings.isEnabled)
                        Toggle(tr("Перемикати слова з великих літер (абревіатури)", "Switch words in capitals (abbreviations)"), isOn: $settings.convertAbbreviations)
                            .disabled(!settings.isEnabled)
                        HStack {
                            Text(tr("Перевіряти слово після", "Check the word after"))
                            Spacer()
                            ForEach(SwitchTrigger.allCases, id: \.self) { trigger in
                                ChipToggle(title: trigger.title, isOn: settings.triggers.contains(trigger)) {
                                    settings.toggleTrigger(trigger)
                                }
                            }
                        }
                        // Pointless with two languages: excluding one would turn switching off.
                        if case let languages = Set(SystemLayouts.enabledLayouts().map(\.map.language)), languages.count > 2 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tr("Перемикати на ці мови лише вручну", "Switch into these languages only by hand"))
                                FlowLayout(spacing: 6) {
                                    ForEach(Translator.ordered(Array(languages)), id: \.self) { code in
                                        ChipToggle(title: Translator.plainName(code),
                                                   isOn: settings.manualLanguages.contains(code)) {
                                            settings.toggleManualLanguage(code)
                                        }
                                    }
                                }
                                Text(tr("Для мови, якою ви пишете рідко: багато її слів є й в основній («дома», «мама»), "
                                        + "тож Klavko не вгадає, яку з двох ви мали на увазі. Гаряча клавіша перемикає й на неї.",
                                        "For a language you rarely write in: many of its words are words of your main one too, "
                                        + "so Klavko can’t tell which of the two you meant. A hotkey still switches into it."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .disabled(!settings.isEnabled)
                        }
                        Toggle(tr("Backspace одразу після виправлення скасовує його", "Backspace right after a fix undoes it"), isOn: $settings.backspaceUndo)
                    } header: {
                        Text(tr("Автоматичне перемикання розкладки", "Automatic layout switching"))
                    } footer: {
                        Text(tr("Гарячі клавіші працюють, навіть коли автоматичні виправлення вимкнені.", "Hotkeys work even when automatic fixes are off."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        HStack {
                            TextField("", text: $newException, prompt: Text(tr("Нові слова через пробіл або кому", "New words, separated by spaces or commas")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addException)
                            Button(tr("Додати", "Add"), action: addException)
                                .disabled(newException.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if settings.exceptions.isEmpty {
                            Text(tr("Поки порожньо", "Empty so far")).foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(settings.exceptions, id: \.self) { word in
                                    RemovableChip(title: word) { settings.removeException(word) }
                                }
                            }
                        }
                    } header: {
                        Text(tr("Винятки", "Exceptions") + " (\(settings.exceptions.count))")
                    } footer: {
                        Text(tr("Слова, які Klavko ніколи не змінює. Записуйте так, як набираєте їх (наприклад «ye» або «npm»). "
                                + "Якщо ви двічі скасуєте виправлення одного слова, Klavko сам запропонує додати його сюди.",
                                "Words Klavko never changes. Write them the way you type them (for example “ye” or “npm”). "
                                + "If you undo the fix of the same word twice, Klavko offers to add it here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .text:
                    Section {
                        Picker(tr("Моя мова", "My language"), selection: $settings.translationOwn) {
                            ForEach(Translator.ordered(TranslationDirection.languages), id: \.self) {
                                Text(Translator.languageName($0)).tag($0)
                            }
                        }
                        Picker(tr("Перекладати на", "Translate into"), selection: $settings.translationOther) {
                            ForEach(Translator.ordered(TranslationDirection.languages.filter { $0 != settings.translationOwn }),
                                    id: \.self) {
                                Text(Translator.languageName($0)).tag($0)
                            }
                        }
                    } header: {
                        Text(tr("Переклад", "Translation"))
                    } footer: {
                        Text(tr("Текст моєю мовою перекладається на вибрану мову, текст будь-якою іншою мовою — на мою. "
                                + "Мови можна змінити й прямо у вікні перекладу.",
                                "Text in my language is translated into the chosen language, text in any other language into mine. "
                                + "The languages can also be changed right in the translation panel."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    grammarSection

                    Section {
                        Toggle(isOn: $settings.emojiByColon) {
                            Text(tr("Емодзі за назвою після двокрапки", "Emoji by name after a colon"))
                            Text(tr("Пробіл, двокрапка й назва — «:сміх», «:серце» — показують емодзі біля курсора. ← → — вибрати, Return чи Tab — вставити, Esc — закрити. Назви — мовою розкладки, якою ви друкуєте.",
                                    "A space, a colon and a name — “:smile”, “:heart” — show emoji at the caret. ← → choose, Return or Tab puts one in, Esc closes. Names are in the language of the layout you type in."))
                        }
                        Toggle(isOn: $settings.emojiSuggestions) {
                            Text(tr("Підказувати емодзі після слова", "Suggest emoji after a word"))
                            Text(tr("Після слова, яке називає емодзі («серце», «вогонь»), над ним з’являються ❤️, 🔥. Tab вставляє перше; ↑ — до них, ← → — вибрати, Return чи Tab — вставити.",
                                    "After a word that names an emoji (“heart”, “fire”), ❤️ and 🔥 appear over it. Tab puts in the first; ↑ goes to them, ← → choose, Return or Tab puts one in."))
                        }
                        Picker(tr("Обране емодзі", "The chosen emoji"), selection: $settings.emojiReplacesWord) {
                            Text(tr("Ставиться після слова", "Goes after the word")).tag(false)
                            Text(tr("Замінює слово", "Replaces the word")).tag(true)
                        }
                        .disabled(!settings.emojiSuggestions)
                    } header: {
                        Text(tr("Емодзі", "Emoji"))
                    } footer: {
                        Text(tr("Усі емодзі — дія «Емодзі» на панельці швидких дій: спершу п’ять останніх, далі решта.",
                                "All the emoji: the Emoji action on the Quick Actions bar, the five used lately first, then the rest."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Toggle(isOn: $settings.correctSpelling) {
                            Text(tr("Виправляти помилки", "Fix typos"))
                            Text(tr("Усі мови розкладок: пропущені й переставлені літери, сусідні клавіші "
                                    + "(рлбиш → робиш), залипання Shift (ПРивіт → Привіт). "
                                    + "Сумнівні слова, імена посеред речення та слова з цифрами не змінюються.",
                                    "All layout languages: missing and swapped letters, neighbouring keys "
                                    + "(teh → the), a stuck Shift (HEllo → Hello). "
                                    + "Doubtful words, names mid-sentence and words with digits stay as they are."))
                        }
                        Toggle(isOn: $settings.spaceAfterPunctuation) {
                            Text(tr("Додавати пропущений пробіл після розділових знаків", "Add a missing space after punctuation"))
                            Text(tr("«Привіт,як» → «Привіт, як». Після крапки — лише перед великою літерою; "
                                    + "числа, адреси, дефіс, дужки й лапки не змінюються.",
                                    "“Hi,there” → “Hi, there”. After a full stop only before a capital letter; "
                                    + "numbers, addresses, hyphens, brackets and quotes are left alone."))
                        }
                    } header: {
                        Text(tr("Помилки", "Typos"))
                    }

                    Section {
                        Toggle(isOn: $settings.autoCapitalize) {
                            Text(tr("Велика літера на початку речення", "Capital letter at the start of a sentence"))
                            Text(tr("Після «.» «!» «?», на новому рядку та на початку тексту. Скорочення («т.д.», «напр.») не враховуються.",
                                    "After “.” “!” “?”, on a new line and at the start of the text. Abbreviations (“e.g.”, “etc.”) don’t count."))
                        }
                        Toggle(isOn: $settings.dashes) {
                            Text(tr("Довге тире", "Long dash"))
                            Text(tr("« - » і « -- » між словами → « — ». Дефіс у словах і «- пункт» на початку рядка не змінюються.",
                                    "“ - ” and “ -- ” between words → “ — ”. Hyphens in words and “- item” at the start of a line stay."))
                        }
                        Toggle(isOn: $settings.smartQuotes) {
                            Text(tr("Типографські лапки", "Curly quotes"))
                            Text(tr("\" → « » (укр.) / “ ” (англ.) / „ “ (нім.)",
                                    "\" → “ ” (Eng.) / « » (Ukr.) / „ “ (Ger.)"))
                        }
                        Toggle(isOn: $settings.symbols) {
                            Text(tr("Три крапки та знаки", "Ellipsis and signs"))
                            Text(tr("... → …   (c) (r) (tm) → © ® ™", "... → …   (c) (r) (tm) → © ® ™"))
                        }
                        Toggle(isOn: $settings.listContinuation) {
                            Text(tr("Продовжувати списки", "Continue lists"))
                            Text(tr("Enter після «- пункт» або «1. пункт» додає наступний маркер; Enter на порожньому пункті завершує список. "
                                    + "Не діє в програмах, що роблять це самі (Нотатки, Word, Notion…).",
                                    "Return after “- item” or “1. item” adds the next marker; Return on an empty item ends the list. "
                                    + "Off in apps that do this themselves (Notes, Word, Notion…)."))
                        }
                        // Fields without labels: in a Form a label would take a column of its own and push the field aside.
                        HStack(spacing: 8) {
                            TextField("", text: $newReplacementFrom, prompt: Text(tr("Набираю", "I type")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("", text: $newReplacementTo, prompt: Text(tr("Замінити на", "Replace with")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addReplacement)
                            Button(tr("Додати", "Add"), action: addReplacement)
                                .disabled(newReplacementFrom.trimmingCharacters(in: .whitespaces).isEmpty || newReplacementTo.isEmpty)
                        }
                        if !settings.replacements.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(settings.replacements, id: \.self) { rule in
                                    RemovableChip(title: "\(rule.from) → \(rule.to)") { settings.removeReplacement(rule) }
                                }
                            }
                        }
                    } header: {
                        Text(tr("Оформлення тексту", "Text formatting"))
                    } footer: {
                        Text(tr("Власні заміни: слово («сп» → «спасибі») змінюється, коли воно закінчене; "
                                + "послідовність символів («:)» → «🙂») — щойно набрана.",
                                "Your replacements: a word (“ty” → “thank you”) is replaced when it’s finished; "
                                + "a sequence of characters (“:)” → “🙂”) as soon as it’s typed."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .voice:
                    Section {
                        Toggle(isOn: $settings.voiceEnabled) {
                            Text(tr("Голосовий ввід", "Voice input"))
                            Text(tr("Вимкнено — гарячі клавіші голосу нічого не роблять, а fn працює як звичайно.",
                                    "Off: the voice hotkeys do nothing, and fn works as usual."))
                        }
                    }
                    Section {
                        Picker(tr("Вигляд", "Look"), selection: $settings.voicePanelStyle) {
                            ForEach(VoiceLook.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker(tr("Де показувати", "Where"), selection: $settings.voicePanelPosition) {
                            ForEach(VoiceLook.Position.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(settings.voicePanelStyle == .island || settings.voicePanelStyle == .hidden)
                        Toggle(isOn: $settings.voiceShowText) {
                            Text(tr("Показувати текст під час диктування", "Show the text while dictating"))
                            Text(tr("Вимкнено — лише хвиля, без тексту.", "Off: only the wave, without the text."))
                        }
                        .disabled(settings.voicePanelStyle == .hidden)
                    } header: {
                        Text(tr("Вигляд під час диктування", "Look while dictating"))
                    } footer: {
                        Text(tr("Dynamic Island — чорна панелька під вирізом камери вгорі екрана (на Mac без вирізу — вгорі по центру).",
                                "Dynamic Island: a black pill under the camera notch at the top of the screen (at the top centre on a Mac without one)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("Я говорю", "I speak"))
                            FlowLayout(spacing: 6) {
                                ForEach(Translator.ordered(Settings.speechLanguages), id: \.self) { code in
                                    ChipToggle(title: Translator.plainName(code),
                                               isOn: settings.voiceLanguages.contains(code)) {
                                        settings.toggleVoiceLanguage(code)
                                    }
                                }
                            }
                        }
                        HStack {
                            Text(tr("Модель розпізнавання", "Recognition model"))
                            Spacer()
                            switch parakeet.state {
                            case .ready:
                                Label(tr("Parakeet Ultra готова", "Parakeet Ultra is ready"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            case .downloading(let fraction):
                                ProgressView(value: fraction).frame(width: 120)
                                Text("\(Int(fraction * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                            case .notDownloaded:
                                Button(tr("Завантажити (~600 МБ)", "Download (~600 MB)")) { parakeet.prepare() }
                            case .failed(let message):
                                Text(message).foregroundStyle(.red).lineLimit(2)
                                Button(tr("Ще раз", "Try again")) { parakeet.prepare() }
                            }
                        }
                    } header: {
                        Text(tr("Голосовий ввід", "Voice input"))
                    } footer: {
                        Text(tr("Натисніть гарячу клавішу «Голосовий ввід» (за замовчуванням fn), говоріть, натисніть її ще раз — "
                                + "текст з’явиться в місці курсора. Esc скасовує. Розпізнає модель NVIDIA Parakeet Ultra на цьому Mac, "
                                + "з розділовими знаками. Турецьку, іврит і арабську розпізнає macOS: увімкніть для них Диктування "
                                + "в System Settings → Keyboard. Мови, не вибрані вище, ніколи не вставляються. Поки модель "
                                + "не завантажена, працює вбудоване розпізнавання macOS.",
                                "Press the “Voice input” hotkey (fn by default), speak, press it again — the text appears at the "
                                + "cursor. Esc cancels. Speech is recognized by the NVIDIA Parakeet Ultra model on this Mac, with "
                                + "punctuation. Turkish, Hebrew and Arabic are recognized by macOS: turn on Dictation for them in "
                                + "System Settings → Keyboard. Languages not chosen above are never inserted. Until the model is "
                                + "downloaded, the built-in macOS recognition is used."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Picker(tr("Розпізнає", "Recognized by"), selection: $settings.voiceEngine) {
                            Text(tr("Цей Mac", "This Mac")).tag("local")
                            Text("Google AI").tag("google")
                        }
                        if settings.voiceEngine == "google" {
                            HStack(spacing: 8) {
                                SecureField("", text: $googleKey, prompt: Text(tr("Ключ API Google AI", "Google AI API key")))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(checkGoogleKey)
                                if checkingGoogleKey {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button(tr("Зберегти", "Save"), action: checkGoogleKey)
                                }
                            }
                            if let googleStatus {
                                Label(googleStatus.text, systemImage: googleStatus.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(googleStatus.ok ? .green : .red)
                            } else if GeminiKey.load() == nil {
                                Link(tr("Отримати ключ (безкоштовно) на aistudio.google.com", "Get a key (free) at aistudio.google.com"),
                                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                            }
                            Toggle(isOn: $settings.googleSmart) {
                                Text(tr("Розумне розпізнавання", "Smart transcription"))
                                Text(tr("Прибирає «ну», «е-е» і самовиправлення («о першій, ні, о другій» → «о другій»), оформлює списки.",
                                        "Removes fillers and self-corrections (“at one, no, at two” → “at two”), formats lists."))
                            }
                        }
                    } header: {
                        Text(tr("Розпізнавання через Google AI", "Recognition with Google AI"))
                    } footer: {
                        Text(tr("З Google AI запис після натискання надсилається в Google (вашим ключем) і розпізнається будь-якою мовою. "
                                + "Ключ зберігається в Keychain. Якщо Google недоступний, текст розпізнає цей Mac.",
                                "With Google AI the recording is sent to Google (with your key) when you finish, and any language is "
                                + "recognized. The key is kept in the Keychain. If Google can’t be reached, this Mac "
                                + "recognizes the text."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Toggle(isOn: $settings.offerVoiceCorrections) {
                            Text(tr("Пропонувати запам’ятати виправлення", "Offer to remember corrections"))
                            Text(tr("Коли ви вручну виправите одне надиктоване слово, Klavko на 5 секунд запропонує "
                                    + "писати його так і надалі (↩ — так, Esc — ні).",
                                    "When you fix one dictated word by hand, Klavko offers for 5 seconds "
                                    + "to write it that way from now on (↩ — yes, Esc — no)."))
                        }
                        HStack(spacing: 8) {
                            TextField("", text: $newSpellingHeard, prompt: Text(tr("Чує", "Heard")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("", text: $newSpellingWritten, prompt: Text(tr("Писати так", "Write as")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addSpelling)
                            Button(tr("Додати", "Add"), action: addSpelling)
                                .disabled(newSpellingHeard.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newSpellingWritten.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if settings.voiceVocabulary.isEmpty {
                            Text(tr("Поки порожньо", "Empty so far")).foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(settings.voiceVocabulary, id: \.self) { rule in
                                    RemovableChip(title: "\(rule.from) → \(rule.to)") { settings.removeVoiceSpelling(rule) }
                                }
                            }
                        }
                    } header: {
                        Text(tr("Словник голосового вводу", "Voice input vocabulary") + " (\(settings.voiceVocabulary.count))")
                    } footer: {
                        Text(tr("Як писати слова, які розпізнавання чує інакше. Власні заміни з вкладки "
                                + "«Текст» («зсу» → «ЗСУ») теж діють для голосового вводу.",
                                "How to write words that recognition hears differently. Your replacements from the "
                                + "“Text” tab (“zsu” → “ZSU”) apply to voice input too."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Picker(tr("Мікрофон", "Microphone"), selection: $settings.microphoneUID) {
                            Text(tr("Як у macOS", "As set in macOS")).tag(String?.none)
                            ForEach(AudioDevices.microphones(), id: \.uid) { microphone in
                                Text(microphone.name).tag(String?.some(microphone.uid))
                            }
                        }
                        Toggle(tr("Приглушувати інші звуки під час диктування", "Turn other sound down while dictating"),
                               isOn: $settings.duckSound)
                        HStack {
                            Text(tr("Гучність під час диктування", "Volume while dictating"))
                            Slider(value: $settings.duckLevel, in: 0...1, step: 0.05)
                            Text("\(Int((settings.duckLevel * 100).rounded())) %")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .disabled(!settings.duckSound)
                    } header: {
                        Text(tr("Мікрофон і звук", "Microphone and sound"))
                    } footer: {
                        Text(tr("Поки ви диктуєте, музика й відео звучать тихіше (0 % — без звуку), а потім гучність повертається.",
                                "While you dictate, music and videos play quieter (0 % mutes them), and the volume comes back afterwards."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Toggle(tr("Зберігати історію голосового вводу", "Keep voice input history"), isOn: $settings.saveVoiceHistory)
                        HStack {
                            Text(trFormat("Записів: %@", "Entries: %@", String(voiceHistory.history.entries.count)))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Подивитися історію", "View History"), action: showVoiceHistory)
                        }
                    } header: {
                        Text(tr("Історія голосового вводу", "Voice input history"))
                    } footer: {
                        Text(tr("Надиктований текст із датою й часом. Зберігається лише на цьому Mac.",
                                "Dictated text with its date and time. Kept on this Mac only."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Picker(tr("Перекладати на", "Translate into"), selection: $settings.voiceTranslationTarget) {
                            ForEach(Translator.ordered(TranslationDirection.languages), id: \.self) {
                                Text(Translator.languageName($0)).tag($0)
                            }
                        }
                    } header: {
                        Text(tr("Голосовий ввід із перекладом", "Voice input with translation"))
                    } footer: {
                        Text(tr("Гаряча клавіша «Голосовий ввід із перекладом» (за замовчуванням Fn+⌃) вмикає той самий голосовий ввід, але вставляє сказане вибраною мовою. Перекладає перекладач macOS на цьому Mac, без інтернету.",
                                "The “Voice input with translation” hotkey (Fn+⌃ by default) starts the same voice input but inserts what you said in the chosen language. The macOS translator does it on this Mac, without the internet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        HStack {
                            Text(trFormat("Слів сьогодні: %1$@ · усього: %2$@", "Words today: %1$@ · all time: %2$@",
                                          StatsFormat.number(voiceStats.stats.counts(.day).words),
                                          StatsFormat.number(voiceStats.stats.counts(.all).words)))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Подивитися статистику", "View Statistics"), action: showVoiceStats)
                        }
                    } header: {
                        Text(tr("Статистика голосового вводу", "Voice input statistics"))
                    } footer: {
                        Text(tr("Слова, час на диктування, зекономлений час і найчастіші слова — за день, місяць, рік і весь час. Зберігається лише на цьому Mac.",
                                "Words, time spent dictating, time saved and the most frequent words — by day, month, year and all time. Kept on this Mac only."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .quickActions:
                    quickActionsTab
                case .clipboard:
                    Section {
                        Toggle(tr("Зберігати історію буфера обміну", "Keep clipboard history"), isOn: $settings.clipboardEnabled)
                        Picker(tr("Зберігати", "Keep for"), selection: $settings.clipboardKeepDays) {
                            Text(tr("1 день", "1 day")).tag(1)
                            Text(tr("7 днів", "7 days")).tag(7)
                            Text(tr("30 днів", "30 days")).tag(30)
                            Text(tr("90 днів", "90 days")).tag(90)
                            Text(tr("Завжди", "Forever")).tag(0)
                        }
                        .disabled(!settings.clipboardEnabled)
                        .onChange(of: settings.clipboardKeepDays) { clipboard.prune() }
                        soundRow(tr("Звук під час копіювання", "Sound when copying"), isOn: $settings.playCopySound, sound: $settings.copySoundName)
                            .disabled(!settings.clipboardEnabled)
                        HStack {
                            Text(tr("Записів", "Items") + ": \(clipboard.history.items.count)")
                            Spacer()
                            Button(tr("Очистити історію", "Clear history")) { clipboard.clearUnpinned() }
                                .disabled(clipboard.history.items.allSatisfy(\.pinned))
                        }
                    } header: {
                        Text(tr("Історія буфера обміну", "Clipboard history"))
                    } footer: {
                        Text(tr("Відкривається гарячою клавішею «Історія буфера обміну» (за замовчуванням ⌥⌘V). "
                                + "Шукайте, ↩ — вставити, ⌘C — скопіювати, ⌘P — закріпити (закріплене не видаляється), "
                                + "⌘⌫ — видалити, ⌘1…⌘9 — вставити одразу. Історія зберігається лише на цьому Mac; "
                                + "паролі, які позначають менеджери паролів, не записуються.",
                                "Opens with the “Clipboard history” hotkey (⌥⌘V by default). "
                                + "Search, ↩ — paste, ⌘C — copy, ⌘P — pin (pinned items are never removed), "
                                + "⌘⌫ — delete, ⌘1…⌘9 — paste right away. The history stays on this Mac only; "
                                + "passwords marked by password managers are never recorded."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section(tr("Не записувати з програм", "Don’t record from these apps")) {
                        appList(settings.clipboardIgnoredApps, remove: { settings.toggleClipboardIgnored($0) },
                                add: { pickApps(adding: settings.clipboardIgnoredApps) { settings.toggleClipboardIgnored($0) } })
                    }
                case .hotkeys:
                    Section {
                        ForEach(HotkeyAction.allCases, id: \.self) { action in
                            shortcutRow(action)
                        }
                        Toggle(tr("Розрізняти лівий і правий ⌃ ⌥ ⇧ ⌘", "Tell left and right ⌃ ⌥ ⇧ ⌘ apart"), isOn: $settings.modifierSides)
                            .help(tr("Нова комбінація запам'ятовує, яку з двох клавіш натиснуто: «правий ⌘» не спрацює від лівого. "
                                     + "Уже задані комбінації не змінюються, їх треба записати знову.",
                                     "A new shortcut remembers which of the two keys was pressed: “right ⌘” won’t fire from the left one. "
                                     + "Shortcuts already set stay as they are until recorded again."))
                        Button(tr("Відновити стандартні", "Restore Defaults")) { settings.resetShortcuts() }
                    } header: {
                        Text(tr("Гарячі клавіші", "Hotkeys"))
                    } footer: {
                        Text(tr("Клацніть на комбінацію і натисніть нову: клавішу з ⌃ ⌥ ⇧ ⌘, лише модифікатори разом "
                                + "(наприклад ⌥⌘) або двічі швидко ті самі модифікатори. Esc — скасувати. "
                                + "Якщо нічого не виділено, змінюється весь текст, набраний після останнього кліку, Enter чи стрілок.",
                                "Click a shortcut and press a new one: a key with ⌃ ⌥ ⇧ ⌘, modifiers alone together "
                                + "(for example ⌥⌘) or the same modifiers twice quickly. Esc — cancel. "
                                + "With nothing selected, all text typed since the last click, Return or arrow key is changed."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(SystemLayouts.allLayouts(), id: \.id) { layout in
                            layoutShortcutRow(id: layout.id, name: layout.name)
                        }
                    } header: {
                        Text(tr("Увімкнути розкладку", "Switch to a layout"))
                    } footer: {
                        Text(tr("Своя клавіша для кожної розкладки: наприклад, лівий ⌘ — українська, правий ⌘ — англійська. "
                                + "Клацніть і натисніть клавішу з ⌃ ⌥ ⇧ ⌘ або сам модифікатор — він запам’ятовується разом зі стороною. "
                                + "Модифікатор перемикає, лише коли його натиснули й відпустили окремо: ⌘C чи ⌘-клік розкладку не змінюють.",
                                "A key of its own for each layout: for example, left ⌘ for Ukrainian, right ⌘ for English. "
                                + "Click and press a key with ⌃ ⌥ ⇧ ⌘, or a modifier alone — it is remembered with its side. "
                                + "A modifier switches only when pressed and released on its own: ⌘C or a ⌘-click leaves the layout as it is."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle(tr("Замінювати клавіші", "Remap keys"), isOn: $settings.keyRemapsEnabled)
                        ForEach(settings.keyRemaps) { rule in
                            remapRow(rule)
                        }
                        remapAdder
                    } header: {
                        Text(tr("Заміна клавіш", "Key remapping"))
                    } footer: {
                        Text(tr("Клавіша чи комбінація зліва діє як та, що справа, у всіх програмах і розкладках. "
                                + "Клацніть «Клавіша…» й натисніть клавішу (можна з ⌃ ⌥ ⇧ ⌘), потім «Чим стане…» й натисніть ту, що має бути замість неї, і «Додати». "
                                + "Заміна окремої клавіші діє і з модифікаторами: з ⇧ вона друкує велику літеру. "
                                + "⇄ додає таку саму заміну навпаки. У полях паролів macOS заміна не діє.",
                                "The key or combination on the left acts as the one on the right, in every app and layout. "
                                + "Click “Key…” and press a key (with ⌃ ⌥ ⇧ ⌘ if you like), then “What it becomes…” and press the one it should become, and Add. "
                                + "A single key’s remapping works with modifiers too: with ⇧ it types a capital. "
                                + "⇄ adds the same remapping the other way round. macOS password fields aren’t remapped."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .about:
                    AboutSection(settings: settings, updater: updater)

                case .thanks:
                    ThanksSection()

                case .whatsNew:
                    WhatsNewSection()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 790, height: height)
        .onAppear {
            tab = initialTab
            loadLayoutLanguages()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String))) { _ in loadLayoutLanguages() }
        .onDisappear { recorder.stop() }
    }

    private func loadLayoutLanguages() {
        layoutLanguages = Translator.ordered(Array(Set(SystemLayouts.allLayouts().compactMap(\.language))))
    }

    /// The layouts' languages, and the chosen one even if its layout was removed.
    private var capsLockLanguages: [String] {
        layoutLanguages.contains(settings.capsLockLanguage) ? layoutLanguages : layoutLanguages + [settings.capsLockLanguage]
    }

    private func soundRow(_ title: String, isOn: Binding<Bool>, sound: Binding<String>) -> some View {
        // Switch at the right edge, like every other row.
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: sound) {
                ForEach(Settings.sounds, id: \.self) { Text(SoundPlayer.title($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(!isOn.wrappedValue)
            Button {
                previewSound(sound.wrappedValue)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(tr("Прослухати", "Listen"))
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func shortcutRow(_ action: HotkeyAction) -> some View {
        shortcutPicker(action.title, shortcut: settings.shortcuts[action], isRecording: recorder.recording == action,
                       record: { recorder.start(action, recordsSides: settings.modifierSides) { settings.setShortcut($0, for: action) } },
                       clear: { settings.setShortcut(nil, for: action) })
    }

    private func layoutShortcutRow(id: String, name: String) -> some View {
        shortcutPicker(name, shortcut: settings.layoutShortcuts[id], isRecording: recorder.recordingLayout == id,
                       record: { recorder.startLayout(id, recordsSides: settings.modifierSides) { settings.setLayoutShortcut($0, for: id) } },
                       clear: { settings.setLayoutShortcut(nil, for: id) })
    }

    private func shortcutPicker(_ title: String, shortcut: Shortcut?, isRecording: Bool,
                                record: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                if isRecording { recorder.stop() } else { record() }
            } label: {
                if isRecording {
                    Text(tr("Натисніть…", "Press keys…"))
                        .foregroundStyle(Color.accentColor)
                } else if let shortcut {
                    HStack(spacing: 4) {
                        ForEach(Array(shortcut.parts(layout: keyLayout).enumerated()), id: \.offset) { _, part in
                            Keycap(text: part)
                        }
                    }
                } else {
                    Text(tr("Не задано", "Not set")).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(tr("Клацніть, щоб змінити", "Click to change"))

            Button(action: clear) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(tr("Прибрати гарячу клавішу", "Remove the hotkey"))
            .opacity(shortcut == nil ? 0 : 1)
            .disabled(shortcut == nil)
        }
    }

    private func remapRow(_ rule: KeyRemap) -> some View {
        HStack {
            keycaps(remapParts(rule.from))
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            keycaps(remapParts(rule.to))
            Spacer()
            Button {
                settings.addKeyRemap(rule.reversed)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help(tr("Додати таку саму заміну навпаки", "Add the same remapping the other way round"))
            .disabled(settings.keyRemaps.contains { $0.from == rule.to && $0.to == rule.from })
            Button {
                settings.removeKeyRemap(rule)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(tr("Прибрати заміну", "Remove the remapping"))
        }
    }

    /// Two keys to record, each on its own click, then «Додати».
    private var remapAdder: some View {
        HStack {
            remapKeyButton("from", combo: newRemapFrom, empty: tr("Клавіша…", "Key…")) { newRemapFrom = $0 }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            remapKeyButton("to", combo: newRemapTo, empty: tr("Чим стане…", "What it becomes…")) { newRemapTo = $0 }
            Spacer()
            Button(tr("Додати", "Add")) {
                guard let from = newRemapFrom, let to = newRemapTo else { return }
                settings.addKeyRemap(KeyRemap(from: from, to: to))
                newRemapFrom = nil
                newRemapTo = nil
            }
            .disabled(newRemapFrom == nil || newRemapTo == nil || newRemapFrom == newRemapTo)
        }
    }

    /// Click, then press the key (with modifiers or without); click again to cancel.
    private func remapKeyButton(_ slot: String, combo: KeyCombo?, empty: String,
                                recorded: @escaping (KeyCombo) -> Void) -> some View {
        Button {
            if recorder.recordingKey == slot {
                recorder.stop()
            } else {
                recorder.recordKey(slot, completion: recorded)
            }
        } label: {
            if recorder.recordingKey == slot {
                Text(tr("Натисніть клавішу…", "Press a key…")).foregroundStyle(Color.accentColor)
            } else if let combo {
                keycaps(remapParts(combo))
            } else {
                Text(empty)
            }
        }
        .buttonStyle(.bordered)
    }

    private func keycaps(_ parts: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in Keycap(text: part) }
        }
    }

    /// The key as the layouts in use name it: «Ґ \\», «Space».
    private func remapParts(_ combo: KeyCombo) -> [String] {
        var parts = combo.parts(layout: keyLayout)
        let english = parts.removeLast()
        let others = SystemLayouts.enabledLayouts().map(\.map).filter { $0.language != "en" }
            .compactMap { $0.character(for: Keystroke(keyCode: combo.keyCode))?.uppercased() }
            .filter { $0 != english && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let names = KeyNames.isSpecial(combo.keyCode) ? [english] : Array(NSOrderedSet(array: others + [english])) as! [String]
        return parts + [names.joined(separator: " ")]
    }

    /// The interface language in use first, the others in alphabetical order of their own names.
    static func interfaceLanguages() -> [AppLanguage] {
        let current = AppLanguage.current
        return [current] + AppLanguage.allCases.filter { $0 != current }.sorted {
            $0.title.compare($1.title, options: [.caseInsensitive, .diacriticInsensitive], locale: current.locale)
                == .orderedAscending
        }
    }

    /// Names for apps in the default lists, shown even when they aren't installed.
    private static let knownApps = [
        "com.googlecode.iterm2": "iTerm2", "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.Zed": "Zed", "com.sublimetext.4": "Sublime Text",
        "com.apple.Terminal": "Terminal", "com.apple.dt.Xcode": "Xcode", "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7", "com.bitwarden.desktop": "Bitwarden",
        "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords",
        "org.keepassxc.keepassxc": "KeePassXC",
    ]

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return knownApps[bundleID] ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

enum SettingsTab: String, CaseIterable {
    case general, layout, text, voice, quickActions, clipboard, hotkeys, about, thanks, whatsNew

    /// Listed apart, at the bottom of the sidebar.
    var isExtra: Bool { self == .thanks || self == .whatsNew }

    var title: String {
        switch self {
        case .general: tr("Загальні", "General")
        case .layout: tr("Розкладка", "Layout")
        case .text: tr("Текст", "Text")
        case .voice: tr("Голос", "Voice")
        case .quickActions: tr("Швидкі дії", "Quick Actions")
        case .clipboard: tr("Буфер", "Clipboard")
        case .about: tr("Про Klavko", "About")
        case .hotkeys: tr("Клавіші", "Hotkeys")
        case .thanks: tr("Подякувати", "Say Thanks")
        case .whatsNew: tr("Що нового", "What’s New")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "keyboard"
        case .text: "textformat"
        case .voice: "waveform"
        case .quickActions: "text.cursor"
        case .clipboard: "doc.on.clipboard"
        case .about: "info.circle"
        case .hotkeys: "command"
        case .thanks: "heart"
        case .whatsNew: "sparkles"
        }
    }
}

/// The tabs listed down the left side, each an icon beside its title, like System Settings;
/// "Say Thanks" and "What's New" apart at the bottom.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases.filter { !$0.isExtra }, id: \.self, content: row)
            Spacer()
            Divider().padding(.vertical, 6)
            ForEach(SettingsTab.allCases.filter(\.isExtra), id: \.self, content: row)
        }
        .padding(10)
        .frame(width: 190)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ tab: SettingsTab) -> some View {
        Button {
            selection = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(selection == tab ? Color.white : (tab == .thanks ? Color.pink : Color.accentColor))
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selection == tab ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(selection == tab ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Dark rounded key label, like "Double", "⌥", "Space".
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.78)))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }
}

/// On/off chip for a set of options.
private struct ChipToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.25)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// An app with its icon and a × to remove it.
private struct AppChip: View {
    let name: String
    let icon: NSImage?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16, height: 16)
            }
            Text(name).font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(trFormat("Прибрати «%@»", "Remove “%@”", name))
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

/// A word with a × to remove it.
private struct RemovableChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(trFormat("Прибрати «%@»", "Remove “%@”", title))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
