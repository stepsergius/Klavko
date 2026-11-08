import Foundation
import FluidAudio
import KlavkoCore

/// Cohere Transcribe speech recognition on this Mac, through sherpa-onnx (`SherpaOnnx`), as in Klavko for Windows.
/// Better than Parakeet at English spoken with an accent, but it knows only 14 languages (no Ukrainian or Russian)
/// and must be told the language, so Klavko uses it only for voice input in one language, by that language's own
/// hotkey. The int8 model (~2.9 GB) is downloaded once from Hugging Face; after that everything runs offline.
@MainActor
final class CohereEngine: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private var recognizer: SherpaOnnx.CohereRecognizer?
    private var loading: Task<SherpaOnnx.CohereRecognizer, Error>?
    /// Frees the memory after a while without dictation.
    private var unloadTimer: Timer?

    /// The export of sherpa-onnx's author, at a fixed revision.
    private static let source = URL(string: "https://huggingface.co/csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01/resolve/156a470cf08eefe706a0004f3c52d9ee567ca7a0/")!
    private static let files: [ModelDownload.File] = [
        .init(name: "tokens.txt", size: 207_437), .init(name: "encoder.int8.onnx", size: 3_090_822),
        .init(name: "decoder.int8.onnx", size: 153_250_705), .init(name: "encoder.int8.onnx.data", size: 2_731_503_072),
    ]

    /// The languages it recognizes ("en", "de", "fr"…).
    static let languages: Set<String> = ["en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Klavko/Models/cohere-transcribe-int8", isDirectory: true)
    }

    /// The Core ML model of Klavko 1.2.0–1.2.1 (~2.2 GB), no longer used: deleted once the new one is in place.
    private static var oldCoreMLDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/cohere-transcribe", isDirectory: true)
    }

    private static var modelsExist: Bool { ModelDownload.isComplete(directory, files) }

    init() {
        state = Self.modelsExist ? .ready : .notDownloaded
        if Self.modelsExist { Self.removeOldModel() }
    }

    var isDownloaded: Bool { state == .ready }

    private static func removeOldModel() {
        let old = oldCoreMLDirectory
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: old) }
    }

    /// Downloads (if needed) and loads the model; cheap if it's already loaded.
    @discardableResult
    func prepare() -> Task<SherpaOnnx.CohereRecognizer, Error> {
        unloadTimer?.invalidate()
        if let recognizer { return Task { recognizer } }
        if let loading { return loading }
        let task = Task { [weak self] () throws -> SherpaOnnx.CohereRecognizer in
            let directory = Self.directory
            if !Self.modelsExist {
                await MainActor.run { self?.state = .downloading(0) }
                try await ModelDownload.run(from: Self.source, to: directory, files: Self.files) { fraction in
                    Task { @MainActor in
                        if self?.state != .ready { self?.state = .downloading(fraction) }
                    }
                }
                Self.removeOldModel()
            }
            // A few seconds on the processor, away from the main thread. The first recognition after loading is
            // slower: it is done now, on two seconds of quiet noise (silence alone doesn't warm it up), while the user is
            // still speaking.
            return try await Task.detached(priority: .userInitiated) {
                let recognizer = try SherpaOnnx.CohereRecognizer(folder: directory)
                let rate = SherpaOnnx.CohereRecognizer.sampleRate
                _ = recognizer.recognize((0..<rate * 2).map { _ in Float.random(in: -0.05...0.05) }[...], language: "en")
                return recognizer
            }.value
        }
        loading = task
        Task { [weak self] in
            do {
                let recognizer = try await task.value
                self?.recognizer = recognizer
                self?.state = .ready
                Log.engine.notice("Cohere model ready")
            } catch {
                self?.state = Self.modelsExist ? .ready : .failed(error.localizedDescription)
                Log.engine.error("Cohere model failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.loading = nil
        }
        return task
    }

    /// Text of a recording in `language` (one of `languages`). Long recordings go in pieces of up to 20 s,
    /// cut in pauses: the model hears about half a minute at most.
    func transcribe(file: URL, language code: String) async throws -> String {
        guard Self.languages.contains(code) else { return "" }
        let recognizer = try await prepare().value
        let samples = try AudioConverter().resampleAudioFile(file)
        let rate = SherpaOnnx.CohereRecognizer.sampleRate
        // Silence or room noise only (the hotkey pressed by mistake, a muted microphone): Cohere would make up
        // a sentence, so nothing is recognized.
        let loudness = AudioChunks.loudest(samples, sampleRate: rate)
        guard loudness >= AudioChunks.speechLevel else {
            Log.engine.notice("Cohere: only silence was recorded (\(loudness, format: .fixed(precision: 4)))")
            return ""
        }
        let text = await Task.detached(priority: .userInitiated) {
            AudioChunks.split(samples, sampleRate: rate)
                .map { recognizer.recognize(samples[$0], language: code).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }.value
        scheduleUnload()
        return TranscriptCleanup.clean(text)
    }

    /// Deletes the downloaded model.
    func remove() {
        guard loading == nil else { return }
        unloadTimer?.invalidate()
        recognizer = nil
        try? FileManager.default.removeItem(at: Self.directory)
        Self.removeOldModel()
        state = .notDownloaded
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loading == nil, self.recognizer != nil else { return }
                self.recognizer = nil
                Log.engine.notice("Cohere model unloaded after 10 min idle")
            }
        }
    }
}
