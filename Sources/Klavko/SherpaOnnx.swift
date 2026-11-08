import CSherpaOnnx
import Darwin
import Foundation

/// sherpa-onnx (Apache 2.0) with ONNX Runtime (MIT), loaded at run time from Contents/Frameworks: the speech
/// recognition library Cohere Transcribe runs on, the same as in Klavko for Windows. It runs the model on the
/// processor, which on a Mac is several times faster than Core ML for this model (its encoder doesn't fit
/// the Neural Engine, and on the GPU macOS prepares it for minutes at every launch).
enum SherpaOnnx {
    private typealias CreateRecognizer = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?) -> OpaquePointer?
    private typealias DestroyRecognizer = @convention(c) (OpaquePointer?) -> Void
    private typealias CreateStream = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias DestroyStream = @convention(c) (OpaquePointer?) -> Void
    private typealias SetOption = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias AcceptWaveform = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Float>?, Int32) -> Void
    private typealias Decode = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    private typealias GetResult = @convention(c) (OpaquePointer?) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
    private typealias DestroyResult = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerResult>?) -> Void

    private struct Functions {
        let createRecognizer: CreateRecognizer
        let destroyRecognizer: DestroyRecognizer
        let createStream: CreateStream
        let destroyStream: DestroyStream
        let setOption: SetOption
        let acceptWaveform: AcceptWaveform
        let decode: Decode
        let getResult: GetResult
        let destroyResult: DestroyResult
    }

    enum Failure: LocalizedError {
        case missingLibrary(String)
        case badModel

        var errorDescription: String? {
            switch self {
            case .missingLibrary(let why): return "sherpa-onnx: \(why)"
            case .badModel: return "sherpa-onnx couldn't load the model"
            }
        }
    }

    /// Where the library is: inside the app, or in Vendor/ of the source folder for a developer build
    /// (scripts/fetch-sherpa-onnx.sh puts it there).
    private static var libraryCandidates: [URL] {
        var folders: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL { folders.append(frameworks) }
        var up = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            guard let folder = up else { break }
            folders.append(folder.appendingPathComponent("Vendor/sherpa-onnx", isDirectory: true))
            up = folder.deletingLastPathComponent()
        }
        return folders.map { $0.appendingPathComponent("libsherpa-onnx-c-api.dylib") }
    }

    private static let loaded: Result<Functions, Failure> = {
        guard let path = libraryCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path else {
            return .failure(.missingLibrary("the library isn't in the app"))
        }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return .failure(.missingLibrary(String(cString: dlerror())))
        }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let createRecognizer = symbol("SherpaOnnxCreateOfflineRecognizer", CreateRecognizer.self),
              let destroyRecognizer = symbol("SherpaOnnxDestroyOfflineRecognizer", DestroyRecognizer.self),
              let createStream = symbol("SherpaOnnxCreateOfflineStream", CreateStream.self),
              let destroyStream = symbol("SherpaOnnxDestroyOfflineStream", DestroyStream.self),
              let setOption = symbol("SherpaOnnxOfflineStreamSetOption", SetOption.self),
              let acceptWaveform = symbol("SherpaOnnxAcceptWaveformOffline", AcceptWaveform.self),
              let decode = symbol("SherpaOnnxDecodeOfflineStream", Decode.self),
              let getResult = symbol("SherpaOnnxGetOfflineStreamResult", GetResult.self),
              let destroyResult = symbol("SherpaOnnxDestroyOfflineRecognizerResult", DestroyResult.self)
        else { return .failure(.missingLibrary("a function is missing")) }
        return .success(Functions(createRecognizer: createRecognizer, destroyRecognizer: destroyRecognizer,
                                  createStream: createStream, destroyStream: destroyStream, setOption: setOption,
                                  acceptWaveform: acceptWaveform, decode: decode, getResult: getResult,
                                  destroyResult: destroyResult))
    }()

    /// A Cohere Transcribe recognizer. Not for use from two threads at once.
    final class CohereRecognizer: @unchecked Sendable {
        static let sampleRate = 16_000
        private let functions: Functions
        private let recognizer: OpaquePointer

        /// Loads the model in `folder` (several seconds, about 3.5 GB of memory).
        init(folder: URL) throws {
            let functions = try SherpaOnnx.loaded.get()
            self.functions = functions
            let path = { (name: String) in strdup(folder.appendingPathComponent(name).path)! }
            let strings = [path("encoder.int8.onnx"), path("decoder.int8.onnx"), path("tokens.txt"),
                           strdup("cpu")!, strdup("greedy_search")!]
            defer { strings.forEach { free($0) } }
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = Int32(Self.sampleRate)
            config.feat_config.feature_dim = 80
            config.model_config.cohere_transcribe.encoder = UnsafePointer(strings[0])
            config.model_config.cohere_transcribe.decoder = UnsafePointer(strings[1])
            config.model_config.cohere_transcribe.use_punct = 1
            config.model_config.cohere_transcribe.use_itn = 1
            config.model_config.tokens = UnsafePointer(strings[2])
            config.model_config.provider = UnsafePointer(strings[3])
            config.model_config.num_threads = Int32(min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 2), 8))
            config.decoding_method = UnsafePointer(strings[4])
            config.max_active_paths = 4
            guard let recognizer = withUnsafePointer(to: &config, { functions.createRecognizer($0) }) else {
                throw Failure.badModel
            }
            self.recognizer = recognizer
        }

        deinit { functions.destroyRecognizer(recognizer) }

        /// The text of 16 kHz mono audio in `language` ("en", "de"…).
        func recognize(_ samples: ArraySlice<Float>, language: String) -> String {
            guard let stream = functions.createStream(recognizer) else { return "" }
            defer { functions.destroyStream(stream) }
            functions.setOption(stream, "language", language)
            samples.withUnsafeBufferPointer {
                functions.acceptWaveform(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
            }
            functions.decode(recognizer, stream)
            guard let result = functions.getResult(stream) else { return "" }
            defer { functions.destroyResult(result) }
            return result.pointee.text.map { String(cString: $0) } ?? ""
        }
    }
}
