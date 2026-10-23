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
        Version(number: "0.15.0", uk: [
            "**QR-коди** в «Тексті з екрана» (⌃Q): виділіть QR-код — Klavko покаже, що в ньому; посилання відкривається клавішею Enter.",
            "**Історія голосового вводу:** надиктоване зберігається з датою й часом (лише на цьому Mac); кожен запис можна скопіювати чи видалити.",
            "**Вибір мікрофона** для голосового вводу.",
            "**Тихіше під час диктування:** музика й відео приглушуються, поки ви говорите; гучність налаштовується.",
            "**Нові звуки** для перемикання розкладки, виправлень і копіювання.",
            "Налаштування з бічною панеллю, «Подякувати» й «Що нового»; у меню — «Перевірити оновлення».",
        ], en: [
            "**QR codes** in Text from the Screen (⌃Q): select a QR code and Klavko shows what it holds; a link opens with Return.",
            "**Voice input history:** what you dictate is kept with its date and time (on this Mac only); copy or delete each entry.",
            "**Choose the microphone** for voice input.",
            "**Quieter while dictating:** music and videos are turned down while you speak; the volume is adjustable.",
            "**New sounds** for layout switching, fixes and copying.",
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
