import AppKit
import KlavkoCore
import SwiftUI

/// What a QR code from "Text from the screen" holds, next to the mouse: a link opens with Return, text is
/// shown to read and copy; when the code can't be read, a note saying so. Esc closes.
@MainActor
final class QRCodePanel {
    private var panel: NSPanel?

    func show(_ payloads: [String], at point: NSPoint) {
        present(QRCodeView(contents: payloads.map(QRContent.init), onOpen: { [weak self] url in
            self?.close()
            NSWorkspace.shared.open(url)
        }, onCopy: { [weak self] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.close()
        }, onClose: { [weak self] in self?.close() }), at: point)
    }

    func showUnreadable(at point: NSPoint) {
        present(QRCodeView(contents: [], onOpen: { _ in }, onCopy: { _ in }, onClose: { [weak self] in self?.close() }), at: point)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func present(_ view: QRCodeView, at point: NSPoint) {
        close()
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let panel = QRPanel(contentViewController: controller)
        panel.styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView, .closable]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }
        panel.layoutIfNeeded()
        // Below and right of the mouse pointer; above it when there is no room below; always on screen.
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        if let frame = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            if origin.y < frame.minY + 8 { origin.y = point.y + 12 }
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        // Takes Return and Esc without activating Klavko.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Developer check of the look: --snapshot-qr <file.png> [payload]; an empty payload shows the unreadable note.
    static func snapshot(to url: URL, payload: String) {
        let view = QRCodeView(contents: payload.isEmpty ? [] : [QRContent(payload)], onOpen: { _ in }, onCopy: { _ in }, onClose: {})
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
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

private final class QRPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct QRCodeView: View {
    /// Empty: the code couldn't be read.
    let contents: [QRContent]
    let onOpen: (URL) -> Void
    let onCopy: (String) -> Void
    let onClose: () -> Void

    private var link: URL? {
        if case .link(let url) = contents.first { return url }
        return nil
    }

    private var allText: String {
        contents.map { content in
            switch content {
            case .link(let url): url.absoluteString
            case .text(let text): text
            }
        }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(contents.count > 1 ? trFormat("QR-коди: %@", "QR codes: %@", String(contents.count)) : tr("QR-код", "QR code"),
                  systemImage: "qrcode")
                .font(.system(size: 13, weight: .semibold))
            if contents.isEmpty {
                Text(tr("Не вдалося прочитати QR-код. Спробуйте виділити його більшим, чіткішим або повністю.",
                        "Couldn’t read the QR code. Try selecting it larger, sharper or whole."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(tr("Закрити", "Close"), action: onClose).keyboardShortcut(.defaultAction)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                            switch content {
                            case .link(let url):
                                Text(url.absoluteString)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                                    .textSelection(.enabled)
                            case .text(let text):
                                Text(text)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(link != nil ? tr("Enter — відкрити посилання", "Return — open the link")
                                     : tr("Прочитано на цьому Mac", "Read on this Mac"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let link {
                        Button(tr("Копіювати", "Copy")) { onCopy(allText) }
                            .keyboardShortcut("c", modifiers: .command)
                        Button(tr("Відкрити", "Open")) { onOpen(link) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(tr("Копіювати", "Copy")) { onCopy(allText) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: 400)
    }
}
