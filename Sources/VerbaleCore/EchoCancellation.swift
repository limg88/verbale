import Foundation
import CEcho

public enum ListeningMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case headphones, speakers
    public var id: String { rawValue }
    public var label: String { self == .speakers ? "Altoparlanti · riduci eco" : "Cuffie / acquisizione diretta" }
    public static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "listeningMode") ?? "") ?? .headphones
    }
}

public extension Meeting {
    var usesEchoCancellation: Bool { listeningMode == .speakers && sources.contains(.microphone) && sources.contains(.system) }
}

/// Exact timestamp placement; holes remain marked unknown rather than treated as silence.
public struct AudioReference: Sendable {
    public var samples: [Float]
    public var covered: [UInt8]
    public init(count: Int) {
        samples = [Float](repeating: 0, count: count)
        covered = [UInt8](repeating: 0, count: count)
    }
    public mutating func place(_ values: [Float], start: Double, windowStart: Double) {
        let offset = Int(((start - windowStart) * 16000).rounded())
        let begin = max(0, offset), end = min(samples.count, offset + values.count)
        guard begin < end else { return }
        for i in begin..<end { samples[i] = values[i - offset]; covered[i] = 1 }
    }
}

public struct EchoResult: Sendable {
    public let samples: [Float]
    public let covered: [UInt8]
}

public actor EchoCancellation {
    private var library: OpaquePointer?
    private let path: URL
    public static var defaultLibrary: URL {
        if let path = ProcessInfo.processInfo.environment["VERBALE_AEC_LIBRARY"] { return URL(fileURLWithPath: path) }
        if Bundle.main.bundleURL.pathExtension == "app", let folder = Bundle.main.privateFrameworksURL { return folder.appendingPathComponent(NativeLibrary.filename("verbale_aec")) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/echo/webrtc").appendingPathComponent(NativeLibrary.filename("verbale_aec"))
    }
    public init(library: URL = defaultLibrary) { self.path = library }
    deinit { if let library { ve_close(library) } }
    public func unload() { if let library { ve_close(library) }; library = nil }
    public func prepare() throws {
        guard library == nil else { return }
        var message = [CChar](repeating: 0, count: 2048)
        guard let loaded = ve_open(path.path, &message, message.count) else {
            throw VerbaleError.message("Cancellazione eco non disponibile: \(String(cString: message))")
        }
        library = loaded
    }
    public func clean(microphone: [Float], reference: AudioReference) throws -> [Float] {
        guard !microphone.isEmpty, microphone.count <= 60 * 16000,
              microphone.count == reference.samples.count, microphone.count == reference.covered.count else {
            throw VerbaleError.message("Finestra AEC non valida")
        }
        try prepare()
        var output = [Float](repeating: 0, count: microphone.count)
        let status = microphone.withUnsafeBufferPointer { mic in reference.samples.withUnsafeBufferPointer { ref in
            reference.covered.withUnsafeBufferPointer { mask in output.withUnsafeMutableBufferPointer { out in
                ve_process(library, mic.baseAddress, ref.baseAddress, mask.baseAddress, out.baseAddress, Int32(microphone.count))
            } }
        } }
        guard status == 0 else { throw VerbaleError.message("Cancellazione eco interrotta (\(status)). Gli originali restano recuperabili.") }
        return output
    }
    public func cleanWindow(microphone: [Float], start: Double, chunks: [AudioChunk], workspace: URL, exported: URL) throws -> EchoResult {
        var reference = AudioReference(count: microphone.count)
        let end = start + Double(microphone.count) / 16000
        for chunk in chunks.filter({ $0.source == .system && $0.start < end && $0.start + $0.duration > start }).sorted(by: { $0.start < $1.start }) {
            var url = workspace.appendingPathComponent(chunk.filename)
            if !FileManager.default.fileExists(atPath: url.path) { url = exported.appendingPathComponent(chunk.filename) }
            // Recorded reference files must be readable: corrupted files must not silently become silence.
            let values = try AudioFiles.samples(url)
            guard values.count == chunk.sampleCount else { throw VerbaleError.message("Riferimento AEC incompleto: \(chunk.filename)") }
            reference.place(values, start: chunk.start, windowStart: start)
        }
        return EchoResult(samples: try clean(microphone: microphone, reference: reference), covered: reference.covered)
    }
}
