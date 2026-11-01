import AppKit
import AVFoundation
import KlavkoCore
import Speech
import SwiftUI

/// The first launch: Klavko is running (in the menu bar), what it does, the permissions it needs and where its
/// settings are, a page at a time.
@MainActor
final class WelcomeWindow {
    private var window: NSWindow?

    struct Context {
        /// What Klavko shows in the menu bar now: the layout's flag, or nil for the keyboard symbol.
        var menuBarMark: String?
        var shortcuts: [HotkeyAction: Shortcut]
        var layout: LayoutMap?
        var settings: Settings
        var requestAccessibility: () -> Void
        var openSettings: () -> Void
    }

    func show(_ context: Context) {
        window?.close()
        let window = Self.makeWindow(WelcomeView(context: context, close: { [weak self] in self?.window?.close() }))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private static func makeWindow(_ view: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = tr("Вітаємо в Klavko", "Welcome to Klavko")
        window.isReleasedWhenClosed = false
        return window
    }

    /// Developer check of the window's look: renders each page into `folder` (welcome-1.png…) and quits.
    static func snapshot(to folder: URL, _ context: Context) {
        func render(_ page: Int) {
            guard page < WelcomeView.Page.allCases.count else { NSApp.terminate(nil); return }
            let hosting = NSHostingView(rootView: WelcomeView(context: context, close: {}, page: WelcomeView.Page.allCases[page]))
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("welcome-\(page + 1).png"))
                }
                window.orderOut(nil)
                render(page + 1)
            }
        }
        render(0)
    }
}

private struct WelcomeView: View {
    enum Page: Int, CaseIterable { case hello, features, permissions, settings }

    let context: WelcomeWindow.Context
    let close: () -> Void
    @State var page: Page = .hello
    @State private var forward = true

    init(context: WelcomeWindow.Context, close: @escaping () -> Void, page: Page = .hello) {
        self.context = context
        self.close = close
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case .hello: HelloPage(mark: context.menuBarMark)
                case .features: FeaturesPage(shortcuts: context.shortcuts, layout: context.layout)
                case .permissions: PermissionsPage(requestAccessibility: context.requestAccessibility)
                case .settings: SettingsPage(settings: context.settings, mark: context.menuBarMark,
                                              openSettings: { close(); context.openSettings() })
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 640, height: 600)
        .background(WelcomeBackground())
    }

    private var footer: some View {
        HStack {
            Group {
                if page != .hello {
                    Button(tr("Назад", "Back")) { go(to: page.rawValue - 1) }
                        .controlSize(.large)
                } else {
                    Button(tr("Пропустити", "Skip"), action: close)
                        .controlSize(.large)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)
            Spacer()
            HStack(spacing: 8) {
                ForEach(Page.allCases, id: \.self) { each in
                    Capsule()
                        .fill(each == page ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: each == page ? 20 : 7, height: 7)
                        .onTapGesture { go(to: each.rawValue) }
                }
            }
            .animation(.spring(duration: 0.35), value: page)
            Spacer()
            Group {
                if page == .settings {
                    Button(tr("Почати", "Get Started"), action: close)
                } else {
                    Button(tr("Далі", "Continue")) { go(to: page.rawValue + 1) }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func go(to index: Int) {
        guard let next = Page(rawValue: index), next != page else { return }
        forward = next.rawValue > page.rawValue
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { page = next }
    }
}

/// A soft wash of colour over the window's material, like the Mac's own setup screens.
private struct WelcomeBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            VisualEffect()
            RadialGradient(colors: [Color.blue.opacity(scheme == .dark ? 0.28 : 0.16), .clear],
                           center: .init(x: 0.15, y: 0.0), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.purple.opacity(scheme == .dark ? 0.22 : 0.12), .clear],
                           center: .init(x: 0.95, y: 0.25), startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Pages

private struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 480)
    }
}

private struct HelloPage: View {
    let mark: String?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 10) {
                Text(tr("Вітаємо в Klavko", "Welcome to Klavko"))
                    .font(.system(size: 34, weight: .bold))
                Text(tr("Klavko виправляє розкладку й помилки просто під час набору, друкує голосом, перекладає й пам’ятає, що ви копіювали. Усе — на вашому Mac.",
                        "Klavko fixes the layout and typos as you type, types what you say, translates and remembers what you copied. All on your Mac."))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470)
            }
            MenuBarSketch(mark: mark)
                .padding(.top, 6)
            Text(tr("Klavko уже працює. Його значок — у рядку меню вгорі екрана.",
                    "Klavko is already running. Its icon is in the menu bar at the top of the screen."))
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.3)) { appeared = true } }
    }
}

/// A sketch of the right end of the menu bar, Klavko's icon picked out (with its menu open, as on the last page).
private struct MenuBarSketch: View {
    let mark: String?
    var menu = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            klavko
                .overlay(alignment: .topLeading) {
                    if menu { dropDown.offset(x: -6, y: 30) }
                }
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            Text("9:41").font(.system(size: 13, weight: .medium))
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08)))
        // Room for the menu under the bar.
        .padding(.bottom, menu ? 175 : 0)
    }

    private var klavko: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.22))
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
            if let mark {
                Text(mark).font(.system(size: 14))
            } else {
                Image(systemName: "keyboard")
            }
        }
        .frame(width: 32, height: 22)
    }

    /// Klavko's menu, shortened.
    private var dropDown: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuLine(tr("Автоматично виправляти розкладку", "Fix Layout Automatically"), check: true)
            menuLine(tr("Виправляти помилки", "Fix Typos"), check: true)
            Divider().padding(.vertical, 3)
            menuLine(tr("Перевірити оновлення", "Check for Updates"))
            menuLine(tr("Як користуватися", "How to Use"))
            menuLine(tr("Налаштування", "Settings"), picked: true)
            Divider().padding(.vertical, 3)
            menuLine(tr("Вийти з Klavko", "Quit Klavko"))
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(6)
        .frame(minWidth: 220)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .fixedSize()
    }

    private func menuLine(_ title: String, check: Bool = false, picked: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").opacity(check ? 1 : 0).font(.system(size: 11, weight: .semibold))
            Text(title).lineLimit(1).fixedSize()
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(picked ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.accentColor : .clear))
    }
}

private struct FeaturesPage: View {
    let shortcuts: [HotkeyAction: Shortcut]
    let layout: LayoutMap?

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(title: tr("Що вміє Klavko", "What Klavko Does"),
                      subtitle: tr("Більшість працює сама. Для решти — кілька клавіш.",
                                   "Most of it works by itself. For the rest, a few keys."))
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(symbol: "keyboard", colors: [.blue, .cyan],
                           title: tr("Правильна розкладка", "The Right Layout"),
                           text: tr("«ghbdsn» стає «привіт» саме. Або натисніть клавіші, щоб змінити розкладку слова.",
                                    "“ghbdsn” turns into “привіт” by itself. Or press the keys to switch the layout of a word."),
                           keys: parts(.convertWord))
                FeatureRow(symbol: "text.badge.checkmark", colors: [.green, .mint],
                           title: tr("Без помилок", "No Typos"),
                           text: tr("Виправляє одруківки, ставить велику літеру, лапки й тире.",
                                    "Fixes typos, adds capital letters, proper quotes and dashes."))
                FeatureRow(symbol: "mic.fill", colors: [.orange, .red],
                           title: tr("Голосовий ввід", "Voice Input"),
                           text: tr("Говоріть — текст з’явиться там, де курсор.", "Speak, and the text appears at the cursor."),
                           keys: parts(.voice))
                FeatureRow(symbol: "character.bubble.fill", colors: [.purple, .indigo],
                           title: tr("Переклад", "Translation"),
                           text: tr("Перекладає виділений текст, а також текст з екрана.", "Translates the selected text, and text on the screen."),
                           keys: parts(.translate))
                FeatureRow(symbol: "doc.on.clipboard.fill", colors: [.teal, .blue],
                           title: tr("Історія буфера обміну", "Clipboard History"),
                           text: tr("Усе, що ви копіювали, — під рукою.", "Everything you copied, at hand."),
                           keys: parts(.clipboard))
                FeatureRow(symbol: "sparkles", colors: [.pink, .orange],
                           title: tr("Швидкі дії та емодзі", "Quick Actions and Emoji"),
                           text: tr("Виділіть текст мишкою — з’являться дії. Двокрапка й назва — емодзі: «:серце».",
                                    "Select text with the mouse for actions. A colon and a name for emoji: “:heart”."))
            }
            .frame(maxWidth: 540)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
    }

    private func parts(_ action: HotkeyAction) -> [String] {
        shortcuts[action]?.parts(layout: layout) ?? []
    }
}

private struct FeatureIcon: View {
    let symbol: String
    let colors: [Color]

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 40, height: 40)
            .overlay(Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: colors[0].opacity(0.3), radius: 4, y: 2)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let text: String
    var keys: [String] = []

    var body: some View {
        HStack(spacing: 14) {
            FeatureIcon(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !keys.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Keycap(text: key) }
                }
            }
        }
    }
}

private struct PermissionsPage: View {
    let requestAccessibility: () -> Void
    @State private var status = PermissionStatus.now()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(title: tr("Дозволи", "Permissions"),
                      subtitle: tr("Klavko працює лише на вашому Mac і нічого не надсилає. Дозволи потрібні, щоб бачити натискання клавіш і вставляти текст.",
                                   "Klavko works only on your Mac and sends nothing anywhere. It needs permissions to see key presses and insert text."))
            VStack(spacing: 12) {
                PermissionRow(symbol: "accessibility", colors: [.blue, .indigo],
                              title: tr("Універсальний доступ", "Accessibility"),
                              text: tr("Обов’язково: без нього Klavko не бачить, що ви набираєте.",
                                       "Required: without it Klavko can’t see what you type."),
                              granted: status.accessibility) {
                    requestAccessibility()
                    PermissionStatus.open("Privacy_Accessibility")
                }
                PermissionRow(symbol: "mic.fill", colors: [.orange, .red],
                              title: tr("Мікрофон і розпізнавання мовлення", "Microphone and Speech Recognition"),
                              text: tr("Для голосового вводу. Можна дозволити й пізніше.", "For voice input. You can allow it later too."),
                              granted: status.voice) {
                    Task {
                        await PermissionStatus.requestVoice()
                        status = PermissionStatus.now()
                    }
                }
                PermissionRow(symbol: "rectangle.dashed.badge.record", colors: [.teal, .green],
                              title: tr("Запис екрана", "Screen Recording"),
                              text: tr("Щоб читати й перекладати текст з екрана. Можна дозволити й пізніше.",
                                       "To read and translate text on the screen. You can allow it later too."),
                              granted: status.screen) {
                    if !CGRequestScreenCaptureAccess() { PermissionStatus.open("Privacy_ScreenCapture") }
                }
            }
            .frame(maxWidth: 540)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .onReceive(timer) { _ in status = PermissionStatus.now() }
    }
}

private struct PermissionStatus {
    var accessibility: Bool
    var voice: Bool
    var screen: Bool

    static func now() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(),
                         voice: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                            && SFSpeechRecognizer.authorizationStatus() == .authorized,
                         screen: CGPreflightScreenCaptureAccess())
    }

    /// Asks macOS once; when the user said no before, the place in System Settings opens instead.
    static func requestVoice() async {
        if SFSpeechRecognizer.authorizationStatus() == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            open(SFSpeechRecognizer.authorizationStatus() == .denied ? "Privacy_SpeechRecognition" : "Privacy_Microphone")
            return
        }
        _ = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let text: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            FeatureIcon(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label(tr("Дозволено", "Allowed"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(tr("Дозволити…", "Allow…"), action: allow)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        .animation(.spring(duration: 0.4), value: granted)
    }
}

private struct SettingsPage: View {
    @ObservedObject var settings: Settings
    let mark: String?
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            PageTitle(title: tr("Усе готово", "You’re All Set"),
                      subtitle: tr("Щоб змінити, що й коли робить Klavko, клацніть його значок у рядку меню й виберіть «Налаштування».",
                                   "To change what Klavko does and when, click its icon in the menu bar and choose “Settings”."))
            MenuBarSketch(mark: mark, menu: true)
            VStack(alignment: .leading, spacing: 10) {
                Toggle(tr("Запускати Klavko під час входу в систему", "Open Klavko when you log in"), isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                Text(tr("Там же: гарячі клавіші, мови голосового вводу, звуки, винятки для програм і заміна клавіш.",
                        "Also there: hotkeys, voice input languages, sounds, app exceptions and key remapping."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("Відкрити налаштування", "Open Settings"), action: openSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 13))
            }
            .padding(16)
            .frame(maxWidth: 480)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
    }
}
