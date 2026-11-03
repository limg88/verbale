import Foundation
import AVFoundation
import CParakeet

private final class NativeContext {
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
            operation == 1 ? vb_vad(pointer, p.baseAddress, Int32(p.count)) : operation == 2 ? vb_diarize(pointer, p.baseAddress, Int32(p.count)) : vb_transcribe(pointer, p.baseAddress, Int32(p.count))
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
        if let folder = Bundle.main.privateFrameworksURL { return folder.appendingPathComponent("libparakeet.dylib") }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/parakeet/libparakeet.dylib")
    }
    public func load(asr: URL, vad: URL, diarization: URL? = nil, library: URL = defaultLibrary) throws {
        self.asr = nil; self.vad = nil; self.diarizer = nil
        self.asr = try NativeContext(library: library, model: asr)
        self.vad = try NativeContext(library: library, model: vad)
        if let diarization { diarizer = try NativeContext(library: library, model: diarization) }
    }
    public func unload() { asr = nil; vad = nil; diarizer = nil }
    private struct Range: Decodable { var start: Double; var end: Double; var speaker: Int? }
    private struct Regions: Decodable { var segments: [Range] }
    private struct Result: Decodable { var text: String; var words: [Word] }
    public func transcribe(samples: [Float], source: AudioSource, offset: Double) throws -> [Segment] {
        guard let asr, let vad else { throw VerbaleError.message("Motore non caricato") }
        if samples.count < 1600 { return [] }
        let duration = Double(samples.count) / 16000
        let regions = try JSONDecoder().decode(Regions.self, from: vad.json(samples, operation: 1)).segments
        var output: [Segment] = []
        for region in regions {
            var start = max(0, region.start - 0.15)
            let end = min(duration, region.end + 0.15)
            while start < end {
                let until = min(end, start + 20)
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
    public func diarize(samples: [Float], segments: [Segment], offset: Double = 0) throws -> [Segment] {
        guard let diarizer else { return segments }
        let ranges = try JSONDecoder().decode(Regions.self, from: diarizer.json(samples, operation: 2)).segments
        return segments.flatMap { segment -> [Segment] in
            guard segment.source == .system else { return [segment] }
            // Split at word boundaries; speaker identities are scoped to this diarization call.
            var groups: [Segment] = []
            for word in segment.words {
                let match = ranges.max { a, b in
                    overlap(word.start - offset, word.end - offset, a.start, a.end) < overlap(word.start - offset, word.end - offset, b.start, b.end)
                }
                let speaker = match.flatMap { overlap(word.start - offset, word.end - offset, $0.start, $0.end) > 0 ? $0.speaker : nil }
                let key = speaker.map { "Interlocutore \($0 + 1)" }
                if let last = groups.last, last.speakerID == key {
                    groups[groups.count - 1].text += " " + word.w; groups[groups.count - 1].end = word.end; groups[groups.count - 1].words.append(word)
                } else { groups.append(Segment(source: .system, start: word.start, end: word.end, text: word.w, speakerID: key, words: [word])) }
            }
            return groups.isEmpty ? [segment] : groups
        }
    }
}
private func overlap(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { max(0, min(b, d) - max(a, c)) }

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
