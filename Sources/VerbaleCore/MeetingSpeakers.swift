import Foundation

/// One visible person, with separate underlying slots and assignment provenance.
public struct MeetingSpeaker: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let speakerIDs: Set<String>
    public let representativeID: String
}
public extension Meeting {
    private func personKey(_ name:String) -> String {
        name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"it_IT"))
    }
    var speakerGroups: [MeetingSpeaker] {
        var members:[String:Set<String>] = [:], labels:[String:String] = [:]
        // Sorting gives a stable representative regardless of transcript storage order.
        for key in Set(segments.compactMap(\.speakerID)).sorted() {
            let assigned = speakers[key]?.trimmingCharacters(in:.whitespacesAndNewlines)
            let named = assigned.map { !$0.isEmpty && $0 != key } ?? false
            let identity = named ? "person:"+personKey(assigned!) : "slot:"+key
            members[identity,default:[]].insert(key)
            if labels[identity] == nil { labels[identity] = named ? assigned! : key }
        }
        return members.map { key,ids in
            MeetingSpeaker(id:id.uuidString+":"+key,name:labels[key]!,speakerIDs:ids,representativeID:ids.sorted().first!)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    func firstSegment(forSpeaker key:String) -> Segment? {
        let ids = speakerGroups.first { $0.speakerIDs.contains(key) }?.speakerIDs ?? [key]
        return segments.filter { $0.speakerID.map(ids.contains) == true }.min { a,b in
            a.start == b.start ? a.id.uuidString < b.id.uuidString : a.start < b.start
        }
    }
    /// Rename a visible person without merging slots, timestamps or history.
    @discardableResult mutating func renameSpeakerPerson(_ key:String,to value:String) throws -> Bool {
        let name = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw VerbaleError.message("Inserisci un nome da 1 a 100 caratteri.") }
        guard let group = speakerGroups.first(where: { $0.speakerIDs.contains(key) }) else { throw VerbaleError.message("L’interlocutore non è più presente nella riunione.") }
        guard group.speakerIDs.contains(where: { speakers[$0] != name }) else { return false }
        for id in group.speakerIDs { speakers[id] = name }
        let affected = Set(segments.filter { $0.speakerID.map(group.speakerIDs.contains) == true }.map(\.id))
        voiceMatches?.removeAll { affected.contains($0.segmentID) }
        invalidateReport()
        return true
    }
}
