import Foundation
import AVFoundation
import CParakeet

/// Reads only the requested frames from Verbale's canonical 16 kHz mono files.
public struct VoiceAudio: Sendable {
    public let workspace: URL
    public let exported: URL
    public init(workspace: URL, exported: URL) { self.workspace = workspace; self.exported = exported }
    public func url(_ filename: String) throws -> URL {
        guard !filename.hasPrefix("/"), !filename.split(separator: "/").contains("..") else { throw VerbaleError.message("Percorso audio non valido.") }
        for root in [workspace, exported] {
            let file = root.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        throw VerbaleError.message("Audio non disponibile. Per creare o riconoscere una voce conserva l’audio della riunione.")
    }
    public func filename(_ chunk: AudioChunk, meeting: Meeting) throws -> String {
        if chunk.source == .microphone && meeting.usesEchoCancellation {
            guard let clean = chunk.cleanedFilename else { throw VerbaleError.message("Il microfono non dispone dell’audio con eco ridotto: completa prima la trascrizione.") }
            return clean
        }
        return chunk.filename
    }
    public func read(_ filename: String, offset: Int, count: Int) throws -> [Float] {
        guard offset >= 0, count > 0, count <= 8 * 16000 else { throw VerbaleError.message("Intervallo audio non valido.") }
        let file = try AVAudioFile(forReading: url(filename), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              Int64(offset + count) <= file.length else { throw VerbaleError.message("Audio incompleto o formato diverso da quello della registrazione.") }
        file.framePosition = AVAudioFramePosition(offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(count, 32768)))!
        var samples: [Float] = []
        while samples.count < count {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int(buffer.frameCapacity), count - samples.count)))
            guard buffer.frameLength > 0, let p = buffer.floatChannelData?[0] else { throw VerbaleError.message("Campione audio incompleto.") }
            samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(buffer.frameLength)))
        }
        return samples
    }
    public func samples(_ clip: VoiceClip, meeting: Meeting, minimumDuration: Double = 3) throws -> [Float] {
        guard clip.meetingID == meeting.id, clip.start.isFinite, clip.end.isFinite, clip.start >= 0, minimumDuration >= 0.1, minimumDuration <= 3, (minimumDuration...8.1).contains(clip.duration) else { throw VerbaleError.message("Campione vocale non valido.") }
        let begin = Int((clip.start * 16000).rounded()), end = Int((clip.end * 16000).rounded())
        var audio = [Float](repeating: 0, count: end - begin), covered = [Bool](repeating: false, count: end - begin)
        for chunk in meeting.chunks where chunk.source == clip.source {
            let start = Int((chunk.start * 16000).rounded())
            let a = max(begin, start), b = min(end, start + chunk.sampleCount)
            guard b > a else { continue }
            let samples = try read(filename(chunk, meeting: meeting), offset: a - start, count: b - a)
            audio.replaceSubrange((a-begin)..<(b-begin), with: samples)
            for i in (a-begin)..<(b-begin) { covered[i] = true }
        }
        guard !covered.contains(false) else { throw VerbaleError.message("Manca una parte dell’audio del campione. Scegli un altro passaggio.") }
        return audio
    }
    public static func wave(_ samples: [Float]) -> Data {
        var data = Data()
        func bytes(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        bytes("RIFF"); u32(UInt32(36 + samples.count * 4)); bytes("WAVEfmt "); u32(16); u16(3); u16(1); u32(16000); u32(64000); u16(4); u16(32); bytes("data"); u32(UInt32(samples.count * 4))
        for sample in samples { u32(sample.bitPattern) }
        return data
    }
}

public enum VoiceConsensus {
    /// Similarity is not a probability. Two distinct, concordant clips are necessary for an automatic name.
    public static func decision(_ ranks: [VoiceRanking?]) -> (VoiceRanking, Bool)? {
        guard let first = ranks.compactMap({ $0 }).first else { return nil }
        guard ranks.compactMap({ $0 }).allSatisfy({ $0.profileID == first.profileID }) else { return nil }
        let automatic = ranks.count >= 2 && ranks.allSatisfy { $0?.strong == true }
        return (first, automatic)
    }
}

public actor VoiceAnalysisEngine {
    public init() {}
    func encoder(_ context: NativeContext, expectedHash: String?) throws -> VoiceEncoderID {
        guard let identity = vb_voice_identity(context.pointer), let family = vb_voice_family(context.pointer) else { throw VerbaleError.message("Il modello non supporta i profili vocali.") }
        let id = VoiceEncoderID(identity: String(cString: identity), family: String(cString: family), dimension: Int(vb_voice_dimension(context.pointer)))
        guard id.dimension > 0, id.dimension <= 4096, expectedHash == nil || id.identity == "sha256:" + expectedHash! else { throw VerbaleError.message("Identità del modello vocale diversa da quella attesa.") }
        return id
    }
    func embed(_ audio: [Float], context: NativeContext, encoder: VoiceEncoderID) throws -> [Float] {
        try Task.checkCancellation()
        let quality = VoiceClipQuality.measure(audio)
        guard quality.usable else { throw VerbaleError.message("Campione non utilizzabile: " + quality.detail + ". Scegli un altro passaggio.") }
        var output: UnsafeMutablePointer<Float>?, count: Int32 = 0
        let status = audio.withUnsafeBufferPointer { vb_embed(context.pointer, $0.baseAddress, Int32($0.count), &output, &count) }
        guard status == 0, let output else { throw VerbaleError.message("Analisi vocale non riuscita: " + String(cString: vb_error(context.pointer))) }
        defer { vb_free_embedding(context.pointer, output) }
        guard count == encoder.dimension else { throw VerbaleError.message("Dimensione del profilo vocale inattesa.") }
        return try VoiceVectors.normalized(Array(UnsafeBufferPointer(start: output, count: Int(count))), dimension: encoder.dimension)
    }
    public func quality(clips: [VoiceClip], meeting: Meeting, audio: VoiceAudio) throws -> [UUID: VoiceClipQuality] {
        var result: [UUID: VoiceClipQuality] = [:]
        for clip in clips {
            try Task.checkCancellation()
            do { result[clip.id] = VoiceClipQuality.measure(try audio.samples(clip, meeting: meeting)) }
            catch { result[clip.id] = .unavailable(error.localizedDescription) }
        }
        return result
    }
    public func enroll(clips: [VoiceClip], meeting: Meeting, audio: VoiceAudio, model: URL, hash: String, library: URL = TranscriptionEngine.defaultLibrary) throws -> (VoiceEncoderID, [VoiceSample]) {
        guard (2...6).contains(clips.count) else { throw VerbaleError.message("Seleziona da due a sei campioni.") }
        let context = try NativeContext(library: library, model: model), id = try encoder(context, expectedHash: hash)
        var samples: [VoiceSample] = []
        for clip in clips {
            do { samples.append(VoiceSample(clip: clip, embedding: try embed(audio.samples(clip, meeting: meeting), context: context, encoder: id))) }
            catch is CancellationError { throw CancellationError() }
            catch { throw VerbaleError.message("Passaggio a " + timecode(clip.start) + ": " + error.localizedDescription) }
        }
        return (id, samples)
    }
    public func diarize(meeting: Meeting, audio: VoiceAudio, model: URL, library: URL = TranscriptionEngine.defaultLibrary,
                        progress: @Sendable (String) -> Void = { _ in }) throws -> Meeting {
        let context = try NativeContext(library: library, model: model)
        var result = meeting
        let protected = meeting.voiceProtectedSegments
        for source in meeting.sources {
            let chunks = meeting.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
            guard !chunks.isEmpty else { continue }
            guard let stream = vb_diar_begin(context.pointer) else { throw VerbaleError.message("Impossibile avviare la separazione degli interlocutori.") }
            defer { vb_diar_end(context.pointer, stream) }
            var regions: [SpeakerRegion] = [], position = 0
            func feed(_ samples: [Float], last: Bool = false) throws {
                try Task.checkCancellation()
                var out: UnsafeMutablePointer<vb_voice_region>?, count: Int32 = 0
                let status = samples.withUnsafeBufferPointer { vb_diar_feed(context.pointer, stream, $0.baseAddress, Int32($0.count), last ? 1 : 0, &out, &count) }
                defer { if let out { vb_free_regions(out) } }
                guard status == 0 else { throw VerbaleError.message("Separazione interlocutori interrotta: " + String(cString: vb_error(context.pointer))) }
                if let out { for i in 0..<Int(count) { let r = out[i]; regions.append(SpeakerRegion(start: Double(r.start), end: Double(r.end), speaker: r.speaker >= 0 ? Int(r.speaker) : nil)) } }
                position += samples.count
            }
            for chunk in chunks {
                let start = max(0, Int((chunk.start * 16000).rounded()))
                while position < start { try feed([Float](repeating: 0, count: min(80000, start - position))) }
                var offset = max(0, position - start)
                let filename = try audio.filename(chunk, meeting: meeting)
                while offset < chunk.sampleCount {
                    let count = min(80000, chunk.sampleCount - offset)
                    try feed(audio.read(filename, offset: offset, count: count)); offset += count
                }
                progress("Separazione · \(source.label) · \(timecode(Double(position) / 16000)) / \(timecode(meeting.duration))")
            }
            try feed([], last: true)
            result.applyDiarization(SpeakerDiarization.split(result.segments, regions: regions, source: source, protected: protected))
        }
        return result
    }
    public func recognize(meeting: Meeting, audio: VoiceAudio, model: URL, hash: String, profiles: [VoiceProfile], library: URL = TranscriptionEngine.defaultLibrary,
                          progress: @Sendable (String) -> Void = { _ in }) throws -> Meeting {
        let context = try NativeContext(library: library, model: model), id = try encoder(context, expectedHash: hash)
        var result = meeting
        let protected = meeting.voiceProtectedSegments
        for source in meeting.sources {
            let groups = Dictionary(grouping: meeting.segments.filter { $0.source == source && !protected.contains($0.id) }, by: { $0.speakerID ?? "" })
            for (speaker, segments) in groups.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                // Without a diarization slot, distinct segments may contain different people: never name the entire source.
                let groups = speaker.isEmpty ? segments.filter { $0.end - $0.start >= 3.2 }.map { [$0] } : [segments]
                for group in groups {
                    // Candidate extraction still sees every other speaker to exclude overlaps.
                    let allowed = Set(group.map(\.id))
                    let clips = VoiceClips.candidates(meeting: meeting, speakerID: speaker.isEmpty ? nil : speaker, source: source, maximum: 3, segmentIDs: allowed)
                    var ranks: [VoiceRanking?] = []
                    for clip in clips {
                        do { ranks.append(try VoiceVectors.rank(embed(audio.samples(clip, meeting: meeting), context: context, encoder: id), encoder: id, profiles: profiles)) }
                        catch is CancellationError { throw CancellationError() }
                        catch { ranks.append(nil) }
                    }
                    if let (ranking, automatic) = VoiceConsensus.decision(ranks) { result.applyVoiceGroup(allowed, ranking: ranking, automatic: automatic && !speaker.isEmpty) }
                }
                progress("Confronto profili · \(source.label) · \(speaker.isEmpty ? "passaggi senza nome" : speaker)")
            }
        }
        return result
    }
}
