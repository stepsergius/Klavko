import Foundation

/// A keyboard layout of its own in each app: the one last used there, remembered by itself, or one the user
/// pinned ("Terminal always in ABC"), which wins. Apps by bundle ID, layouts by input source ID.
public struct AppLayouts: Codable, Equatable, Sendable {
    /// Remembered at most for this many apps; the ones not used for longest are forgotten first.
    public static let limit = 300

    public var pinned: [String: String] = [:]
    /// The last layout in each app, the app used latest last.
    public private(set) var remembered: [Remembered] = []

    public struct Remembered: Codable, Equatable, Sendable {
        public let app: String
        public let layout: String
    }

    public init(pinned: [String: String] = [:], remembered: [Remembered] = []) {
        self.pinned = pinned
        self.remembered = remembered
    }

    /// The layout to switch to in `app`: pinned, else the last one used there; nil for an app not seen yet.
    public func layout(for app: String) -> String? {
        pinned[app] ?? remembered.last { $0.app == app }?.layout
    }

    /// `layout` is on in `app` now.
    public mutating func remember(_ layout: String, in app: String) {
        if remembered.last?.app == app && remembered.last?.layout == layout { return }
        remembered.removeAll { $0.app == app }
        remembered.append(Remembered(app: app, layout: layout))
        if remembered.count > Self.limit { remembered.removeFirst(remembered.count - Self.limit) }
    }

    /// Layouts no longer in macOS are forgotten (a pinned one too: the app is free again).
    public mutating func keepOnly(layouts: Set<String>) {
        pinned = pinned.filter { layouts.contains($0.value) }
        remembered.removeAll { !layouts.contains($0.layout) }
    }
}
