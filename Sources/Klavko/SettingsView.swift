import AppKit
import Carbon
import KlavkoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var parakeet: ParakeetEngine
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var updater: Updater
    /// English layout, used to name letter keys in shortcuts.
    let keyLayout: LayoutMap?
    let previewSound: (String) -> Void
    /// Taller only for a full-length snapshot of the window.
    var height: CGFloat = 620

    @State private var newException = ""
    @State private var newReplacementFrom = ""
    @State private var newReplacementTo = ""
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

    private func addReplacement() {
        if settings.setReplacement(from: newReplacementFrom, to: newReplacementTo) {
            newReplacementFrom = ""
            newReplacementTo = ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
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

                case .about:
                    AboutSection(settings: settings, updater: updater)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: height)
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
                ForEach(Settings.sounds, id: \.self) { Text($0).tag($0) }
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
        HStack {
            Text(action.title)
            Spacer()
            Button {
                if recorder.recording == action {
                    recorder.stop()
                } else {
                    recorder.start(action, recordsSides: settings.modifierSides) { settings.setShortcut($0, for: action) }
                }
            } label: {
                if recorder.recording == action {
                    Text(tr("Натисніть…", "Press keys…"))
                        .foregroundStyle(Color.accentColor)
                } else if let shortcut = settings.shortcuts[action] {
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

            Button {
                settings.setShortcut(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(tr("Прибрати гарячу клавішу", "Remove the hotkey"))
            .opacity(settings.shortcuts[action] == nil ? 0 : 1)
            .disabled(settings.shortcuts[action] == nil)
        }
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
    case general, layout, text, voice, clipboard, hotkeys, about

    var title: String {
        switch self {
        case .general: tr("Загальні", "General")
        case .layout: tr("Розкладка", "Layout")
        case .text: tr("Текст", "Text")
        case .voice: tr("Голос", "Voice")
        case .clipboard: tr("Буфер", "Clipboard")
        case .about: tr("Про Klavko", "About")
        case .hotkeys: tr("Клавіші", "Hotkeys")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "keyboard"
        case .text: "textformat"
        case .voice: "waveform"
        case .clipboard: "doc.on.clipboard"
        case .about: "info.circle"
        case .hotkeys: "command"
        }
    }
}

/// Icons with titles in a row at the top, like the tabs of macOS settings windows.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .frame(width: 78, height: 50)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selection == tab ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Dark rounded key label, like "Double", "⌥", "Space".
private struct Keycap: View {
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
