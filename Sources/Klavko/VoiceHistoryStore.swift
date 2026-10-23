import Foundation
import KlavkoCore

/// The voice input history on disk: ~/Library/Application Support/Klavko/voice-history.json (this Mac only).
@MainActor
final class VoiceHistoryStore: ObservableObject {
    @Published private(set) var history = VoiceHistory()

    private let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Klavko/voice-history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(VoiceHistory.self, from: data) {
            history = stored
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
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            Log.engine.error("Voice history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
