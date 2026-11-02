import Foundation

/// A JSON file in ~/Library/Application Support/Klavko that outlives restarts. It is written readable from the
/// first login on: «complete» protection locks a file whenever the Mac is locked, and Klavko starts before that
/// lifts, so it used to find its history unreadable, start empty and save over it. A file that exists but cannot
/// be read is never overwritten: saving waits, and the file is tried again until `onReadable` hands it over to
/// be merged with what is new. A damaged file is set aside, not lost.
@MainActor
final class StoredFile<Value: Codable> {
    let url: URL
    /// The file, now readable, after Klavko started without it.
    var onReadable: (Value) -> Void = { _ in }

    private var locked = false
    private var retry: Timer?

    init(_ path: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = support.appendingPathComponent("Klavko/" + path)
    }

    /// What is stored; nil when there is nothing yet, or the file cannot be read yet.
    func load() -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if !locked { Log.engine.error("\(self.url.lastPathComponent, privacy: .public) not readable yet: \(error.localizedDescription, privacy: .public)") }
            waitUntilReadable()
            return nil
        }
        locked = false
        do {
            let value = try JSONDecoder().decode(Value.self, from: data)
            // Older files were locked with the Mac.
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: url.path)
            return value
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            Log.engine.error("\(self.url.lastPathComponent, privacy: .public) damaged, set aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save(_ value: Value) {
        guard !locked else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Log.engine.error("\(self.url.lastPathComponent, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func waitUntilReadable() {
        locked = true
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = self.load()
                guard !self.locked else { return }
                self.retry?.invalidate()
                self.retry = nil
                if let value { self.onReadable(value) }
            }
        }
    }
}
