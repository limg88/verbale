import Foundation
import CryptoKit

public struct SpeakerAutomaticAssignment: Codable, Sendable {
    public var name: String
    public var previousSpeakerID: String?
    public var score: Double
    public var margin: Double
}
public struct SpeakerLearningMatch: Sendable {
    public var name: String
    public var score: Double
    public var margin: Double
    public init(name: String, score: Double, margin: Double) { self.name = name; self.score = score; self.margin = margin }
}
public struct SpeakerLearningReference: Sendable {
    public let name: String
    public let vector: [Float]
    public let evidenceID: String
    /// Only explicitly confirmed audio can be admitted as a reference.
    public let explicitlyConfirmed: Bool
    public init(name: String, vector: [Float], evidenceID: String, explicitlyConfirmed: Bool) { self.name = name; self.vector = vector; self.evidenceID = evidenceID; self.explicitlyConfirmed = explicitlyConfirmed }
}
public enum SpeakerLearningMatcher {
    public static func match(_ vector: [Float], references: [SpeakerLearningReference]) throws -> SpeakerLearningMatch? {
        let vector = try VoiceVectors.normalized(vector, dimension: vector.count)
        let trusted = references.filter { $0.explicitlyConfirmed && $0.vector.count == vector.count }
        let people = Dictionary(grouping: trusted, by: \.name)
        var scores: [(String,Double,Int,Double)] = []
        for (name, refs) in people {
            var unique = Set<String>(), similarities: [Double] = []
            for ref in refs where unique.insert(ref.evidenceID).inserted {
                let normalized = try VoiceVectors.normalized(ref.vector, dimension: vector.count)
                similarities.append(zip(vector,normalized).reduce(0.0) { $0 + Double($1.0)*Double($1.1) })
            }
            similarities.sort(by: >)
            if let best = similarities.first { scores.append((name,best,similarities.count,similarities.dropFirst().first ?? -1)) }
        }
        scores.sort { $0.1 > $1.1 }
        guard let best = scores.first else { return nil }
        let margin = best.1-max(0.55,scores.dropFirst().first?.1 ?? 0.55)
        let supported = best.2 >= 2 && best.3 >= 0.75
        guard best.1 >= (supported ? 0.80 : 0.90), margin >= 0.15 else { return nil }
        return SpeakerLearningMatch(name:best.0,score:best.1,margin:margin)
    }
}

public struct SpeakerLearningUnit: Sendable {
    public var pieces: [SpeakerAuditPiece]
    public var source: AudioSource
    public var duration: Double { pieces.reduce(0) { $0 + $1.segment.end-$1.segment.start } }
    public func key(audioIdentity: String) throws -> String {
        struct Span: Encodable { let start: Double; let end: Double }
        struct Input: Encodable { let audio: String; let source: AudioSource; let spans: [Span] }
        let data = try JSONCoding.encoder().encode(Input(audio:audioIdentity,source:source,spans:pieces.map { Span(start:$0.segment.start,end:$0.segment.end) }))
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
}
public enum SpeakerLearningUnits {
    /// References may combine separate utterances explicitly attributed to the same person.
    public static func references(_ pieces: [SpeakerAuditPiece]) -> [SpeakerLearningUnit] { build(pieces, contiguous:false) }
    /// Candidate audio never bridges an unverified speaker change or a long pause.
    public static func candidates(_ pieces: [SpeakerAuditPiece]) -> [SpeakerLearningUnit] { build(pieces, contiguous:true) }
    private static func build(_ pieces: [SpeakerAuditPiece], contiguous: Bool) -> [SpeakerLearningUnit] {
        var result: [SpeakerLearningUnit] = [], batch: [SpeakerAuditPiece] = [], duration = 0.0
        func finish() {
            if duration >= 3, let source = batch.first?.segment.source { result.append(SpeakerLearningUnit(pieces:batch,source:source)) }
            batch = []; duration = 0
        }
        var expanded: [SpeakerAuditPiece] = []
        for piece in pieces {
            let duration = piece.segment.end-piece.segment.start
            if duration > 8 && duration.isFinite && duration < 86400 {
                let count = Int(ceil(duration/6))
                for i in 0..<count {
                    var part = piece
                    part.segment.start = piece.segment.start+duration*Double(i)/Double(count)
                    part.segment.end = piece.segment.start+duration*Double(i+1)/Double(count)
                    expanded.append(part)
                }
            } else { expanded.append(piece) }
        }
        for piece in expanded.sorted(by: { $0.segment.start < $1.segment.start }) {
            let d = piece.segment.end-piece.segment.start
            guard d.isFinite, d >= 0.15, d <= 8 else { finish(); continue }
            if let prior = batch.last {
                let gap = piece.segment.start-prior.segment.end
                if prior.segment.source != piece.segment.source || (contiguous && (gap > 0.35 || gap < -0.01)) || duration+d > 7.5 { finish() }
            }
            batch.append(piece); duration += d
            if duration >= 5 { finish() }
        }
        finish(); return result
    }
}

public extension SpeakerAudit {
    mutating func noteManualAssignment(segmentID: UUID, name: String, meeting: Meeting) throws {
        guard meetingID == meeting.id, pieces.contains(where: { $0.id == segmentID }), let segment = meeting.segments.first(where: { $0.id == segmentID }), meeting.speakerName(for: segment) == name else { return }
        let children = pieces.filter { $0.originalID == segmentID }.map(\.id)
        let ids = !materializedParents.contains(segmentID) && !children.isEmpty ? children : [segmentID]
        confirmedAssignments = confirmedAssignments ?? [:]
        for id in ids { confirmedAssignments?[id.uuidString] = name; automaticAssignments?.removeValue(forKey:id.uuidString); applied.insert(id) }
        inputFingerprint = try Self.fingerprint(meeting)
    }
    /// Rebase a batch of reviewed ASR text edits while retaining voice evidence.
    mutating func rebaseTranscriptChanges(previous:Meeting,updated:Meeting) throws {
        guard isCurrent(for:previous),previous.id == updated.id,previous.speakers == updated.speakers,
              previous.segments.count == updated.segments.count,
              zip(previous.segments,updated.segments).allSatisfy({ $0.id == $1.id && $0.source == $1.source && $0.start == $1.start && $0.end == $1.end && $0.speakerID == $1.speakerID }),
              try JSONCoding.encoder().encode(previous.chunks) == JSONCoding.encoder().encode(updated.chunks) else { throw VerbaleError.message("La struttura della riunione è cambiata: ripeti l’analisi delle voci.") }
        var interim = previous
        for i in updated.segments.indices where previous.segments[i].text != updated.segments[i].text {
            var next = interim;next.segments[i] = updated.segments[i];next.review = updated.review
            try rebaseTextCorrection(segmentID:next.segments[i].id,previous:interim,updated:next)
            interim = next
        }
        inputFingerprint = try Self.fingerprint(updated)
    }
    /// Text edits keep the analysis usable without turning an automatic name into a human confirmation.
    mutating func rebaseTextCorrection(segmentID: UUID, previous: Meeting, updated: Meeting) throws {
        guard isCurrent(for:previous), previous.id == updated.id,
              let old = previous.segments.first(where: { $0.id == segmentID }), let current = updated.segments.first(where: { $0.id == segmentID }),
              old.start == current.start, old.end == current.end, old.source == current.source else { throw VerbaleError.message("Il passaggio è cambiato: ripeti l’analisi prima della rivalutazione.") }
        if old.text != current.text {
            if !materializedParents.contains(segmentID), pieces.contains(where: { $0.originalID == segmentID }) {
                let removed = Set(pieces.filter { $0.originalID == segmentID }.map(\.id))
                pieces.removeAll { $0.originalID == segmentID }
                pieces.append(SpeakerAuditPiece(originalID:segmentID,segment:current,groupID:nil))
                for id in removed { confirmedAssignments?.removeValue(forKey:id.uuidString); automaticAssignments?.removeValue(forKey:id.uuidString); applied.remove(id) }
                if let i = originalSegments.firstIndex(where: { $0.id == segmentID }) { originalSegments[i] = current }
            } else if let i = pieces.firstIndex(where: { $0.id == segmentID }) {
                pieces[i].segment.text = current.text; pieces[i].segment.words = current.words
            }
        }
        inputFingerprint = try Self.fingerprint(updated)
    }
    var manualEvidence: [String:String] { confirmedAssignments ?? [:] }
    /// Roll back previous predictions in a value copy before each reevaluation. Manual edits always win.
    mutating func retractAutomatic(in meeting: inout Meeting) throws {
        let corrected = Set(meeting.corrections.filter { $0.previousSpeakerID != $0.speakerID }.map(\.segmentID))
        for (key, assignment) in automaticAssignments ?? [:] {
            guard let id = UUID(uuidString:key) else { continue }
            if manualEvidence[key] != nil || corrected.contains(id) { continue }
            if let i = meeting.segments.firstIndex(where: { $0.id == id }), meeting.segments[i].speakerID?.hasPrefix("auto-learn-") == true, meeting.speakerName(for:meeting.segments[i]) == assignment.name {
                meeting.segments[i].speakerID = assignment.previousSpeakerID
                applied.remove(id)
            }
        }
        automaticAssignments = [:]; inputFingerprint = try Self.fingerprint(meeting)
    }
}

public struct SpeakerLearningResult: Sendable {
    public let meeting: Meeting
    public let audit: SpeakerAudit
    public let referenceCount: Int
    public let automaticCount: Int
    public let unresolvedCount: Int
    public let computedEmbeddings: Int
    public let cacheHits: Int
}
private struct SpeakerEmbeddingCache: Codable {
    var encoder: VoiceEncoderID
    var vectors: [String:[Float]] = [:]
}

extension VoiceAnalysisEngine {
    public func reevaluateSpeakers(meeting: Meeting, audit: SpeakerAudit, audio: VoiceAudio, voice: URL, voiceHash: String, cacheURL: URL,
                                   profiles: [VoiceProfile] = [], library: URL = TranscriptionEngine.defaultLibrary,
                                   progress: @Sendable (String) -> Void = { _ in }) throws -> SpeakerLearningResult {
        guard audit.isCurrent(for:meeting) else { throw VerbaleError.message("I contenuti sono cambiati. Riapri o ripeti l’analisi prima della rivalutazione.") }
        try Task.checkCancellation()
        let context = try NativeContext(library:library,model:voice), encoder = try encoder(context,expectedHash:voiceHash)
        var cache = (try? JSONCoding.decoder().decode(SpeakerEmbeddingCache.self,from:Data(contentsOf:cacheURL))) ?? SpeakerEmbeddingCache(encoder:encoder)
        if cache.encoder != encoder { cache = SpeakerEmbeddingCache(encoder:encoder) }
        struct AudioInput: Encodable { let chunks: [AudioChunk]; let mode: ListeningMode?; let echoVersion: Int? }
        let audioIdentity = SHA256.hash(data:try JSONCoding.encoder().encode(AudioInput(chunks:meeting.chunks,mode:meeting.listeningMode,echoVersion:meeting.usesEchoCancellation ? meeting.echoProcessingVersion : nil))).map { String(format:"%02x",$0) }.joined()
        var computedEmbeddings = 0, cacheHits = 0
        func vector(_ unit: SpeakerLearningUnit) throws -> [Float] {
            try Task.checkCancellation()
            let key = try unit.key(audioIdentity:audioIdentity)
            if let cached = cache.vectors[key], let normalized = try? VoiceVectors.normalized(cached,dimension:encoder.dimension) { cacheHits += 1; return normalized }
            var samples: [Float] = []
            for piece in unit.pieces {
                let s = piece.segment
                let clip = VoiceClip(meetingID:meeting.id,source:s.source,start:s.start,end:s.end,text:s.text)
                samples += try audio.samples(clip,meeting:meeting,minimumDuration:0.15)
            }
            let value = try embed(samples,context:context,encoder:encoder); computedEmbeddings += 1
            if cache.vectors.count < 5000 { cache.vectors[key] = value }
            return value
        }
        var proposedMeeting = meeting, proposedAudit = audit
        try proposedAudit.retractAutomatic(in:&proposedMeeting)
        let currentByID = Dictionary(proposedMeeting.segments.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
        // Old audit versions only recorded explicit confirmations in `applied`; safely migrate matching manual corrections.
        for piece in proposedAudit.pieces where proposedAudit.applied.contains(piece.id) && proposedAudit.manualEvidence[piece.id.uuidString] == nil {
            if let current = currentByID[piece.id], meeting.corrections.contains(where: { $0.segmentID == piece.id && $0.previousSpeakerID != $0.speakerID }) {
                try proposedAudit.noteManualAssignment(segmentID:piece.id,name:meeting.speakerName(for:current),meeting:proposedMeeting)
            }
        }
        for match in meeting.voiceMatches ?? [] where match.state == .confirmed {
            if let current = currentByID[match.segmentID] { try proposedAudit.noteManualAssignment(segmentID:current.id,name:meeting.speakerName(for:current),meeting:proposedMeeting) }
        }
        let unclassified = proposedAudit.learningUnclassifiedGroup ?? UUID()
        var addedUnclassified = false
        for i in proposedAudit.pieces.indices where proposedAudit.pieces[i].groupID == nil && proposedAudit.pieces[i].segment.end-proposedAudit.pieces[i].segment.start >= 3 {
            proposedAudit.pieces[i].groupID = unclassified; addedUnclassified = true
        }
        if addedUnclassified {
            proposedAudit.learningUnclassifiedGroup = unclassified
            if !proposedAudit.groups.contains(where: { $0.id == unclassified }) {
                var group = SpeakerAuditGroup(label:"Passaggi senza gruppo iniziale",clips:[],caution:"Vengono confrontati singolarmente; non rappresentano una sola voce.")
                group.id = unclassified; proposedAudit.groups.append(group)
            }
        }
        let evidence = proposedAudit.manualEvidence
        var byPerson: [String:[SpeakerAuditPiece]] = [:]
        for piece in proposedAudit.pieces {
            guard let name = evidence[piece.id.uuidString], let current = currentByID[piece.id] ?? (!proposedAudit.materializedParents.contains(piece.originalID) ? currentByID[piece.originalID] : nil), proposedMeeting.speakerName(for:current) == name else { continue }
            byPerson[name,default:[]].append(piece)
        }
        var references: [SpeakerLearningReference] = []
        for (name,pieces) in byPerson.sorted(by: { $0.key < $1.key }) {
            for unit in SpeakerLearningUnits.references(pieces).suffix(12) {
                do { references.append(SpeakerLearningReference(name:name,vector:try vector(unit),evidenceID:try unit.key(audioIdentity:audioIdentity),explicitlyConfirmed:true)) }
                catch is CancellationError { throw CancellationError() } catch { /* A short, quiet or missing reference is never replaced by unverified context. */ }
            }
        }
        // Existing enrollment samples are explicit evidence; automatic predictions never enter this list.
        for profile in profiles where profile.enabled && profile.encoder == encoder {
            for sample in profile.samples where sample.clip.meetingID == meeting.id {
                let contradicted = proposedAudit.pieces.contains { piece in
                    guard let name = evidence[piece.id.uuidString], name != profile.name, piece.segment.source == sample.clip.source else { return false }
                    return min(piece.segment.end,sample.clip.end) > max(piece.segment.start,sample.clip.start)
                }
                if !contradicted { references.append(SpeakerLearningReference(name:profile.name,vector:sample.embedding,evidenceID:"profile-"+sample.id.uuidString,explicitlyConfirmed:true)) }
            }
        }
        let corrected = Set(meeting.corrections.filter { $0.previousSpeakerID != $0.speakerID }.map(\.segmentID)).union((meeting.voiceMatches ?? []).filter { $0.state == .confirmed || $0.state == .rejected }.map(\.segmentID))
        let manualIDs = Set(evidence.keys.compactMap(UUID.init(uuidString:))).union(corrected)
        let eligible = proposedAudit.pieces.filter { piece in
            guard !manualIDs.contains(piece.id), !(corrected.contains(piece.originalID) && !proposedAudit.materializedParents.contains(piece.originalID)), !proposedAudit.applied.contains(piece.id), piece.groupID != nil else { return false }
            return true
        }
        let groups = Dictionary(grouping:eligible,by: { $0.groupID! })
        var units: [(UUID,SpeakerLearningUnit)] = []
        for (group,pieces) in groups {
            if group == proposedAudit.learningUnclassifiedGroup {
                for piece in pieces { units += SpeakerLearningUnits.candidates([piece]).map { (group,$0) } }
            } else { units += SpeakerLearningUnits.candidates(pieces).map { (group,$0) } }
        }
        units.sort { ($0.1.pieces.first?.segment.start ?? 0) < ($1.1.pieces.first?.segment.start ?? 0) }
        var decisions: [UUID:[String:[UUID:SpeakerLearningMatch]]] = [:]
        var required: [UUID:Int] = [:], votes: [UUID:[SpeakerLearningMatch]] = [:]
        for item in units { for id in Set(item.1.pieces.map(\.id)) { required[id,default:0] += 1 } }
        if !references.isEmpty {
            for (index,item) in units.enumerated() {
                try Task.checkCancellation()
                if index % 10 == 0 { progress("Rivalutazione · \(index+1)/\(units.count) estratti · \(references.count) riferimenti confermati") }
                do {
                    if let match = try SpeakerLearningMatcher.match(vector(item.1),references:references) {
                        for id in Set(item.1.pieces.map(\.id)) { votes[id,default:[]].append(match) }
                    }
                } catch is CancellationError { throw CancellationError() } catch { /* Unusable audio stays unresolved. */ }
            }
        }
        for piece in eligible {
            guard let matches = votes[piece.id], matches.count == required[piece.id], let first = matches.first, matches.allSatisfy({ $0.name == first.name }), let group = piece.groupID else { continue }
            decisions[group,default:[:]][first.name,default:[:]][piece.id] = SpeakerLearningMatch(name:first.name,score:matches.map(\.score).min() ?? first.score,margin:matches.map(\.margin).min() ?? first.margin)
        }
        for (group,people) in decisions {
            for (name,matches) in people {
                try Task.checkCancellation()
                try proposedAudit.apply(groupID:group,selected:Set(matches.keys),name:name,to:&proposedMeeting,automatic:matches)
            }
        }
        try Task.checkCancellation()
        // Retractions also invalidate a previously generated report if no replacement match survives.
        if Self.speakerNames(proposedMeeting) != Self.speakerNames(meeting) { proposedMeeting.invalidateReport() }
        else { proposedMeeting.review = meeting.review; proposedMeeting.reportStatus = meeting.reportStatus }
        proposedAudit.inputFingerprint = try SpeakerAudit.fingerprint(proposedMeeting)
        try JSONCoding.encoder().encode(cache).write(to:cacheURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:cacheURL.path)
        return SpeakerLearningResult(meeting:proposedMeeting,audit:proposedAudit,referenceCount:references.count,automaticCount:proposedAudit.automaticAssignments?.count ?? 0,unresolvedCount:proposedAudit.pieces.filter { !proposedAudit.applied.contains($0.id) }.count,computedEmbeddings:computedEmbeddings,cacheHits:cacheHits)
    }
    private static func speakerNames(_ meeting: Meeting) -> [String] { meeting.segments.map { $0.id.uuidString+":"+meeting.speakerName(for:$0) } }
}
