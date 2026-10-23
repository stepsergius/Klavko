import AVFoundation

/// Plays Klavko's short sounds at its own volume, off the main thread:
/// starting a sound takes 20–130 ms, which must not delay the key being typed.
/// (System alert sounds start instantly, but follow the system alert volume, which may be muted.)
final class SoundPlayer {
    private let queue = DispatchQueue(label: "app.klavko.sound", qos: .userInitiated)
    private var players: [String: AVAudioPlayer] = [:]
    private let volume: Float = 0.4

    func play(_ name: String) {
        queue.async { [self] in
            guard let player = player(for: name) else { return }
            player.stop()
            player.currentTime = 0
            if !player.play() {
                Log.engine.error("Sound \(name, privacy: .public) didn't start")
            }
        }
    }

    /// Loads a sound ahead of time, so the first fix doesn't wait for it.
    func preload(_ name: String) {
        queue.async { [self] in _ = player(for: name) }
    }

    /// Klavko's own sounds, by file name ("bubble-pop"), A–Z.
    static let bundledSounds: [String] = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".mp3") }.map { String($0.dropLast(4)) }.sorted()
    }()

    /// How the picker shows a sound: "bubble-pop" → "Bubble Pop"; system sounds as they are. One of Klavko's
    /// named like a system sound gets a number ("pop" → "Pop 2"), so the list never shows the same name twice.
    static func title(_ name: String) -> String {
        guard bundledSounds.contains(name) else { return name }
        let title = name.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        return Settings.sounds.contains(title) ? title + " 2" : title
    }

    /// Only on `queue`.
    private func player(for name: String) -> AVAudioPlayer? {
        if let player = players[name] { return player }
        let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds")
            ?? URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Log.engine.error("Sound \(name, privacy: .public) couldn't be loaded")
            return nil
        }
        player.volume = volume
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
