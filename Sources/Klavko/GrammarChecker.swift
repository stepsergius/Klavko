import Foundation
import KlavkoCore

/// Spelling and grammar check on this Mac with LanguageTool (open source, LGPL), run as a small local server.
/// LanguageTool needs Java, so both come as one download (~300 MB: LanguageTool and the Eclipse Temurin runtime)
/// into Application Support; after that everything runs offline, on localhost only.
@MainActor
final class GrammarChecker: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    enum CheckError: LocalizedError {
        case notDownloaded
        case serverDidNotStart

        var errorDescription: String? {
            switch self {
            case .notDownloaded: tr("Перевірку правопису ще не завантажено.", "The spelling check isn’t downloaded yet.")
            case .serverDidNotStart: tr("Перевірка правопису не запустилася.", "The spelling check didn’t start.")
            }
        }
    }

    @Published private(set) var state: State

    private var server: Process?
    private var port = 0
    private var starting: Task<Int, Error>?
    private var downloading: Task<Void, Error>?
    /// Frees the server's memory (~500 MB) after a while without checks.
    private var stopTimer: Timer?

    private static let javaURL = URL(string: "https://api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jre/hotspot/normal/eclipse")!
    private static let languageToolURL = URL(string: "https://languagetool.org/download/LanguageTool-stable.zip")!

    static let folder = URL.applicationSupportDirectory.appending(path: "Klavko/LanguageTool", directoryHint: .isDirectory)
    private static let pidFile = folder.appending(path: "server.pid")

    init() {
        state = Self.java() != nil && Self.serverJar() != nil ? .ready : .notDownloaded
        Self.stopLeftoverServer()
    }

    /// The user's dictionary: words never taken for spelling mistakes (lowercased).
    var knownWords: () -> Set<String> = { [] }

    var isDownloaded: Bool { state == .ready }

    /// The issues LanguageTool finds in `text`. `language` is a Klavko language code ("uk", "en"), nil to let it guess.
    func check(_ text: String, language: String?) async throws -> [GrammarIssue] {
        guard isDownloaded else { throw CheckError.notDownloaded }
        let port = try await startServer().value
        defer { scheduleStop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/check")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["text": text, "language": GrammarCheck.languageCode(for: language)]
        if fields["language"] == "auto" { fields["preferredVariants"] = "en-US,de-DE,pt-PT" }
        request.httpBody = Self.formEncoded(fields).data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let issues = GrammarCheck.withoutKnownWords(try GrammarCheck.issues(fromResponse: data, text: text),
                                                    in: text, words: knownWords())
        // LanguageTool knows few Ukrainian comma rules: Klavko's own fill in.
        guard language == "uk" else { return issues }
        return UkrainianCommas.merged(issues, with: UkrainianCommas.issues(in: text))
    }

    // MARK: Download

    func download() {
        guard downloading == nil else { return }
        state = .downloading(0)
        let task = Task { [weak self] in
            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory.appending(path: "Klavko-LanguageTool-\(UUID().uuidString)")
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }
            // Java is ~48 MB, LanguageTool ~252 MB: progress is shared out by size.
            let java = try await Self.fetch(Self.javaURL, to: scratch.appending(path: "jre.tar.gz")) { fraction in
                self?.state = .downloading(fraction * 0.16)
            }
            let languageTool = try await Self.fetch(Self.languageToolURL, to: scratch.appending(path: "lt.zip")) { fraction in
                self?.state = .downloading(0.16 + fraction * 0.84)
            }
            let unpacked = scratch.appending(path: "unpacked")
            try fileManager.createDirectory(at: unpacked.appending(path: "jre"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: unpacked.appending(path: "lt"), withIntermediateDirectories: true)
            try await Self.run("/usr/bin/tar", ["-xzf", java.path, "-C", unpacked.appending(path: "jre").path])
            try await Self.run("/usr/bin/ditto", ["-x", "-k", languageTool.path, unpacked.appending(path: "lt").path])
            try? fileManager.removeItem(at: Self.folder)
            try fileManager.createDirectory(at: Self.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: unpacked, to: Self.folder)
            guard Self.java() != nil, Self.serverJar() != nil else { throw CheckError.notDownloaded }
        }
        downloading = task
        Task { [weak self] in
            do {
                try await task.value
                self?.state = .ready
                Log.engine.notice("LanguageTool downloaded")
            } catch {
                self?.state = .failed(error.localizedDescription)
                Log.engine.error("LanguageTool download failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.downloading = nil
        }
    }

    /// Downloads `url` into `destination`, reporting progress on the main actor.
    private static func fetch(_ url: URL, to destination: URL,
                              progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor in progress(fraction) }
            }
            task.resume()
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: Server

    /// Starts the server (if it isn't running) and waits until it answers; returns its port.
    private func startServer() -> Task<Int, Error> {
        stopTimer?.invalidate()
        if let server, server.isRunning { return Task { [port] in port } }
        if let starting { return starting }
        let task = Task { [weak self] () throws -> Int in
            guard let java = Self.java(), let jar = Self.serverJar() else { throw CheckError.notDownloaded }
            let port = try Self.freePort()
            let process = Process()
            process.executableURL = java
            process.arguments = ["-Xms64m", "-Xmx1g", "-cp", jar.path,
                                 "org.languagetool.server.HTTPServer", "--port", "\(port)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            try? "\(process.processIdentifier)".write(to: Self.pidFile, atomically: true, encoding: .utf8)
            self?.server = process
            let started = Date()
            while Date().timeIntervalSince(started) < 60 {
                guard process.isRunning else { break }
                let probe = URL(string: "http://127.0.0.1:\(port)/v2/languages")!
                if let (_, response) = try? await URLSession.shared.data(from: probe),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    return port
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            process.terminate()
            throw CheckError.serverDidNotStart
        }
        starting = task
        Task { [weak self] in
            do {
                self?.port = try await task.value
                Log.engine.notice("LanguageTool server ready")
            } catch {
                self?.server = nil
                Log.engine.error("LanguageTool server failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.starting = nil
        }
        return task
    }

    /// Starts the server ahead of the first check, so it answers at once.
    func warmUp() {
        guard isDownloaded else { return }
        startServer()
        scheduleStop()
    }

    func stop() {
        stopTimer?.invalidate()
        server?.terminate()
        server = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    private func scheduleStop() {
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.starting == nil, self.server != nil else { return }
                self.stop()
                Log.engine.notice("LanguageTool server stopped after 15 min idle")
            }
        }
    }

    /// A server left running when Klavko last quit abruptly.
    private static func stopLeftoverServer() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text), pid > 0 else { return }
        if let java = java(), let path = executablePath(of: pid), path == java.path { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Helpers

    static func java() -> URL? {
        let jre = folder.appending(path: "jre")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: jre.path) else { return nil }
        return versions.sorted().reversed().lazy
            .map { jre.appending(path: "\($0)/Contents/Home/bin/java") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func serverJar() -> URL? {
        let lt = folder.appending(path: "lt")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: lt.path) else { return nil }
        return versions.sorted().reversed().lazy
            .map { lt.appending(path: "\($0)/languagetool-server.jar") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Bytes on disk, for Settings.
    static func downloadedSize() -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func deleteDownload() {
        stop()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notDownloaded
    }

    /// A port nothing listens on, from the system.
    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        // ASCII only: `.alphanumerics` would leave Cyrillic letters unencoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}
