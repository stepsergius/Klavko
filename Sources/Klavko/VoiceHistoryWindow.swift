import AppKit
import KlavkoCore
import SwiftUI

/// The voice input history in a window of its own: each dictated text with its date and time, newest first,
/// with round buttons to copy or delete it, and "Clear History".
@MainActor
final class VoiceHistoryWindow {
    private var window: NSWindow?

    func show(_ store: VoiceHistoryStore) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: VoiceHistoryView(store: store)))
            window.title = tr("Історія голосового вводу", "Voice Input History")
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct VoiceHistoryView: View {
    @ObservedObject var store: VoiceHistoryStore
    @State private var copied: UUID?
    @State private var confirmingClear = false
    @State private var query = ""

    private var shown: [VoiceHistory.Entry] { store.history.search(query) }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("Пошук в історії", "Search the history"), text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help(tr("Очистити пошук", "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            if store.history.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(tr("Тут з’являтиметься те, що ви надиктуєте.", "What you dictate will appear here."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(tr("Нічого не знайдено", "Nothing found"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(shown) { entry in
                        row(entry)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                Text(query.isEmpty
                     ? trFormat("Записів: %@", "Entries: %@", String(store.history.entries.count))
                     : trFormat("Знайдено %1$@ з %2$@", "Found %1$@ of %2$@", String(shown.count), String(store.history.entries.count)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("Очистити історію", "Clear History"), role: .destructive) { confirmingClear = true }
                    .disabled(store.history.entries.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 300)
        .confirmationDialog(tr("Очистити всю історію голосового вводу?", "Clear the whole voice input history?"),
                            isPresented: $confirmingClear) {
            Button(tr("Очистити", "Clear"), role: .destructive) { store.clear() }
        }
    }

    private func row(_ entry: VoiceHistory.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormat.string(from: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            roundButton(copied == entry.id ? "checkmark" : "doc.on.doc", help: tr("Копіювати", "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = entry.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == entry.id { copied = nil } }
            }
            roundButton("trash", help: tr("Видалити", "Delete")) { store.remove(entry.id) }
        }
        .padding(.vertical, 4)
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
