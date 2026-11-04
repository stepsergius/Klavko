import AppKit
import KlavkoCore
import SwiftUI

/// "Say Thanks" in Settings: why and how to support Klavko (the Monobank jar), and a GitHub star.
struct ThanksSection: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Color.pink.opacity(0.15))
                        Image(systemName: "heart.fill").font(.system(size: 24)).foregroundStyle(.pink)
                    }
                    .frame(width: 52, height: 52)
                    Text(tr("Допоможіть Klavko розвиватися", "Help Klavko grow"))
                        .font(.system(size: 20, weight: .bold))
                }
                Text(tr("Klavko залишається безкоштовним і працює лише на вашому Mac, без реклами й стеження. "
                        + "Якщо він вам допомагає, підтримати розробку можна через банку Monobank.",
                        "Klavko stays free and runs only on your Mac, with no ads or tracking. "
                        + "If it helps you, you can support its development through a Monobank jar."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let donate = AboutInfo.donateURL {
                    Button {
                        NSWorkspace.shared.open(donate)
                    } label: {
                        Label(tr("Підтримати через Monobank", "Support via Monobank"), systemImage: "heart.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
                Link(destination: AboutInfo.repository) {
                    Label(tr("Зірка на GitHub теж допомагає людям дізнатися про Klavko.",
                             "A star on GitHub also helps people find Klavko."), systemImage: "star")
                }
                .foregroundStyle(.secondary)
                Text(tr("Дякуємо, що ви з нами.", "Thank you for being here.") + " 🖤")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        }
    }
}

/// "What's New" in Settings: the changes of each version since 0.13, newest first.
/// In Ukrainian or English, like the release notes.
struct WhatsNewSection: View {
    private struct Version {
        let number: String
        let uk: [String]
        let en: [String]
    }

    private static let versions: [Version] = [
        Version(number: "1.1.0", uk: [
            "**Своя розкладка в кожній програмі:** Klavko вмикає ту, якою ви там писали; розкладку можна закріпити за програмою в «Налаштування → Розкладка» або з меню.",
            "**Окрема гаряча клавіша для кожної розкладки** — навіть сам модифікатор зі стороною: лівий ⌘ для української, правий ⌘ для англійської.",
            "**Голосові команди:** «кома», «крапка», «знак питання», «новий рядок», «новий абзац» та інші ставлять знак, а «буквально кома» — саме слово.",
            "**Мій словник:** «Додати до словника» біля підкресленого слова — і воно більше не вважається помилкою.",
            "**Статистика голосового вводу по датах:** дні періоду, попередні місяці й роки, графіки за місяцями й роками.",
            "**Перенесення налаштувань:** «Налаштування → Загальні → Зберегти у файл… / Відновити з файлу…».",
            "**«Обчислити»** у швидких діях замість «Суми чисел»: `1 250 * 3 + 15%`; текст із числами, як і раніше, додається.",
            "**Результат після «=»:** наберіть `2+3*4=` чи `Ціна 25*4=` — результат з’явиться біля курсора, Return або Tab вставляє його.",
            "**Транслітерація** у швидких діях за офіційною системою мови: українська, білоруська, болгарська, сербська, македонська.",
            "⌘C у Slack і VS Code знову завжди копіює, коли працює Klavko.",
            "Голосовий ввід: короткі українські фрази більше не сприймаються як російські, фраза після нового рядка не замінює попередню, а новий рядок у вебредакторах не губить текст.",
            "Підкреслення помилок в Outlook стоять під своїми словами й не виходять за межі листа.",
        ], en: [
            "**A layout for each app:** Klavko switches to the one you typed there; pin a layout to an app in Settings → Layout or from the menu.",
            "**A hotkey for each layout** — even a lone modifier by its side: left ⌘ for Ukrainian, right ⌘ for English.",
            "**Voice commands:** “comma”, “period”, “question mark”, “new line”, “new paragraph” and more put the mark, and “literally comma” the word itself.",
            "**My Dictionary:** Add to Dictionary next to an underlined word, and it’s no longer taken for a mistake.",
            "**Voice statistics by date:** the days of each period, earlier months and years, charts by month and by year.",
            "**Move your settings:** Settings → General → Save to File… / Restore from File…",
            "**Calculate** in Quick Actions instead of Sum of Numbers: `1,250 * 3 + 15%`; text with numbers is still added up.",
            "**The answer after “=”:** type `2+3*4=` or `Price 25*4=` and the answer appears by the caret; Return or Tab inserts it.",
            "**Transliterate** in Quick Actions, by each language’s official system: Ukrainian, Belarusian, Bulgarian, Serbian, Macedonian.",
            "⌘C in Slack and VS Code always copies again while Klavko runs.",
            "Voice input: short Ukrainian phrases are no longer taken for Russian, a phrase after a new line no longer replaces the one before, and a new line in web editors no longer loses text.",
            "Mistake underlines in Outlook sit under their words and stay inside the letter.",
        ]),
        Version(number: "1.0.1", uk: [
            "**Вимикач голосового вводу** в «Налаштування → Голос»: коли вимкнено, гарячі клавіші голосу нічого не роблять, а fn працює як звичайно.",
            "Історія буфера обміну, історія й статистика голосового вводу більше не зникають після перезавантаження Mac.",
            "Голосовий ввід більше не губить надиктоване, коли на Mac немає українського розпізнавання macOS.",
            "Картка «Запам’ятати для голосового вводу?» більше не з’являється, коли в слові змінився лише апостроф.",
        ], en: [
            "**A voice input switch** in Settings → Voice: when it’s off, the voice hotkeys do nothing and fn works as usual.",
            "Clipboard history, voice input history and statistics no longer disappear after the Mac restarts.",
            "Voice input no longer loses what you said when the Mac has no macOS Ukrainian recognizer.",
            "The “Remember for voice input?” card no longer appears when only an apostrophe changed.",
        ]),
        Version(number: "1.0.0", uk: [
            "**Швидкі дії над виділеним текстом:** панель із копіюванням, пошуком, перекладом, регістром, лапками й дужками, жирним і курсивом, ChatGPT, Claude і Perplexity; дії можна переставляти в налаштуваннях.",
            "**Емодзі за назвою:** пробіл, двокрапка й назва («:сміх», «:серце») показують емодзі біля курсора; після слова Klavko може сам запропонувати емодзі.",
            "**Перевірка правопису й граматики** з LanguageTool на цьому Mac: ⌃⌥G або «Швидкі дії», а за бажанням — підкреслення під час набору, також в Obsidian і Google Docs.",
            "**Голосовий ввід із перекладом:** Fn+⌃ — диктуєте однією мовою, вставляється перекладений текст (перекладач macOS, без інтернету).",
            "**Вигляд голосового вводу на вибір:** острівець біля камери, маленька панель із текстом або «без вікна».",
            "**Статистика голосового вводу** в «Налаштування → Голос» і привітання на 1 000, 10 000 слів і далі — уже після того, як текст вставлено.",
            "**Заміна клавіш:** будь-яка клавіша чи комбінація може працювати як інша, в усіх програмах.",
            "**Вітальне вікно** при першому запуску; відкрити його знову — «Як користуватися» в меню.",
            "**Група в Telegram** для запитань, помилок і пропозицій — кнопка в «Про Klavko».",
            "Голосовий ввід з AirPods більше не збоїть після зміни мікрофона.",
        ], en: [
            "**Quick Actions for selected text:** a bar with copy, search, translate, case, quotes and brackets, bold and italic, ChatGPT, Claude and Perplexity; reorder the actions in Settings.",
            "**Emoji by name:** a space, a colon and a name (“:laugh”, “:heart”) show emoji at the caret; after a word Klavko can suggest emoji itself.",
            "**Spelling and grammar check** with LanguageTool on this Mac: ⌃⌥G or Quick Actions, and, if you like, underlines while you type, also in Obsidian and Google Docs.",
            "**Voice input with translation:** Fn+⌃ — speak in one language, the translated text is inserted (the macOS translator, offline).",
            "**Choose how voice input looks:** an island by the camera, a small panel with the text, or no window.",
            "**Voice input statistics** in Settings → Voice, and congratulations at 1,000, 10,000 words and on — once the text is in.",
            "**Key remapping:** any key or combination can act as another, in every app.",
            "**A welcome window** on the first launch; open it again with How to Use in the menu.",
            "**A Telegram group** for questions, bugs and ideas — a button in About.",
            "Voice input with AirPods no longer fails after the microphone changes.",
        ]),
        Version(number: "0.15.0", uk: [
            "**QR-коди** в «Тексті з екрана» (⌃Q): виділіть QR-код — Klavko покаже, що в ньому; посилання відкривається клавішею Enter.",
            "**Історія голосового вводу:** надиктоване зберігається з датою й часом (лише на цьому Mac); кожен запис можна скопіювати чи видалити.",
            "**Вибір мікрофона** для голосового вводу.",
            "**Тихіше під час диктування:** музика й відео приглушуються, поки ви говорите; гучність налаштовується.",
            "**Лампочка Caps Lock показує мову** (за бажанням): світиться для вибраної мови.",
            "**Нові звуки** для перемикання розкладки, виправлень і копіювання; посилання в тексті з буфера клікабельні; пошук в історії голосу.",
            "Налаштування з бічною панеллю, «Подякувати» й «Що нового»; у меню — «Перевірити оновлення».",
        ], en: [
            "**QR codes** in Text from the Screen (⌃Q): select a QR code and Klavko shows what it holds; a link opens with Return.",
            "**Voice input history:** what you dictate is kept with its date and time (on this Mac only); copy or delete each entry.",
            "**Choose the microphone** for voice input.",
            "**Quieter while dictating:** music and videos are turned down while you speak; the volume is adjustable.",
            "**The Caps Lock light shows the language** (optional): lit for the language you choose.",
            "**New sounds** for layout switching, fixes and copying; clickable links in copied text; search in the voice history.",
            "Settings with a sidebar, Say Thanks and What’s New; Check for Updates in the menu.",
        ]),
        Version(number: "0.14.0", uk: [
            "**Точніше перемикання розкладки:** Klavko зважає на кілька попередніх слів; мову, якою пишете рідко, можна позначити «лише вручну».",
            "**«є» замість «э»:** окреме «є», набране в російській розкладці, виправляється, щойно далі йде український текст.",
            "**«GHbdsn» → «Привіт»:** залиплий Shift виправляється разом із розкладкою, а слово, яке ви правили вручну, Klavko не чіпає.",
            "**Розкладка з меню:** список розкладок із прапорами; тире, лапки й три крапки вмикаються окремо.",
            "**Лівий і правий ⌃ ⌥ ⇧ ⌘:** гаряча клавіша може спрацьовувати лише від однієї клавіші.",
            "Після оновлення — вікно з подякою; зміна однієї великої літери після голосового вводу не пропонується до запам’ятовування.",
        ], en: [
            "**More accurate layout switching:** Klavko looks at several words before; a language you rarely write in can be “only by hand”.",
            "**«є» instead of «э»:** a lone «є» typed in the Russian layout is fixed as soon as Ukrainian text follows.",
            "**“GHbdsn” → “Привіт”:** a stuck Shift is fixed with the layout, and a word you edited by hand is left alone.",
            "**Layouts in the menu** with their flags; the long dash, curly quotes and the ellipsis have their own switches.",
            "**Left and right ⌃ ⌥ ⇧ ⌘:** a hotkey can fire from one key only.",
            "A thank-you window after an update; changing one capital letter after voice input isn’t offered to remember.",
        ]),
        Version(number: "0.13.0", uk: [
            "**Текст з екрана** (⌃Q): виділіть область екрана — Klavko прочитає текст і перекладе його.",
            "**Переклад між 12 мовами:** пару вибирають у налаштуваннях, мови можна змінити прямо у вікні перекладу.",
            "**Інтерфейс 12 мовами;** перемикання розкладки для 13 мов і голосовий ввід кількома мовами.",
            "**Розпізнавання голосу через Google AI** — за бажанням, з вашим ключем.",
            "Меню показує гарячі клавіші, вікно оновлення — що нового.",
        ], en: [
            "**Text from the screen** (⌃Q): select an area and Klavko reads the text and translates it.",
            "**Translation between 12 languages:** choose the pair in Settings or change it right in the translation panel.",
            "**Interface in 12 languages;** layout switching for 13 languages and voice input in several.",
            "**Optional Google AI voice recognition** with your own key.",
            "The menu shows hotkeys, the update prompt shows what’s new.",
        ]),
    ]

    var body: some View {
        ForEach(Self.versions, id: \.number) { version in
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((AppLanguage.current == .ukrainian ? version.uk : version.en).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(Color.accentColor)
                            Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Klavko " + version.number)
            }
        }
        Section {
            Link(tr("Усі зміни на GitHub", "All changes on GitHub"), destination: Updater.releasesPage)
        }
    }
}
