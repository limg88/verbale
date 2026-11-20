import Foundation
import CParakeet

public struct SpeakerWindowSettings: Sendable {
    public var coreDuration: Double
    public var context: Double
    public init(coreDuration: Double = 90, context: Double = 15) { self.coreDuration = coreDuration; self.context = context }
}

extension VoiceAnalysisEngine {
    private func regions(context: NativeContext, meeting: Meeting, audio: VoiceAudio, source: AudioSource, start: Double, end: Double) throws -> [SpeakerRegion] {
        guard let stream = vb_diar_begin(context.pointer) else { throw VerbaleError.message("Impossibile avviare l’analisi locale delle voci.") }
        defer { vb_diar_end(context.pointer, stream) }
        let begin = Int((start * 16000).rounded()), until = Int((end * 16000).rounded())
        var position = begin, output: [SpeakerRegion] = []
        func feed(_ samples: [Float], last: Bool = false) throws {
            try Task.checkCancellation()
            var out: UnsafeMutablePointer<vb_voice_region>?, count: Int32 = 0
            let status = samples.withUnsafeBufferPointer { vb_diar_feed(context.pointer, stream, $0.baseAddress, Int32($0.count), last ? 1 : 0, &out, &count) }
            defer { if let out { vb_free_regions(out) } }
            guard status == 0 else { throw VerbaleError.message("Analisi locale interrotta: " + String(cString: vb_error(context.pointer))) }
            if let out { for i in 0..<Int(count) {
                let r = out[i]
                output.append(SpeakerRegion(start: start + Double(r.start), end: start + Double(r.end), speaker: r.speaker >= 0 ? Int(r.speaker) : nil))
            } }
            position += samples.count
        }
        let chunks = meeting.chunks.filter { $0.source == source && $0.start < end && $0.start + $0.duration > start }.sorted { $0.start < $1.start }
        for chunk in chunks {
            let chunkStart = Int((chunk.start * 16000).rounded())
            let a = max(begin, chunkStart), b = min(until, chunkStart + chunk.sampleCount)
            while position < a { try feed([Float](repeating: 0, count: min(80000, a-position))) }
            let filename = try audio.filename(chunk, meeting: meeting)
            while position < b { let n = min(80000,b-position); try feed(audio.read(filename, offset: position-chunkStart, count: n)) }
        }
        while position < until { try feed([Float](repeating: 0, count: min(80000,until-position))) }
        try feed([], last: true)
        return output
    }
    /// Local model slots are reset per window; the linker has no eight-person meeting limit.
    public func auditSpeakers(meeting: Meeting, audio: VoiceAudio, diarization: URL, voice: URL, voiceHash: String,
                              settings: SpeakerWindowSettings = SpeakerWindowSettings(), library: URL = TranscriptionEngine.defaultLibrary,
                              progress: @Sendable (String) -> Void = { _ in }) throws -> SpeakerAudit {
        guard settings.coreDuration.isFinite, (5...300).contains(settings.coreDuration), settings.context.isFinite, (0...60).contains(settings.context),
              meeting.duration.isFinite, meeting.duration > 0, meeting.duration < 86400, !meeting.segments.isEmpty else { throw VerbaleError.message("Durata o parametri dell’analisi non validi.") }
        let diarizer = try NativeContext(library: library, model: diarization)
        let speaker = try NativeContext(library: library, model: voice), encoder = try encoder(speaker, expectedHash: voiceHash)
        var linker = SpeakerWindowLinker(), proposed = meeting.segments
        var originalIDs = Dictionary(meeting.segments.map { ($0.id,$0.id) }, uniquingKeysWith: { first, _ in first })
        var pieceGroups: [UUID:UUID] = [:], warnings: [String] = [], shortWindows = 0, failedSamples = 0, saturatedWindows = 0
        let windows = Int(ceil(meeting.duration / settings.coreDuration))
        for source in meeting.sources {
            guard meeting.chunks.contains(where: { $0.source == source }) else { warnings.append("Audio non disponibile per \(source.label)."); continue }
            var allRegions: [SpeakerRegion] = [], previousContext: [SpeakerRegion] = []
            for window in 0..<windows {
                try Task.checkCancellation()
                let coreStart = Double(window) * settings.coreDuration, coreEnd = min(meeting.duration,coreStart+settings.coreDuration)
                progress("Ricerca voci · \(source.label) · finestra \(window+1)/\(windows) · \(timecode(coreStart))")
                let local = try regions(context: diarizer, meeting: meeting, audio: audio, source: source, start: max(0,coreStart-settings.context), end: min(meeting.duration,coreEnd+settings.context))
                let slots = Set(local.filter { $0.end > coreStart && $0.start < coreEnd }.compactMap(\.speaker)).sorted()
                if slots.count >= 8 { saturatedWindows += 1 }
                var used = Set<Int>(), localToGlobal: [Int:Int] = [:]
                for slot in slots {
                    let spans = cleanSpans(local, slot: slot, start: coreStart, end: coreEnd)
                    var candidates: [VoiceClip] = []
                    for span in spans {
                        var cursor = span.0 + 0.1
                        while span.1 - cursor - 0.1 >= 3 {
                            let until = min(span.1-0.1,cursor+6)
                            candidates.append(VoiceClip(meetingID: meeting.id, source: source, start: cursor, end: until, text: "Campione della voce proposta"))
                            cursor = until + 0.2
                        }
                    }
                    // Spread exemplars over the window; never infer identity from silence or a very short turn.
                    let chosen = spread(candidates, maximum: 3)
                    var vectors: [[Float]] = [], clips: [VoiceClip] = []
                    for clip in chosen {
                        do {
                            let samples = try audio.samples(clip, meeting: meeting)
                            guard VoiceClipQuality.measure(samples).usable else { failedSamples += 1; continue }
                            vectors.append(try embed(samples, context: speaker, encoder: encoder)); clips.append(clip)
                        } catch is CancellationError { throw CancellationError() }
                        catch { failedSamples += 1 }
                    }
                    if vectors.isEmpty { shortWindows += 1 }
                    let anchor = temporalAnchor(local: local, slot: slot, previous: previousContext, start: max(0,coreStart-settings.context), end: min(meeting.duration,coreStart+settings.context), excluding: used)
                    let track = try linker.link(vectors: vectors, clips: clips, usedInWindow: used, temporalAnchor: anchor)
                    used.insert(track); localToGlobal[slot] = track
                }
                previousContext = local.map { SpeakerRegion(start: $0.start, end: $0.end, speaker: $0.speaker.flatMap { localToGlobal[$0] }) }
                for region in local where region.end > coreStart && region.start < coreEnd {
                    allRegions.append(SpeakerRegion(start: max(coreStart,region.start), end: min(coreEnd,region.end), speaker: region.speaker.flatMap { localToGlobal[$0] }))
                }
            }
            let split = SpeakerDiarization.split(proposed, regions: allRegions, source: source)
            for (parent, children) in split.replacements { for child in children { originalIDs[child] = originalIDs[parent] ?? parent } }
            proposed = split.segments
            for i in proposed.indices where proposed[i].source == source {
                var track: Int?
                if !proposed[i].words.isEmpty {
                    track = proposed[i].speakerID.flatMap { Int($0.replacingOccurrences(of: source == .system ? "Interlocutore " : "Microfono ", with: "")) }.map { $0-1 }
                } else {
                    // Edited/unaligned text is never partitioned. Only a single dominating local voice may be proposed.
                    let segment = proposed[i]
                    let overlaps = allRegions.filter { $0.start < segment.end && $0.end > segment.start }
                    let known = Set(overlaps.compactMap(\.speaker))
                    if known.count == 1, let single = known.first {
                        let coverage = overlaps.filter { $0.speaker == single }.reduce(0.0) { $0 + max(0,min(segment.end,$1.end)-max(segment.start,$1.start)) }
                        if segment.end > segment.start && coverage / (segment.end-segment.start) >= 0.8 { track = single }
                    }
                }
                if let track, linker.tracks.indices.contains(track) { pieceGroups[proposed[i].id] = linker.tracks[track].group.id }
                // Proposals never inherit a named diarization slot as an identified person.
                proposed[i].speakerID = nil
            }
        }
        if shortWindows > 0 { warnings.append("\(shortWindows) gruppi locali hanno parlato troppo poco o non hanno campioni utilizzabili: potrebbero duplicare altre voci.") }
        if failedSamples > 0 { warnings.append("\(failedSamples) campioni non utilizzabili sono stati esclusi dal confronto.") }
        if saturatedWindows > 0 { warnings.append("\(saturatedWindows) finestre raggiungono ancora il limite locale di 8 voci: possibili ulteriori accorpamenti.") }
        warnings.append("I gruppi proposti non equivalgono a un conteggio certo delle persone. Voci brevi, rumore e sovrapposizioni possono produrre gruppi duplicati o mancanti.")
        let pieces = proposed.map { SpeakerAuditPiece(originalID: originalIDs[$0.id] ?? $0.id, segment: $0, groupID: pieceGroups[$0.id]) }
        let referenced = Set(pieces.compactMap(\.groupID))
        return try SpeakerAudit(meeting: meeting, groups: linker.tracks.map(\.group).filter { referenced.contains($0.id) }, pieces: pieces,
                                modelDigests: ["voice":voiceHash,"diarization":ModelManager.digest(diarization)], warnings: warnings)
    }
    private func temporalAnchor(local: [SpeakerRegion], slot: Int, previous: [SpeakerRegion], start: Double, end: Double, excluding: Set<Int>) -> Int? {
        guard end > start, !previous.isEmpty else { return nil }
        let current = cleanSpans(local,slot:slot,start:start,end:end)
        let duration = current.reduce(0.0) { $0 + $1.1-$1.0 }
        guard duration >= 2 else { return nil }
        var scores: [(Int,Double,Double)] = []
        for track in Set(previous.compactMap(\.speaker)) where !excluding.contains(track) {
            let old = cleanSpans(previous,slot:track,start:start,end:end)
            let oldDuration = old.reduce(0.0) { $0 + $1.1-$1.0 }
            var overlap = 0.0
            for a in current { for b in old { overlap += max(0,min(a.1,b.1)-max(a.0,b.0)) } }
            if overlap >= 2 && oldDuration > 0 { scores.append((track,overlap/duration,overlap/oldDuration)) }
        }
        scores.sort { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= 0.70, best.2 >= 0.70, best.1-(scores.dropFirst().first?.1 ?? 0) >= 0.25 else { return nil }
        return best.0
    }
    private func spread(_ clips: [VoiceClip], maximum: Int) -> [VoiceClip] {
        guard clips.count > maximum else { return clips }
        return (0..<maximum).map { clips[Int((Double($0) * Double(clips.count-1) / Double(maximum-1)).rounded())] }
    }
    private func cleanSpans(_ regions: [SpeakerRegion], slot: Int, start: Double, end: Double) -> [(Double,Double)] {
        var result: [(Double,Double)] = []
        for region in regions where region.speaker == slot && region.end > start && region.start < end {
            var spans = [(max(start,region.start),min(end,region.end))]
            for other in regions where other.speaker != slot && other.end > region.start && other.start < region.end {
                spans = spans.flatMap { a,b -> [(Double,Double)] in
                    if other.end <= a || other.start >= b { return [(a,b)] }
                    return [(a,min(b,other.start)),(max(a,other.end),b)].filter { $0.1 > $0.0 }
                }
            }
            result.append(contentsOf: spans)
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
