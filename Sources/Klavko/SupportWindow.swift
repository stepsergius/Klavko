import AppKit
import KlavkoCore
import SwiftUI

/// After an update: thanks, and a way to support Klavko (the Monobank jar). Shown once per new version.
@MainActor
final class SupportWindow {
    private var window: NSWindow?

    func show(version: String) {
        window?.close()
        let view = SupportView(version: version, onDone: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = tr("Підтримати Klavko", "Support Klavko")
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Developer check of the window's look: renders it into `url` and quits.
    static func snapshot(to url: URL, version: String) {
        let hosting = NSHostingView(rootView: SupportView(version: version, onDone: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}

private struct SupportView: View {
    let version: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.primary)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(trFormat("Klavko оновлено до версії %@", "Klavko has been updated to %@", version))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(tr("Допоможіть Klavko розвиватися", "Help Klavko grow"))
                        .font(.system(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(tr("Klavko залишається безкоштовним і працює лише на вашому Mac, без реклами й стеження. "
                    + "Якщо він вам допомагає, підтримати розробку можна через банку Monobank.",
                    "Klavko stays free and runs only on your Mac, with no ads or tracking. "
                    + "If it helps you, you can support its development through a Monobank jar."))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let donate = AboutInfo.donateURL {
                Button {
                    NSWorkspace.shared.open(donate)
                } label: {
                    Label(tr("Підтримати через Monobank", "Support via Monobank"), systemImage: "heart.fill")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
            Link(destination: AboutInfo.repository) {
                Label(tr("Зірка на GitHub теж допомагає людям дізнатися про Klavko.",
                         "A star on GitHub also helps people find Klavko."), systemImage: "star")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(tr("Дякуємо, що ви з нами.", "Thank you for being here.") + " 🖤")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack {
                Link(tr("Що нового", "What’s new"), destination: Updater.releasesPage)
                    .font(.callout)
                Spacer()
                Button(tr("Готово", "Done"), action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 520)
    }
}
