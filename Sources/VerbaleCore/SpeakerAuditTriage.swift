import Foundation

public struct SpeakerAuditCase: Identifiable, Sendable {
    public var id: UUID { groupID }
    public let groupID: UUID
    public let title: String
    public let detail: String
    public let examples: [SpeakerAuditPiece]
    public let referenceIDs: Set<UUID>
    public let priority: Double
    public let bucket: String
}
public struct SpeakerAuditTriage: Sendable {
    public let cases: [SpeakerAuditCase]
    public let eligibleCount: Int
    public let remainingPeopleCount: Int
    public let deferredCount: Int
    public let reviewedCount: Int
    public init(audit: SpeakerAudit, meeting: Meeting, limit: Int = 5) {
        let originals = Dictionary(audit.originalSegments.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: audit.pieces.filter { !audit.applied.contains($0.id) }, by: { $0.groupID })
        let reviewed = audit.reviewedGroups ?? []
        var primary: [String:(UUID,Double,SpeakerAuditPiece)] = [:]
        for group in audit.groups where group.clips.count >= 2 {
            let pieces = groups[group.id] ?? []
            var named: [String:Double] = [:]
            for piece in pieces {
                if let key = originals[piece.originalID]?.speakerID.flatMap({ meeting.speakers[$0] }), !key.isEmpty { named[key,default:0] += max(0,piece.segment.end-piece.segment.start) }
            }
            if let main = named.sorted(by: { a,b in a.value == b.value ? a.key < b.key : a.value > b.value }).first, let example = pieces.filter({ originals[$0.originalID]?.speakerID.flatMap { meeting.speakers[$0] } == main.key }).max(by: { $0.segment.end-$0.segment.start < $1.segment.end-$1.segment.start }) {
                if main.value > (primary[main.key]?.1 ?? 0) { primary[main.key] = (group.id,main.value,example) }
            }
        }
        var candidates: [SpeakerAuditCase] = []
        for group in audit.groups where !reviewed.contains(group.id) {
            let pieces = groups[group.id] ?? []
            // The quick review requires usable exemplars and sustained evidence, not tiny slot fragments.
            guard group.clips.count >= 2 else { continue }
            var durations: [String:Double] = [:]
            for piece in pieces {
                let original = originals[piece.originalID]
                let key = original?.speakerID.flatMap { meeting.speakers[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? ""
                durations[key,default:0] += max(0,piece.segment.end-piece.segment.start)
            }
            let total = durations.values.reduce(0,+), unknown = durations[""] ?? 0
            let named = durations.filter { !$0.key.isEmpty }.sorted { a,b in a.value == b.value ? a.key < b.key : a.value > b.value }
            let main = named.first, namedTotal = total-unknown
            let minority = max(0,namedTotal-(main?.value ?? 0))
            let conflictingNames = minority >= max(5,namedTotal*0.20)
            let unresolved = unknown >= max(5,total*0.25)
            let bucket = main?.key ?? ""
            guard !(audit.reviewedBuckets ?? []).contains(bucket) else { continue }
            let alternate = !bucket.isEmpty && primary[bucket]?.0 != group.id && (main?.value ?? 0) >= 15
            guard total >= 12, conflictingNames || unresolved || alternate else { continue }
            let suspect = pieces.filter { piece in
                let key = originals[piece.originalID]?.speakerID.flatMap { meeting.speakers[$0] } ?? ""
                return key.isEmpty || (conflictingNames && key != bucket) || alternate
            }
            // Spread examples instead of offering many almost identical fragments at the same timestamp.
            var examples: [SpeakerAuditPiece] = []
            for piece in suspect.sorted(by: { a,b in
                let ad = a.segment.end-a.segment.start, bd = b.segment.end-b.segment.start
                return ad == bd ? a.segment.start < b.segment.start : ad > bd
            }) where !examples.contains(where: { $0.segment.source == piece.segment.source && abs($0.segment.start-piece.segment.start) < 8 }) {
                examples.append(piece); if examples.count == 3 { break }
            }
            guard !examples.isEmpty else { continue }
            let title = bucket.isEmpty ? "Passaggi senza nome" : "Verifica \(bucket)"
            var referenceIDs = Set<UUID>()
            if alternate, let reference = primary[bucket]?.2 {
                examples = [reference] + Array(examples.prefix(2)); referenceIDs.insert(reference.id)
            }
            let detail = alternate ? "Confronta il riferimento con gli altri estratti che hanno lo stesso nome. La differenza potrebbe dipendere dalla registrazione oppure da persone accorpate." : conflictingNames ? "La stessa voce proposta attraversa passaggi con nomi diversi. Potrebbe esserci un’assegnazione da correggere." : "Questo gruppo include passaggi ancora senza nome. Ascolta per capire se appartengono a una persona già assegnata."
            candidates.append(SpeakerAuditCase(groupID:group.id,title:title,detail:detail,examples:examples,referenceIDs:referenceIDs,priority:min(unknown,60)+min(minority,60)*1.5+(alternate ? min(main?.value ?? 0,60)*0.4 : 0),bucket:bucket))
        }
        candidates.sort { $0.priority == $1.priority ? $0.groupID.uuidString < $1.groupID.uuidString : $0.priority > $1.priority }
        var chosen: [SpeakerAuditCase] = [], seen = Set<String>()
        for candidate in candidates where chosen.count < max(0,limit) {
            if seen.insert(candidate.bucket).inserted { chosen.append(candidate) }
        }
        // Do not fill the batch with repetitions of the same already-assigned person.
        cases = chosen; eligibleCount = candidates.count; remainingPeopleCount = Set(candidates.map(\.bucket)).count; deferredCount = max(0,audit.groups.count-candidates.count-reviewed.count); reviewedCount = (audit.reviewedBuckets ?? []).count
    }
}
