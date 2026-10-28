import AppKit
import KlavkoCore

/// Emoji in the Quick Actions bar: typed by name after a space and a colon (" :сміх", in the language of the layout
/// typed in), offered after a word that names one ("серце" → ❤️, when that's on), and listed by the bar's Emoji
/// action. The ones used lately come first.
@MainActor
final class EmojiInput {
    var settings: () -> Settings? = { nil }
    weak var bar: QuickActionsBar?

    /// What the list near the caret is for: the name typed after " :" (the colon and it give way to the emoji),
    /// or the word just typed (the emoji goes after it).
    private enum Showing { case name(String), word }
    private var showing: Showing?
    private var catalogs: [String: EmojiCatalog] = [:]

    /// The newest emoji this Mac can show.
    private static let maxVersion: Double = {
        if #available(macOS 15.4, *) { return 16.0 }
        if #available(macOS 14.4, *) { return 15.1 }
        return 15.0
    }()

    /// The emoji named in `language` (English when Klavko has no names in it).
    func catalog(_ language: String) -> EmojiCatalog? {
        if let catalog = catalogs[language] { return catalog }
        guard let catalog = EmojiCatalog.load(language: language, maxVersion: Self.maxVersion)
                ?? (language == "en" ? nil : self.catalog("en")) else { return nil }
        catalogs[language] = catalog
        return catalog
    }

    /// The catalog of the layout typed in now.
    func currentCatalog() -> EmojiCatalog? {
        catalog(SystemLayouts.currentLanguage() ?? "en")
    }

    var recent: [String] { settings()?.recentEmoji ?? [] }

    func used(_ emoji: String) {
        settings()?.recentEmoji = EmojiCatalog.recorded(emoji, in: recent)
    }

    /// What the typing engine calls.
    func hooks() -> SwitchEngine.EmojiHooks {
        var hooks = SwitchEngine.EmojiHooks()
        hooks.byColon = { [weak self] in self?.settings()?.emojiByColon ?? false }
        hooks.suggestions = { [weak self] in self?.settings()?.emojiSuggestions ?? false }
        hooks.isShowing = { [weak self] in self?.bar?.isShowingEmojiList ?? false }
        hooks.search = { [weak self] query, language in self?.search(query, language: language) }
        hooks.word = { [weak self] word, language in self?.offer(for: word, language: language) }
        hooks.move = { [weak self] step in self?.bar?.moveInEmojiList(by: step) }
        hooks.chosen = { [weak self] in
            guard let self, let emoji = bar?.highlightedEmoji else { return nil }
            used(emoji)
            return emoji
        }
        hooks.end = { [weak self] in self?.end() }
        return hooks
    }

    private func search(_ query: String, language: String) {
        showing = .name(query)
        // Just the colon: the latest used, then all the rest.
        if query.isEmpty, let listed = catalog(language)?.listed(recent: recent) {
            bar?.showEmojiList(listed.recent + listed.rest, recentCount: listed.recent.count, highlighted: false)
            return
        }
        let found = catalog(language)?.search(query, recent: recent) ?? []
        if found.isEmpty {
            bar?.hideEmojiList()
        } else {
            bar?.showEmojiList(found)
        }
    }

    private func offer(for word: String?, language: String) {
        guard let word, let found = catalog(language)?.matches(word: word), !found.isEmpty else {
            if case .word = showing { end() }
            return
        }
        showing = .word
        // Nothing picked until ↑ (or Tab, the first).
        bar?.showEmojiList(found, highlighted: false, fitted: true)
    }

    private func end() {
        // A click on the list ends the typing (as any click does) on its way to the button: it picks from it.
        if bar?.emojiListContainsMouse == true { return }
        showing = nil
        bar?.hideEmojiList()
    }

    /// An emoji in the list near the caret clicked.
    func clicked(_ emoji: String) {
        used(emoji)
        switch showing {
        case .name(let query): TextInjector.replace(deleting: 1 + query.count, with: emoji)
        case .word: TextInjector.type(" " + emoji)
        case nil: TextInjector.type(emoji)
        }
        showing = nil
        bar?.hideEmojiList()
    }
}
