import Foundation

/// One thing that was copied.
public struct ClipItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, link, image, files

        public var title: String {
            switch self {
            case .text: tr("Текст", "Text")
            case .link: tr("Посилання", "Links")
            case .image: tr("Зображення", "Images")
            case .files: tr("Файли", "Files")
            }
        }

        public var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .files: "doc"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// The text (or link) itself; for files, their paths one per line.
    public var text: String
    /// Image file name in the history folder.
    public var imageName: String?
    /// Identifies equal content: the text, the image's hash, the file paths.
    public var fingerprint: String
    public var date: Date
    public var appName: String?
    public var appBundleID: String?
    public var pinned: Bool

    public init(kind: Kind, text: String, imageName: String? = nil, fingerprint: String? = nil, date: Date = Date(),
                appName: String? = nil, appBundleID: String? = nil, pinned: Bool = false) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.imageName = imageName
        self.fingerprint = fingerprint ?? kind.rawValue + ":" + text
        self.date = date
        self.appName = appName
        self.appBundleID = appBundleID
        self.pinned = pinned
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "svg", "avif", "ico",
    ]

    /// One copied picture file (from Finder, a screenshot app): shown and filtered as a picture.
    public var isImageFile: Bool {
        kind == .files && !text.contains("\n")
            && Self.imageExtensions.contains((text as NSString).pathExtension.lowercased())
    }

    /// What the item is for the filter: a picture file counts as a picture.
    public var shownKind: Kind { isImageFile ? .image : kind }

    /// One line for the list.
    public var title: String {
        switch kind {
        case .image: return tr("Зображення", "Image")
        case .files:
            let names = text.split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : trFormat("%@ і ще %@", "%@ and %@ more", names.first ?? "", String(names.count - 1))
        case .text, .link:
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? tr("(пробіли)", "(spaces)") : line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Text copied from somewhere is a link when it is just one web or mail address.
    public static func kind(ofText text: String) -> Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else { return .text }
        switch scheme {
        case "http", "https": return url.host?.contains(".") == true ? .link : .text
        case "mailto": return .link
        default: return .text
        }
    }
}

/// The history itself: newest first, pinned items kept forever, equal content never twice.
public struct ClipboardHistory: Codable, Sendable {
    public private(set) var items: [ClipItem] = []

    public init(items: [ClipItem] = []) {
        self.items = items
    }

    /// Puts `item` on top. Copying something already there moves it up (keeping its pin).
    /// Returns items that dropped out (so their image files can be deleted).
    @discardableResult
    public mutating func add(_ item: ClipItem, maxItems: Int, maxAge: TimeInterval?) -> [ClipItem] {
        var item = item
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            let existing = items.remove(at: index)
            item.pinned = existing.pinned
            item.id = existing.id
            item.imageName = item.imageName ?? existing.imageName
        }
        items.insert(item, at: 0)
        return prune(maxItems: maxItems, maxAge: maxAge, now: item.date)
    }

    /// Drops unpinned items over the limit or older than `maxAge`; returns them.
    @discardableResult
    public mutating func prune(maxItems: Int, maxAge: TimeInterval?, now: Date = Date()) -> [ClipItem] {
        var kept: [ClipItem] = []
        var dropped: [ClipItem] = []
        var unpinned = 0
        for item in items {
            if item.pinned {
                kept.append(item)
                continue
            }
            let tooOld = maxAge.map { now.timeIntervalSince(item.date) > $0 } ?? false
            if tooOld || unpinned >= maxItems {
                dropped.append(item)
            } else {
                unpinned += 1
                kept.append(item)
            }
        }
        items = kept
        return dropped
    }

    /// Moves an item to the top, as pasting it from the history does.
    public mutating func touch(_ id: UUID, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = now
        items.insert(item, at: 0)
    }

    public mutating func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ClipItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Removes everything but pinned items; returns what was removed.
    @discardableResult
    public mutating func clearUnpinned() -> [ClipItem] {
        let dropped = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        return dropped
    }

    /// Both histories in one, newest first: what was kept on disk and what was copied before it could be read.
    /// The same content is kept once, pinned if either copy was.
    public func merged(with other: ClipboardHistory) -> ClipboardHistory {
        var byFingerprint: [String: ClipItem] = [:]
        for item in items + other.items {
            guard var existing = byFingerprint[item.fingerprint] else {
                byFingerprint[item.fingerprint] = item
                continue
            }
            existing.pinned = existing.pinned || item.pinned
            if item.date > existing.date { existing.date = item.date }
            byFingerprint[item.fingerprint] = existing
        }
        return ClipboardHistory(items: byFingerprint.values.sorted { $0.date > $1.date })
    }

    /// Pinned first, then newest; matching every word of `query` (any case) and the kind, if given.
    public func search(_ query: String, kind: ClipItem.Kind? = nil) -> [ClipItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let matching = items.filter { item in
            if let kind, item.shownKind != kind { return false }
            guard !words.isEmpty else { return true }
            let haystack = (item.text + " " + (item.appName ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return matching.filter(\.pinned) + matching.filter { !$0.pinned }
    }
}
