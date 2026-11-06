import Foundation

public struct VoiceEncoderID: Codable, Equatable, Sendable {
    public var identity: String
    public var family: String
    public var dimension: Int
    public init(identity: String, family: String, dimension: Int) { self.identity = identity; self.family = family; self.dimension = dimension }
}
public struct VoiceClip: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var meetingID: UUID
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var duration: Double { end - start }
    public init(meetingID: UUID, source: AudioSource, start: Double, end: Double, text: String) { self.meetingID = meetingID; self.source = source; self.start = start; self.end = end; self.text = text }
}
public struct VoiceSample: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var created = Date()
    public var clip: VoiceClip
    public var embedding: [Float]
    public init(clip: VoiceClip, embedding: [Float]) { self.clip = clip; self.embedding = embedding }
}
public struct VoiceProfile: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var created = Date()
    public var enabled = true
    public var encoder: VoiceEncoderID
    public var samples: [VoiceSample]
    /// A model disagreement is not proof of different people. Keep explicit enrollment, require confirmation of future matches.
    public var needsMatchConfirmation: Bool {
        guard samples.count >= 2 else { return true }
        guard let vectors = try? samples.map({ try VoiceVectors.normalized($0.embedding, dimension: encoder.dimension) }) else { return true }
        for a in vectors.indices { for b in vectors.indices where b > a {
            if zip(vectors[a], vectors[b]).reduce(0.0, { $0 + Double($1.0) * Double($1.1) }) < 0.50 { return true }
        } }
        return false
    }
}
public enum VoiceMatchState: String, Codable, Sendable { case automatic, suggested, confirmed, rejected }
public struct VoiceMatch: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var segmentID: UUID
    public var profileID: UUID
    public var name: String
    public var state: VoiceMatchState
    public var score: Double
    public var margin: Double
    public var originalSpeakerID: String?
}
public struct VoiceRanking: Sendable {
    public var profileID: UUID
    public var name: String
    public var score: Double
    public var margin: Double
    public var automaticAllowed: Bool
    public init(profileID: UUID, name: String, score: Double, margin: Double, automaticAllowed: Bool = true) { self.profileID = profileID; self.name = name; self.score = score; self.margin = margin; self.automaticAllowed = automaticAllowed }
    public var strong: Bool { automaticAllowed && score >= 0.80 && margin >= 0.15 }
}
public enum VoiceVectors {
    public static func normalized(_ vector: [Float], dimension: Int) throws -> [Float] {
        guard dimension > 0, dimension <= 4096, vector.count == dimension, vector.allSatisfy(\.isFinite) else { throw VerbaleError.message("Profilo vocale non valido o incompatibile con il modello.") }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { throw VerbaleError.message("Il campione non contiene un profilo vocale utilizzabile.") }
        return vector.map { Float(Double($0) / norm) }
    }
    public static func rank(_ embedding: [Float], encoder: VoiceEncoderID, profiles: [VoiceProfile]) throws -> VoiceRanking? {
        let vector = try normalized(embedding, dimension: encoder.dimension)
        let scores = try profiles.filter { $0.enabled && $0.encoder == encoder && !$0.samples.isEmpty }.compactMap { profile -> (VoiceProfile, Double)? in
            var average = [Float](repeating: 0, count: encoder.dimension)
            for sample in profile.samples {
                let normalized = try normalized(sample.embedding, dimension: encoder.dimension)
                for i in average.indices { average[i] += normalized[i] / Float(profile.samples.count) }
            }
            guard let center = try? normalized(average, dimension: encoder.dimension) else { return nil }
            let score = zip(vector, center).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            return (profile, min(1, max(-1, score)))
        }.sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= 0.55 else { return nil }
        let margin = best.1 - (scores.dropFirst().first?.1 ?? 0)
        guard margin >= 0.05 else { return nil }
        return VoiceRanking(profileID: best.0.id, name: best.0.name, score: best.1, margin: margin, automaticAllowed: !best.0.needsMatchConfirmation)
    }
}
/// Main coordinator owns this store; embeddings never enter Meeting or its exports.
public final class VoiceProfileStore {
    public let directory: URL
    public private(set) var profiles: [VoiceProfile]
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("profiles.json")
        profiles = FileManager.default.fileExists(atPath: file.path) ? try JSONCoding.decoder().decode([VoiceProfile].self, from: Data(contentsOf: file)) : []
        guard Set(profiles.map(\.id)).count == profiles.count, Set(profiles.map { $0.name.lowercased() }).count == profiles.count else { throw VerbaleError.message("Archivio profili vocali con duplicati: nessun profilo è stato caricato.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        for p in profiles {
            guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (2...12).contains(p.samples.count) else { throw VerbaleError.message("Archivio profili vocali non valido.") }
            for s in p.samples { _ = try VoiceVectors.normalized(s.embedding, dimension: p.encoder.dimension) }
        }
    }
    private func commit(_ next: [VoiceProfile]) throws {
        let file = directory.appendingPathComponent("profiles.json")
        try JSONCoding.encoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        profiles = next
    }
    @discardableResult public func enroll(name: String, samples: [VoiceSample], encoder: VoiceEncoderID, existing: UUID? = nil) throws -> VoiceProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (existing != nil || (!name.isEmpty && name.count <= 100)), samples.count >= 2, samples.count <= 6,
              samples.allSatisfy({ (3...8.1).contains($0.clip.duration) }),
              Set(samples.map(\.clip.id)).count == samples.count else { throw VerbaleError.message("Conferma almeno due campioni distinti di 3–8 secondi e assegna un nome al profilo.") }
        for sample in samples { _ = try VoiceVectors.normalized(sample.embedding, dimension: encoder.dimension) }
        for a in samples.indices { for b in samples.indices where b > a {
            let x = samples[a].clip, y = samples[b].clip
            guard x.meetingID != y.meetingID || x.source != y.source || min(x.end, y.end) <= max(x.start, y.start) + 0.01 else { throw VerbaleError.message("I campioni selezionati si sovrappongono. Scegli passaggi distinti.") }
        } }
        var next = profiles
        if let existing {
            guard let i = next.firstIndex(where: { $0.id == existing }), next[i].encoder == encoder else { throw VerbaleError.message("Il profilo esistente non è compatibile con questo modello.") }
            guard next[i].samples.count + samples.count <= 12 else { throw VerbaleError.message("Il profilo contiene già abbastanza campioni. Rimuovilo e ricrealo per sostituirli.") }
            for old in next[i].samples { for new in samples {
                let x = old.clip, y = new.clip
                guard x.meetingID != y.meetingID || x.source != y.source || min(x.end, y.end) <= max(x.start, y.start) + 0.01 else { throw VerbaleError.message("Questi passaggi sono già presenti nel profilo. Aggiungi campioni diversi.") }
            } }
            next[i].samples += samples
            try commit(next); return next[i]
        }
        guard !profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw VerbaleError.message("Esiste già un profilo con questo nome. Scegli Aggiungi a un profilo esistente.") }
        let profile = VoiceProfile(name: name, encoder: encoder, samples: samples)
        next.append(profile); try commit(next); return profile
    }
    public func rename(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !profiles.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }), let i = profiles.firstIndex(where: { $0.id == id }) else { throw VerbaleError.message("Nome non valido o già utilizzato.") }
        var next = profiles; next[i].name = name; try commit(next)
    }
    public func remove(_ id: UUID) throws { try commit(profiles.filter { $0.id != id }) }
    public func setEnabled(_ id: UUID, _ enabled: Bool) throws { var next = profiles; guard let i = next.firstIndex(where: { $0.id == id }) else { return }; next[i].enabled = enabled; try commit(next) }
}

public enum VoiceClips {
    public static func candidates(meeting: Meeting, speakerID: String?, source: AudioSource, selected: UUID? = nil, maximum: Int = 8, segmentIDs: Set<UUID>? = nil) -> [VoiceClip] {
        let segments = meeting.segments.filter { $0.source == source && (segmentIDs == nil || segmentIDs!.contains($0.id)) && (speakerID == nil || $0.speakerID == speakerID) }
            .sorted { a, b in a.id == b.id ? false : a.id == selected ? true : b.id == selected ? false : a.start < b.start }
        var clips: [VoiceClip] = []
        for segment in segments where segment.end - segment.start >= 3.2 {
            var spans: [(Double, Double)] = [(segment.start, segment.end)]
            for other in meeting.segments where ((other.source == source && other.id != segment.id && other.speakerID != segment.speakerID) || (source == .microphone && meeting.usesEchoCancellation && other.source == .system)) && other.start < segment.end && other.end > segment.start {
                spans = spans.flatMap { a, b -> [(Double, Double)] in
                    if other.end <= a || other.start >= b { return [(a,b)] }
                    return [(a,min(b,other.start)),(max(a,other.end),b)].filter { $0.1 > $0.0 }
                }
            }
            for (start, end) in spans {
                var cursor = start + 0.1
                while end - 0.1 - cursor >= 3 {
                    let until = min(end - 0.1, cursor + 6)
                    let clip = VoiceClip(meetingID: meeting.id, source: source, start: cursor, end: until, text: segment.text)
                    if !clips.contains(where: { $0.source == source && min($0.end,clip.end) > max($0.start,clip.start) }) { clips.append(clip) }
                    if clips.count >= maximum { return clips }
                    cursor = until + 0.2
                }
            }
        }
        return clips
    }
}
public extension Meeting {
    /// A fresh analysis may replace predictions, but never explicit confirmations.
    func preparingVoiceAnalysis(learning: SpeakerAudit? = nil) throws -> Meeting {
        var input = self
        // Learning predictions have separate provenance. A stale sidecar may only
        // retract matching predictions; it is never reused as a source of proposals.
        if var learning, learning.meetingID == id { try learning.retractAutomatic(in:&input) }
        for match in input.voiceMatches ?? [] where match.state == .automatic {
            if let i = input.segments.firstIndex(where: { $0.id == match.segmentID }), !input.corrections.contains(where: { $0.segmentID == match.segmentID }) { input.segments[i].speakerID = match.originalSpeakerID }
        }
        input.voiceMatches?.removeAll { $0.state == .automatic || $0.state == .suggested }
        return input
    }
    /// Explicit user assignment: preserve the diarization slot, and never group all unnamed passages.
    mutating func assignVoiceName(_ name: String, to segmentID: UUID) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let selected = segments.first(where: { $0.id == segmentID }) else { throw VerbaleError.message("Il passaggio non è più disponibile o manca il nome della persona.") }
        let ids: Set<UUID>
        if let speakerID = selected.speakerID {
            ids = Set(segments.filter { $0.source == selected.source && $0.speakerID == speakerID }.map(\.id))
            // Speaker display names are global keys: give the selected source its own key if necessary.
            if segments.contains(where: { $0.source != selected.source && $0.speakerID == speakerID }) {
                let key = "manual-" + UUID().uuidString
                for i in segments.indices where ids.contains(segments[i].id) { segments[i].speakerID = key }
                speakers[key] = name
            } else { speakers[speakerID] = name }
        } else {
            ids = [segmentID]
            let key = "manual-" + UUID().uuidString
            if let i = segments.firstIndex(where: { $0.id == segmentID }) { segments[i].speakerID = key }
            speakers[key] = name
        }
        voiceMatches?.removeAll { ids.contains($0.segmentID) }
        invalidateReport()
    }
    var voiceProtectedSegments: Set<UUID> {
        let rejected = Set((voiceMatches ?? []).filter { $0.state == .rejected }.map(\.segmentID))
        let previouslyAutomatic = Set((voiceMatches ?? []).filter { $0.state == .automatic }.map(\.segmentID))
        return rejected.union(corrections.map(\.segmentID)).union(segments.filter { segment in
            guard let id = segment.speakerID else { return false }
            return id.hasPrefix("manual-") || (speakers[id] != nil && !previouslyAutomatic.contains(segment.id))
        }.map(\.id))
    }
    mutating func applyVoiceGroup(_ ids: Set<UUID>, ranking: VoiceRanking, automatic: Bool) {
        let protected = voiceProtectedSegments
        for i in segments.indices where ids.contains(segments[i].id) && !protected.contains(segments[i].id) {
            let original = (voiceMatches ?? []).first { $0.segmentID == segments[i].id && $0.state == .automatic }.map { $0.originalSpeakerID } ?? segments[i].speakerID
            voiceMatches = (voiceMatches ?? []).filter { $0.segmentID != segments[i].id }
            voiceMatches?.append(VoiceMatch(segmentID: segments[i].id, profileID: ranking.profileID, name: ranking.name, state: automatic ? .automatic : .suggested, score: ranking.score, margin: ranking.margin, originalSpeakerID: original))
            if automatic {
                let key = "voice-" + ranking.profileID.uuidString
                segments[i].speakerID = key; speakers[key] = ranking.name
            }
        }
        invalidateReport()
    }
    private var voiceIdentityProtectedSegments:Set<UUID> {
        var identity = self
        identity.review?.corrections.removeAll { $0.previousSpeakerID == $0.speakerID }
        return identity.voiceProtectedSegments
    }
    mutating func confirmVoice(_ profileID: UUID) {
        guard let matches = voiceMatches else { return }
        let protected = voiceIdentityProtectedSegments
        var segmentIndex:[UUID:Int]=[:],matchIndex:[UUID:Int]=[:]
        for (i,segment) in segments.enumerated() where segmentIndex[segment.id] == nil {segmentIndex[segment.id]=i}
        for (i,match) in matches.enumerated() where matchIndex[match.id] == nil {matchIndex[match.id]=i}
        let key="voice-"+profileID.uuidString
        for match in matches where match.profileID == profileID && match.state != .rejected && !protected.contains(match.segmentID) {
            guard let i=segmentIndex[match.segmentID],let m=matchIndex[match.id] else {continue}
            segments[i].speakerID=key;speakers[key]=match.name;voiceMatches?[m].state = .confirmed
        }
        invalidateReport()
    }
    mutating func rejectVoice(_ profileID: UUID) {
        let protected = voiceIdentityProtectedSegments,matches=voiceMatches ?? []
        var segmentIndex:[UUID:Int]=[:],matchIndex:[UUID:Int]=[:]
        for (i,segment) in segments.enumerated() where segmentIndex[segment.id] == nil {segmentIndex[segment.id]=i}
        for (i,match) in matches.enumerated() where matchIndex[match.id] == nil {matchIndex[match.id]=i}
        let key="voice-"+profileID.uuidString
        for match in matches where match.profileID == profileID && match.state != .confirmed && !protected.contains(match.segmentID) {
            if let i=segmentIndex[match.segmentID],segments[i].speakerID==key {segments[i].speakerID=match.originalSpeakerID}
            if let i=matchIndex[match.id] {voiceMatches?[i].state = .rejected}
        }
        invalidateReport()
    }
}
