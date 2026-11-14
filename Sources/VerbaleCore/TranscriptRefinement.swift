import Foundation
import CryptoKit

public enum RefinementScope:String,Codable,CaseIterable,Sendable { case uncertain, all }
public struct TranscriptProposal:Codable,Identifiable,Sendable {
    public var id:UUID { segmentID }
    public var segmentID:UUID
    public var start:Double
    public var end:Double
    public var source:AudioSource
    public var original:String
    public var candidate:String
    public var words:[Word]
    public init(segment:Segment,candidate:String,words:[Word] = []) {
        segmentID = segment.id;start = segment.start;end = segment.end;source = segment.source
        original = segment.text;self.candidate = candidate;self.words = words
    }
}
public struct TranscriptRefinement:Codable,Identifiable,Sendable {
    public var id = UUID()
    public var created = Date()
    public var original:Meeting
    public var inputFingerprint:String
    public var afterFingerprint:String?
    public var proposals:[TranscriptProposal]
    public var applied:Set<UUID> = []
    public var warnings:[String]
    public var originalSpeakerAnalysis:SpeakerAudit?
    public init(meeting:Meeting,proposals:[TranscriptProposal],warnings:[String] = []) throws {
        original = meeting;original.notes = "";original.report = nil;original.screenshots = [];original.review?.markers = []
        inputFingerprint = try Self.fingerprint(meeting);self.proposals = proposals;self.warnings = warnings
    }
    public static func fingerprint(_ meeting:Meeting) throws -> String {
        struct Input:Encodable { var content:String;var matches:[VoiceMatch]? }
        let data = try JSONCoding.encoder().encode(Input(content:SpeakerAudit.fingerprint(meeting),matches:meeting.voiceMatches))
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    public func isCurrent(for meeting:Meeting) -> Bool { (try? Self.fingerprint(meeting)) == (afterFingerprint ?? inputFingerprint) }
    public var pending:[TranscriptProposal] { proposals.filter { !applied.contains($0.id) } }
    public mutating func apply(_ selected:Set<UUID>,to meeting:inout Meeting) throws {
        guard isCurrent(for:meeting), !selected.isEmpty, selected.isSubset(of:Set(pending.map(\.id))) else { throw VerbaleError.message("La trascrizione è cambiata o la selezione non è valida. Ripeti l’analisi.") }
        var updated = meeting
        for proposal in pending where selected.contains(proposal.id) {
            guard let segment = updated.segments.first(where: { $0.id == proposal.id }),segment.text == proposal.original else { throw VerbaleError.message("Il passaggio è stato modificato: ripeti l’analisi.") }
            guard !original.corrections.contains(where: { $0.segmentID == proposal.id && $0.text != $0.previousText }) else { throw VerbaleError.message("Il passaggio contiene una correzione manuale e non verrà sostituito.") }
            let matches = (updated.voiceMatches ?? []).filter { $0.segmentID == segment.id }
            try updated.correctSegment(segment.id,text:proposal.candidate,speakerID:segment.speakerID)
            // Acceptance concerns words, not speaker identity or new forced alignment.
            if !matches.isEmpty { updated.voiceMatches = (updated.voiceMatches ?? [])+matches }
        }
        applied.formUnion(selected);afterFingerprint = try Self.fingerprint(updated);meeting = updated
    }
    public mutating func undo(in meeting:inout Meeting) throws {
        guard !applied.isEmpty,isCurrent(for:meeting) else { throw VerbaleError.message("Sono presenti modifiche successive: il ripristino automatico non è disponibile.") }
        let previous = Dictionary(original.segments.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
        for i in meeting.segments.indices where applied.contains(meeting.segments[i].id) { if let value = previous[meeting.segments[i].id] { meeting.segments[i] = value } }
        meeting.voiceMatches = (meeting.voiceMatches ?? []).filter { !applied.contains($0.segmentID) }+(original.voiceMatches ?? []).filter { applied.contains($0.segmentID) }
        if meeting.review == nil { meeting.review = MeetingReview() }
        meeting.review?.corrections = original.corrections;meeting.invalidateReport()
        applied = [];afterFingerprint = try Self.fingerprint(meeting)
    }
    public func save(to url:URL) throws {
        try JSONCoding.encoder().encode(self).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public static func load(from url:URL) throws -> Self { try JSONCoding.decoder().decode(Self.self,from:Data(contentsOf:url)) }
}
public enum TranscriptRefinementPlanner {
    public static func targets(_ meeting:Meeting,scope:RefinementScope,selected:Set<UUID>? = nil) -> [Segment] {
        let edited = Set(meeting.corrections.filter { $0.text != $0.previousText }.map(\.segmentID))
        return meeting.segments.filter { segment in
            guard segment.start.isFinite,segment.end.isFinite,segment.end-segment.start >= 0.12,!edited.contains(segment.id), selected == nil || selected!.contains(segment.id) else { return false }
            if scope == .all { return true }
            let scores = segment.words.compactMap(\.conf)
            return scores.isEmpty || scores.contains(where: { $0 < 0.65 }) || (!scores.isEmpty && scores.reduce(0,+)/Double(scores.count) < 0.85)
        }
    }
    private static func tokens(_ text:String) -> [String] {
        text.precomposedStringWithCanonicalMapping.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    public static func proposals(targets:[Segment],recognized:[Segment],context:[Segment]? = nil) -> [TranscriptProposal] {
        var result:[TranscriptProposal] = [], allocated:[UUID:[Word]] = [:]
        let owners = (context ?? targets).sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString:$0.start < $1.start }
        for span in recognized { if Task.isCancelled { return [] };for word in span.words {
            let center = (word.start+word.end)/2
            let candidates = owners.filter { $0.source == span.source && center >= $0.start && center < $0.end }
            let owner = candidates.max { a,b in
                let overlapA = min(word.end,a.end)-max(word.start,a.start)
                let overlapB = min(word.end,b.end)-max(word.start,b.start)
                return overlapA == overlapB ? a.start > b.start:overlapA < overlapB
            }
            if let owner { allocated[owner.id,default:[]].append(word) }
        } }
        for segment in targets {
            if Task.isCancelled { return [] }
            let words = (allocated[segment.id] ?? []).sorted { $0.start < $1.start }
            let candidate = words.map(\.w).joined(separator:" ").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !candidate.isEmpty,candidate != segment.text else { continue }
            let oldTokens = tokens(segment.text),newTokens = tokens(candidate)
            guard !newTokens.isEmpty,oldTokens != newTokens else { continue }
            if newTokens.count < oldTokens.count {
                let cropped = (0...(oldTokens.count-newTokens.count)).contains { offset in Array(oldTokens[offset..<(offset+newTokens.count)]) == newTokens }
                if cropped { continue }
            }
            // A truncated candidate is never offered as a deletion of most of a passage.
            let oldCount = segment.text.split(whereSeparator: { $0.isWhitespace }).count
            let newCount = candidate.split(whereSeparator: { $0.isWhitespace }).count
            guard newCount >= max(1,oldCount/2),newCount <= oldCount*2+3 else { continue }
            result.append(TranscriptProposal(segment:segment,candidate:candidate,words:words))
        }
        return result.sorted { $0.start < $1.start }
    }
}
public extension TranscriptionEngine {
    func refine(meeting:Meeting,audio:VoiceAudio,scope:RefinementScope,selected:Set<UUID>? = nil,progress:@Sendable(String)->Void = { _ in }) throws -> TranscriptRefinement {
        let targets = TranscriptRefinementPlanner.targets(meeting,scope:scope,selected:selected)
        guard !targets.isEmpty else { return try TranscriptRefinement(meeting:meeting,proposals:[],warnings:["Nessun passaggio da rivedere con questa selezione. Le correzioni manuali sono escluse."]) }
        var recognized:[Segment] = [],excluded:Set<UUID> = []
        for source in meeting.sources {
            var sourceTargets = targets.filter { $0.source == source }
            guard !sourceTargets.isEmpty else { continue }
            let chunks = meeting.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
            let lastEnd = chunks.map { $0.start+$0.duration }.max() ?? 0
            guard let first = chunks.first else { throw VerbaleError.message("Audio non disponibile per "+source.label+". Conserva l’audio per usare il riascolto.") }
            sourceTargets = sourceTargets.filter { segment in
                let available = segment.start >= first.start-0.2 && segment.end <= lastEnd+0.2
                if !available { excluded.insert(segment.id) };return available
            }
            guard !sourceTargets.isEmpty else { continue }
            let blocks = Set(sourceTargets.flatMap { segment in stride(from:max(0,Int(segment.start/25)),through:max(0,Int(segment.end/25)),by:1).map { $0 } }).sorted()
            for (step,block) in blocks.enumerated() {
                try Task.checkCancellation()
                let ownedStart = Double(block)*25,ownedEnd = min(lastEnd,ownedStart+25)
                guard ownedEnd > ownedStart else { continue }
                let begin = max(0,ownedStart-5),end = min(lastEnd,ownedEnd+5)
                var samples = [Float](repeating:0,count:Int(((end-begin)*16000).rounded()))
                var covered = [Bool](repeating:false,count:samples.count)
                for chunk in chunks where chunk.start < end && chunk.start+chunk.duration > begin {
                    let a = max(begin,chunk.start),b = min(end,chunk.start+chunk.duration)
                    let target = Int(((a-begin)*16000).rounded()),from = Int(((a-chunk.start)*16000).rounded())
                    let count = min(Int(((b-a)*16000).rounded()),samples.count-target,chunk.sampleCount-from)
                    guard count > 0 else { continue }
                    let name = try audio.filename(chunk,meeting:meeting)
                    var offset = 0
                    while offset < count {
                        let n = min(80000,count-offset),part = try audio.read(name,offset:from+offset,count:n)
                        samples.replaceSubrange((target+offset)..<(target+offset+n),with:part)
                        for i in (target+offset)..<(target+offset+n) { covered[i] = true };offset += n
                    }
                }
                // Missing timeline gaps remain silence; missing declared files throw above.
                let expected = sourceTargets.filter { $0.start < ownedEnd && $0.end > ownedStart }
                guard !expected.isEmpty else { continue }
                for segment in expected {
                    let a = max(0,Int(((max(segment.start,begin)-begin)*16000).rounded()))
                    let b = min(covered.count,Int(((min(segment.end,end)-begin)*16000).rounded()))
                    if b > a && covered[a..<b].reduce(0,{ $0+($1 ? 0:1) }) > 2 { excluded.insert(segment.id) }
                }
                let decoded = try transcribe(samples:samples,source:source,offset:begin,pass:.refinement)
                let owned = AudioChunk(source:source,start:ownedStart,sampleCount:Int(((ownedEnd-ownedStart)*16000).rounded()),filename:"refinement")
                let selected = TranscriptBoundaries.owned(decoded,by:owned)
                recognized += TranscriptBoundaries.reconcile(selected,existing:recognized,chunk:owned).segments
                progress("Riascolto · "+source.label+" · \(step+1)/\(blocks.count) finestre")
            }
        }
        let proposals = TranscriptRefinementPlanner.proposals(targets:targets.filter { !excluded.contains($0.id) },recognized:recognized,context:meeting.segments)
        try Task.checkCancellation()
        var warnings = ["Le proposte derivano da un nuovo riconoscimento dell’audio. Verifica nomi, numeri e negazioni prima di applicarle."]
        if !excluded.isEmpty { warnings.append("\(excluded.count) passaggi esclusi per lacune nella timeline audio. Il testo originale di questi passaggi resta invariato.") }
        return try TranscriptRefinement(meeting:meeting,proposals:proposals,warnings:warnings)
    }
}
