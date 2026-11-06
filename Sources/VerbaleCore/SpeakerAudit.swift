import Foundation
import CryptoKit

public struct SpeakerAuditGroup: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var label: String
    public var clips: [VoiceClip]
    public var caution: String?
    public init(label: String, clips: [VoiceClip], caution: String? = nil) { self.label = label; self.clips = clips; self.caution = caution }
}
public struct SpeakerAuditPiece: Codable, Identifiable, Sendable {
    public var id: UUID { segment.id }
    public var originalID: UUID
    public var segment: Segment
    public var groupID: UUID?
    public init(originalID: UUID, segment: Segment, groupID: UUID?) { self.originalID = originalID; self.segment = segment; self.groupID = groupID }
}
/// A private, independent proposal. It contains no speaker embeddings and never alters Meeting during analysis.
public struct SpeakerAudit: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var version = 1
    public var created = Date()
    public var meetingID: UUID
    public var inputFingerprint: String
    public var modelDigests: [String: String]
    public var groups: [SpeakerAuditGroup]
    public var pieces: [SpeakerAuditPiece]
    public var originalSegments: [Segment]
    public var materializedParents: Set<UUID> = []
    public var applied: Set<UUID> = []
    public var reviewedGroups: Set<UUID>?
    public var reviewedBuckets: Set<String>?
    public var confirmedAssignments: [String:String]?
    public var automaticAssignments: [String:SpeakerAutomaticAssignment]?
    public var learningUnclassifiedGroup: UUID?
    public var warnings: [String]
    public init(meeting: Meeting, groups: [SpeakerAuditGroup], pieces: [SpeakerAuditPiece], modelDigests: [String: String], warnings: [String]) throws {
        meetingID = meeting.id; inputFingerprint = try Self.fingerprint(meeting)
        self.groups = groups; self.pieces = pieces; self.originalSegments = meeting.segments; self.modelDigests = modelDigests; self.warnings = warnings
    }
    public static func fingerprint(_ meeting: Meeting) throws -> String {
        struct Input: Encodable { let id: UUID; let segments: [Segment]; let speakers: [String:String]; let corrections: [SegmentCorrection]; let chunks: [AudioChunk]; let listeningMode: ListeningMode? }
        let data = try JSONCoding.encoder().encode(Input(id: meeting.id, segments: meeting.segments, speakers: meeting.speakers, corrections: meeting.corrections, chunks: meeting.chunks, listeningMode: meeting.listeningMode))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func isCurrent(for meeting: Meeting) -> Bool { meetingID == meeting.id && (try? Self.fingerprint(meeting)) == inputFingerprint }
    public func pending(_ groupID: UUID) -> [SpeakerAuditPiece] { pieces.filter { $0.groupID == groupID && !applied.contains($0.id) }.sorted { $0.segment.start < $1.segment.start } }
    public func save(to url: URL) throws { try JSONCoding.encoder().encode(self).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    public static func load(from url: URL) throws -> SpeakerAudit { try JSONCoding.decoder().decode(Self.self, from: Data(contentsOf: url)) }
    /// Explicitly apply selected proposals only; unrelated names, edited text and anchors survive.
    public mutating func apply(groupID: UUID, selected: Set<UUID>, name: String, to meeting: inout Meeting, automatic: [UUID:SpeakerLearningMatch]? = nil) throws {
        guard isCurrent(for: meeting) else { throw VerbaleError.message("La trascrizione o i nomi sono cambiati. Ripeti l’analisi prima di applicare queste proposte.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(pieces.filter { $0.groupID == groupID && (!applied.contains($0.id) || automaticAssignments?[$0.id.uuidString] != nil) }.map(\.id))
        guard !name.isEmpty, name.count <= 100, !selected.isEmpty, selected.isSubset(of: allowed) else { throw VerbaleError.message("Scegli il nome e almeno un passaggio della stessa voce proposta.") }
        let affectedParents = Set(pieces.filter { selected.contains($0.id) }.map(\.originalID))
        let byParent = Dictionary(grouping: pieces, by: \.originalID)
        let byID = Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0) })
        let originalByID = Dictionary(uniqueKeysWithValues: originalSegments.map { ($0.id, $0) })
        var updated = meeting, output: [Segment] = [], replacements: [UUID:[UUID]] = [:]
        let key = automatic == nil ? "manual-audit-" + UUID().uuidString : "auto-learn-" + UUID().uuidString
        var autoChanges: [String:SpeakerAutomaticAssignment] = [:]
        var changes: [SegmentCorrection] = []
        for current in meeting.segments {
            let parent = byID[current.id]?.originalID ?? current.id
            guard affectedParents.contains(parent) else { output.append(current); replacements[current.id] = [current.id]; continue }
            let candidates: [SpeakerAuditPiece]
            if affectedParents.contains(current.id), !materializedParents.contains(current.id), let children = byParent[current.id] {
                guard children.count <= 1 || !current.words.isEmpty || current.text == originalByID[current.id]?.text else { throw VerbaleError.message("Questo passaggio contiene testo corretto manualmente. Usa l’editor del passaggio o ripeti l’analisi per conservarlo.") }
                candidates = children
            } else if let piece = byID[current.id] { candidates = [piece] }
            else { output.append(current); replacements[current.id] = [current.id]; continue }
            var resulting: [Segment] = []
            for piece in candidates {
                var segment = materializedParents.contains(piece.originalID) && current.id == piece.id ? current : piece.segment
                // Materialization is only a timestamp/text partition; unselected siblings keep the original name.
                segment.speakerID = materializedParents.contains(piece.originalID) ? current.speakerID : originalByID[piece.originalID]?.speakerID
                if selected.contains(piece.id) {
                    let previous = materializedParents.contains(piece.originalID) ? current : (originalByID[piece.originalID] ?? current)
                    if let automatic {
                        guard let match = automatic[segment.id] else { throw VerbaleError.message("Manca il riferimento per un’assegnazione automatica.") }
                        autoChanges[segment.id.uuidString] = SpeakerAutomaticAssignment(name: name, previousSpeakerID: automaticAssignments?[segment.id.uuidString]?.previousSpeakerID ?? previous.speakerID, score: match.score, margin: match.margin)
                    } else {
                        changes.append(SegmentCorrection(segmentID: segment.id, date: Date(), previousText: previous.text, previousSpeakerID: previous.speakerID, previousWords: previous.words, text: segment.text, speakerID: key))
                    }
                    segment.speakerID = key
                }
                resulting.append(segment)
            }
            output.append(contentsOf: resulting); replacements[current.id] = resulting.map(\.id)
        }
        guard Set(output.filter { $0.speakerID == key }.map(\.id)) == selected else { throw VerbaleError.message("Alcuni passaggi non sono più disponibili. Ripeti l’analisi.") }
        updated.applyDiarization(DiarizationResult(segments: output, replacements: replacements))
        updated.speakers[key] = name
        updated.voiceMatches?.removeAll { selected.contains($0.segmentID) || affectedParents.contains($0.segmentID) }
        updated.review?.corrections.append(contentsOf: changes)
        // Commit the value only after every invariant has been checked.
        var next = self
        next.materializedParents.formUnion(affectedParents); next.applied.formUnion(selected)
        if automatic == nil {
            for id in selected {
                next.confirmedAssignments = next.confirmedAssignments ?? [:]; next.confirmedAssignments?[id.uuidString] = name
                next.automaticAssignments?.removeValue(forKey: id.uuidString)
            }
        } else {
            next.automaticAssignments = (next.automaticAssignments ?? [:]).merging(autoChanges) { _,new in new }
        }
        next.inputFingerprint = try Self.fingerprint(updated)
        meeting = updated; self = next
    }
}

/// Dynamic meeting-level identities. Window-local slots have no global meaning.
public struct SpeakerWindowLinker {
    public struct Track {
        public var group: SpeakerAuditGroup
        var vectors: [[Float]]
    }
    public private(set) var tracks: [Track] = []
    public init() {}
    private func center(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var mean = [Float](repeating: 0, count: first.count)
        for vector in vectors { guard vector.count == mean.count else { return nil }; for i in mean.indices { mean[i] += vector[i] / Float(vectors.count) } }
        return try? VoiceVectors.normalized(mean, dimension: mean.count)
    }
    private func similarity(_ a: [Float], _ b: [Float]) -> Double { zip(a,b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } }
    /// Only a clear, consistent match links across windows. Ambiguity produces a separate reviewable group.
    public mutating func link(vectors: [[Float]], clips: [VoiceClip], usedInWindow: Set<Int>, temporalAnchor: Int? = nil) throws -> Int {
        let vectors = try vectors.map { try VoiceVectors.normalized($0, dimension: $0.count) }
        let consistent = vectors.indices.allSatisfy { a in vectors.indices.allSatisfy { b in a == b || similarity(vectors[a], vectors[b]) >= 0.50 } }
        var scores: [(Int,Double)] = []
        if let candidate = center(vectors), consistent {
            for i in tracks.indices where !usedInWindow.contains(i) {
                if let existing = center(tracks[i].vectors) { scores.append((i, similarity(candidate,existing))) }
            }
        }
        scores.sort { $0.1 > $1.1 }
        let best = scores.first, margin = (best?.1 ?? 0) - (scores.dropFirst().first?.1 ?? 0)
        var anchored: Int?
        if let temporalAnchor, tracks.indices.contains(temporalAnchor), !usedInWindow.contains(temporalAnchor), consistent {
            // Same clean audio in the overlapping contexts is a stronger anchor than unrelated utterances.
            let agreement = center(vectors).flatMap { candidate in center(tracks[temporalAnchor].vectors).map { similarity(candidate,$0) } }
            if agreement == nil || agreement! >= 0.35 { anchored = temporalAnchor }
        }
        if let i = anchored ?? (best.flatMap { $0.1 >= 0.78 && margin >= 0.12 ? $0.0 : nil }) {
            let prior = tracks[i].vectors
            tracks[i].vectors = Array((prior + vectors).prefix(6)) + Array((prior + vectors).dropFirst(6).suffix(6))
            if prior.isEmpty && !vectors.isEmpty { tracks[i].group.caution = "Collegato tramite il contesto sovrapposto; verifica i campioni prima di assegnare il nome." }
            for clip in clips where tracks[i].group.clips.count < 6 {
                if !tracks[i].group.clips.contains(where: { $0.source == clip.source && min($0.end,clip.end) > max($0.start,clip.start) }) { tracks[i].group.clips.append(clip) }
            }
            return i
        }
        let caution = vectors.isEmpty ? "Audio troppo breve o non utilizzabile per collegare questa voce alle altre finestre." : !consistent ? "Campioni variabili: questo gruppo potrebbe contenere voci diverse." : (best?.1 ?? 0) >= 0.55 ? "Somiglianza non conclusiva con un altro gruppo: potrebbe essere la stessa persona." : "Nuovo gruppo da verificare; non equivale a una persona identificata."
        tracks.append(Track(group: SpeakerAuditGroup(label: "Voce proposta \(tracks.count + 1)", clips: clips, caution: caution), vectors: vectors))
        return tracks.count - 1
    }
}
