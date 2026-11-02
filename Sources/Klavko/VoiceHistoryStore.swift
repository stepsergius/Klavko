import Foundation
import KlavkoCore

/// The voice input history on disk: ~/Library/Application Support/Klavko/voice-history.json (this Mac only).
@MainActor
final class VoiceHistoryStore: ObservableObject {
    @Published private(set) var history = VoiceHistory()

    private let file = StoredFile<VoiceHistory>("voice-history.json")

    init() {
        if let stored = file.load() { history = stored }
        file.onReadable = { [weak self] stored in
            guard let self else { return }
            self.history = self.history.merged(with: stored)
            self.save()
        }
    }

    func add(_ text: String) {
        history.add(text)
        save()
    }

    func remove(_ id: UUID) {
        history.remove(id)
        save()
    }

    func clear() {
        history.clear()
        save()
    }

    private func save() {
        file.save(history)
    }
}
