import AppKit
import KlavkoCore
import SwiftUI
import UniformTypeIdentifiers

/// The clipboard history window: search on top, the list on the left, a preview on the
/// right. ↩ pastes into the app you were in, ⌘C only copies, ⌘P pins, ⌘⌫ deletes, Esc closes.
/// It never activates Klavko, so the app you came from stays in front and gets the paste.
@MainActor
final class ClipboardWindow: ObservableObject {
    @Published var query = "" { didSet { selectFirst() } }
    @Published var kind: ClipItem.Kind? { didSet { selectFirst() } }
    @Published var selectedID: UUID?

    let manager: ClipboardManager
    private var panel: ClipboardPanel?

    init(manager: ClipboardManager) {
        self.manager = manager
    }

    var results: [ClipItem] { manager.history.search(query, kind: kind) }
    var selected: ClipItem? { results.first { $0.id == selectedID } ?? results.first }
    var isVisible: Bool { panel != nil }

    func toggle() {
        if panel != nil { close() } else { show() }
    }

    func show() {
        query = ""
        kind = nil
        selectFirst()
        let hosting = NSHostingView(rootView: ClipboardView(window: self, manager: manager))
        let size = NSSize(width: 780, height: 480)
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = ClipboardPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.onResignKey = { [weak self] in self?.close() }
        // Centred, a little above the middle of the screen with the mouse.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(),
                                         y: (frame.midY - size.height / 2 + frame.height * 0.08).rounded()))
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Developer check of the window's look with the current history.
    func snapshot(to url: URL) {
        selectFirst()
        let view = NSHostingView(rootView: ClipboardView(window: self, manager: manager)
            .frame(width: 780, height: 480).background(Color(white: 0.8)))
        view.frame = NSRect(x: 0, y: 0, width: 780, height: 480)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        panel.orderOut(nil)
    }

    // MARK: - Actions

    func paste(_ item: ClipItem? = nil) {
        guard let item = item ?? selected else { return }
        close()
        // The app you came from gets its keyboard back once the window is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [manager] in manager.paste(item) }
    }

    func copy() {
        guard let item = selected else { return }
        manager.copy(item)
        close()
    }

    func togglePin() {
        guard let item = selected else { return }
        manager.togglePin(item)
    }

    func delete() {
        guard let item = selected else { return }
        let list = results
        let index = list.firstIndex(of: item) ?? 0
        manager.remove(item)
        let rest = results
        selectedID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
    }

    private func move(_ step: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = list[max(0, min(list.count - 1, index + step))].id
    }

    private func selectFirst() {
        selectedID = results.first?.id
    }

    /// Keys for the list, while typing in the search field goes on as usual.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (125, []): move(1)                      // ↓
        case (126, []): move(-1)                     // ↑
        case (36, []), (76, []): paste()             // ↩
        case (53, []): close()                       // Esc
        case (8, .command): copy()                   // ⌘C
        case (35, .command): togglePin()             // ⌘P
        case (51, .command): delete()                // ⌘⌫
        default:
            // ⌘1…⌘9: paste that item straight away.
            if flags == .command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
                let list = results
                if digit <= list.count { paste(list[digit - 1]) }
                return true
            }
            return false
        }
        return true
    }
}

private final class ClipboardPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    // Clicking elsewhere closes it.
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Views

private struct ClipboardView: View {
    @ObservedObject var window: ClipboardWindow
    @ObservedObject var manager: ClipboardManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 16))
            TextField("", text: $window.query, prompt: Text(tr("Шукати в історії буфера обміну…", "Search clipboard history…")))
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            Picker("", selection: $window.kind) {
                Text(tr("Усе", "All")).tag(ClipItem.Kind?.none)
                Divider()
                ForEach(ClipItem.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(ClipItem.Kind?.some(kind))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var list: some View {
        let items = window.results
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if items.isEmpty {
                        Text(manager.history.items.isEmpty ? tr("Тут з’явиться все, що ви копіюєте.", "Everything you copy will appear here.")
                             : tr("Нічого не знайдено", "Nothing found"))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipRow(item: item, number: index < 9 ? index + 1 : nil,
                                isSelected: item.id == window.selected?.id, manager: manager)
                            .id(item.id)
                            .onTapGesture(count: 2) { window.paste(item) }
                            .onTapGesture { window.selectedID = item.id }
                    }
                }
                .padding(6)
            }
            .onChange(of: window.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let item = window.selected {
            VStack(alignment: .leading, spacing: 0) {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                info(item).padding(12)
            }
        } else {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .link:
            ScrollView {
                LinkPreview(address: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) { window.close() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        case .text:
            // A link in the text opens in the browser, and the history closes, as for a copied link.
            LinkedTextView(text: item.text) { url in
                window.close()
                NSWorkspace.shared.open(url)
            }
        case .image:
            if let url = manager.imageURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .files where ClipRow.imagePath(of: item) != nil:
            // A copied picture file (Finder): show the picture itself.
            let path = ClipRow.imagePath(of: item) ?? ""
            VStack(spacing: 8) {
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 64, height: 64)
                }
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.text.split(separator: "\n").map(String.init), id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(.system(size: 13))
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func info(_ item: ClipItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if let app = item.appName {
                GridRow {
                    Text(tr("Звідки", "From")).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        if let icon = ClipRow.appIcon(item.appBundleID) {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                        }
                        Text(app)
                    }
                }
            }
            GridRow {
                Text(tr("Скопійовано", "Copied")).foregroundStyle(.secondary)
                Text(item.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                    .locale(AppLanguage.current.locale)))
            }
            GridRow {
                Text(detailTitle(item)).foregroundStyle(.secondary)
                Text(detail(item))
            }
        }
        .font(.system(size: 12))
    }

    private func detailTitle(_ item: ClipItem) -> String {
        switch item.kind {
        case .text, .link: tr("Символів", "Characters")
        case .image: tr("Розмір", "Size")
        case .files: tr("Файлів", "Files")
        }
    }

    private func detail(_ item: ClipItem) -> String {
        switch item.kind {
        case .text, .link: "\(item.text.count)"
        case .image: item.text
        case .files: "\(item.text.split(separator: "\n").count)"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(tr("Історія буфера обміну", "Clipboard History"), systemImage: "doc.on.clipboard")
                .foregroundStyle(.secondary)
            Spacer()
            hint("↩", tr("Вставити", "Paste"))
            hint("⌘C", tr("Копіювати", "Copy"))
            hint("⌘P", window.selected?.pinned == true ? tr("Відкріпити", "Unpin") : tr("Закріпити", "Pin"))
            hint("⌘⌫", tr("Видалити", "Delete"))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
        }
    }
}

/// Copied text in a native, selectable text view: every web or mail address in it is a real link —
/// a pointing hand over it, a click opens it (SwiftUI's selectable Text doesn't show the hand and often
/// takes the click for the start of a selection).
private struct LinkedTextView: NSViewRepresentable {
    let text: String
    let onOpen: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 9, height: 14)
        view.delegate = context.coordinator
        view.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onOpen = onOpen
        guard let view = scroll.documentView as? NSTextView, context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.textStorage?.setAttributedString(Self.withLinks(text))
        view.scroll(.zero)
    }

    /// The text with every web or mail address in it as a link.
    static func withLinks(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        for found in TextLinks.find(in: text) {
            result.addAttribute(.link, value: found.url, range: NSRange(found.range, in: text))
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpen: (URL) -> Void
        var shown: String?

        init(onOpen: @escaping (URL) -> Void) { self.onOpen = onOpen }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            onOpen(url)
            return true
        }
    }
}

/// The copied address as a link: underlined with a hand cursor on hover; a click opens it in the browser.
private struct LinkPreview: View {
    let address: String
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(address)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .underline(hovering)
                .multilineTextAlignment(.leading)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onTapGesture { open() }
                .help(tr("Відкрити в браузері", "Open in browser"))
            if let host = URL(string: address)?.host {
                Label(host, systemImage: "globe").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
    }

    private func open() {
        guard let url = URL(string: address) else { return }
        onOpen()
        NSWorkspace.shared.open(url)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let number: Int?
    let isSelected: Bool
    let manager: ClipboardManager

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 22, height: 22)
            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if let number {
                Text("⌘\(number)").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if item.kind == .image, let url = manager.imageURL(for: item), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let path = Self.imagePath(of: item), let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
        } else if item.kind == .files, let path = item.text.split(separator: "\n").first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: String(path))).resizable()
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.kind == .link ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
    }

    /// The file of a single copied picture (from Finder), if that's what the item is.
    static func imagePath(of item: ClipItem) -> String? {
        guard item.kind == .files, !item.text.contains("\n"),
              let type = UTType(filenameExtension: (item.text as NSString).pathExtension),
              type.conforms(to: .image) else { return nil }
        return item.text
    }

    static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
