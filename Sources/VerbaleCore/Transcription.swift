import Foundation
import AVFoundation
import CParakeet

final class NativeContext {
    let pointer: OpaquePointer
    init(library: URL, model: URL) throws {
        var error = [CChar](repeating: 0, count: 2048)
        guard let p = vb_open(library.path, model.path, &error, error.count) else { throw VerbaleError.message(String(cString: error)) }
        pointer = p
    }
    deinit { vb_close(pointer) }
    func json(_ samples: [Float], operation: Int) throws -> Data {
        guard !samples.isEmpty, samples.count <= Int(Int32.max) else { throw VerbaleError.message("Dimensione audio non valida") }
        let text = samples.withUnsafeBufferPointer { p in
            switch operation {
            case 1: return vb_vad(pointer,p.baseAddress,Int32(p.count))
            case 2: return vb_diarize(pointer,p.baseAddress,Int32(p.count))
            case 3: return vb_vad_refinement(pointer,p.baseAddress,Int32(p.count))
            default: return vb_transcribe(pointer,p.baseAddress,Int32(p.count))
            }
        }
        guard let text else { throw VerbaleError.message(String(cString: vb_error(pointer))) }
        defer { vb_free(pointer, text) }
        return Data(String(cString: text).utf8)
    }
}
public actor TranscriptionEngine {
    private var asr: NativeContext?
    private var vad: NativeContext?
    private var diarizer: NativeContext?
    public init() {}
    public static var defaultLibrary: URL {
        if let path = ProcessInfo.processInfo.environment["VERBALE_LIBRARY"] { return URL(fileURLWithPath: path) }
        if let folder = Bundle.main.privateFrameworksURL {
            let library = folder.appendingPathComponent("libparakeet.dylib")
            if FileManager.default.fileExists(atPath: library.path) { return library }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/parakeet/libparakeet.dylib")
    }
    public func load(asr: URL, vad: URL, diarization: URL? = nil, library: URL = defaultLibrary) throws {
        self.asr = nil; self.vad = nil; self.diarizer = nil
        // Build transactionally: a failed VAD/diarizer load must release ASR too.
        let loadedASR = try NativeContext(library: library, model: asr)
        let loadedVAD = try NativeContext(library: library, model: vad)
        let loadedDiarizer = try diarization.map { try NativeContext(library:library,model:$0) }
        self.asr = loadedASR; self.vad = loadedVAD; self.diarizer = loadedDiarizer
    }
    public func unload() { asr = nil; vad = nil; diarizer = nil }
    private struct Range: Decodable { var start: Double; var end: Double; var speaker: Int? }
    private struct Regions: Decodable { var segments: [Range] }
    private struct Result: Decodable { var text: String; var words: [Word] }
    public func transcribe(samples: [Float], source: AudioSource, offset: Double, pass:ASRPass = .live) throws -> [Segment] {
        guard let asr, let vad else { throw VerbaleError.message("Motore non caricato") }
        if samples.count < 1600 { return [] }
        let duration = Double(samples.count) / 16000
        let regions = try JSONDecoder().decode(Regions.self, from: vad.json(samples, operation:pass == .refinement ? 3:1)).segments
        var output: [Segment] = []
        let spans = ASRSegmentation.spans(regions.map { SpeechSpan(start:$0.start,end:$0.end) },duration:duration,pass:pass)
        for region in spans {
            try Task.checkCancellation()
            var start = region.start
            let end = region.end
            while start < end {
                let until = min(end, start + (pass == .refinement ? 30:20))
                let a = min(samples.count, Int(start * 16000)), b = min(samples.count, Int(until * 16000))
                guard b > a else { break }
                guard let result = try JSONDecoder().decode([Result].self, from: asr.json(Array(samples[a..<b]), operation: 0)).first else { throw VerbaleError.message("Risposta ASR vuota") }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let words = result.words.map { word -> Word in var w = word; w.start += offset + start; w.end += offset + start; return w }
                    output.append(Segment(source: source, start: offset + start, end: offset + until, text: text, words: words))
                }
                start = until
            }
        }
        return output
    }
    public func diarize(samples: [Float], segments: [Segment], offset: Double = 0) throws -> DiarizationResult {
        guard let diarizer else { return DiarizationResult(segments: segments, replacements: Dictionary(segments.map { ($0.id, [$0.id]) }, uniquingKeysWith: { first, _ in first })) }
        let ranges = try JSONDecoder().decode(Regions.self, from: diarizer.json(samples, operation: 2)).segments
        return SpeakerDiarization.split(segments, regions: ranges.map { SpeakerRegion(start: $0.start, end: $0.end, speaker: $0.speaker) }, offset: offset)
    }
}

public enum AudioFiles {
    public static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw VerbaleError.message("Il file audio non contiene campioni") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw VerbaleError.message("Formato audio non convertibile") }
        var result: [Float] = []
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)!
        while true {
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            var error: NSError?, readError: Error?
            let status = converter.convert(to: output, error: &error) { requested, status in
                if file.framePosition >= file.length { status.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity, AVAudioFrameCount(file.length - file.framePosition)))
                    status.pointee = .haveData; return input
                } catch { readError = error; status.pointee = .noDataNow; return nil }
            }
            if let readError { throw readError }
            if let error { throw error }
            if let p = output.floatChannelData?[0] { result.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(output.frameLength))) }
            if status == .endOfStream { break }
            if status == .error || output.frameLength == 0 { throw VerbaleError.message("Conversione audio interrotta") }
        }
        return result
    }
    public static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in if let base = p.baseAddress { buffer.floatChannelData![0].update(from: base, count: p.count) } }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
    }
}
