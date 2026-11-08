import Foundation

/// Downloads a model's files of known sizes into a folder. An interrupted download goes on from where it stopped
/// (each file is written as name.part first), so a 3 GB model survives a dropped connection.
enum ModelDownload {
    struct File: Sendable {
        let name: String
        let size: Int64
    }

    static func isComplete(_ folder: URL, _ files: [File]) -> Bool {
        files.allSatisfy { size(of: folder.appendingPathComponent($0.name)) == $0.size }
    }

    /// Downloads the missing files from `source` (a URL ending in "/"); `progress` gets 0…1.
    static func run(from source: URL, to folder: URL, files: [File],
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = files.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        for file in files {
            let target = folder.appendingPathComponent(file.name)
            if size(of: target) == file.size { done += file.size; continue }
            try? FileManager.default.removeItem(at: target)
            let part = folder.appendingPathComponent(file.name + ".part")
            let before = done
            var attempts = 0
            while true {
                do {
                    try await fetch(source.appendingPathComponent(file.name), into: part, size: file.size) { got in
                        progress(Double(before + got) / Double(total))
                    }
                    break
                } catch let error as URLError where attempts < 5 && error.code != .cancelled {
                    // A dropped connection: wait a little and go on from where it stopped.
                    attempts += 1
                    try await Task.sleep(for: .seconds(3))
                }
            }
            guard size(of: part) == file.size else { throw URLError(.cannotDecodeContentData) }
            try FileManager.default.moveItem(at: part, to: target)
            done += file.size
        }
        progress(1)
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Appends the rest of `url` to `part`.
    private static func fetch(_ url: URL, into part: URL, size: Int64,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        var have = Self.size(of: part) ?? 0
        if have > size { try Data().write(to: part); have = 0 }
        if have == size { return }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        if http.statusCode == 206 {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
            have = 0
        }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                have += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.25 { progress(have); lastReport = Date() }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(have + Int64(buffer.count))
    }
}
