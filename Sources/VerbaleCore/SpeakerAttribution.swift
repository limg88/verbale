import Foundation

public enum SpeakerAttributionState: Sendable { case assigned, recognized, uncertain, unidentified }
public struct SpeakerAttribution: Sendable {
    public var name: String
    public var state: SpeakerAttributionState
    public var detail: String
    public var profileID: UUID?
}
public extension Meeting {
    func attribution(for segment: Segment, learned: SpeakerAutomaticAssignment? = nil) -> SpeakerAttribution {
        let actual = speakerName(for:segment)
        if learned != nil { return SpeakerAttribution(name:actual,state:.recognized,detail:"Nome riconosciuto dai passaggi confermati. Puoi correggerlo dal menu.",profileID:nil) }
        let match = (voiceMatches ?? []).first { $0.segmentID == segment.id && $0.state != .rejected }
        if let match, match.state == .automatic {
            return SpeakerAttribution(name:actual,state:.recognized,detail:"Voce riconosciuta nel profilo di \(match.name).",profileID:match.profileID)
        }
        if let match, match.state == .confirmed { return SpeakerAttribution(name:actual,state:.assigned,detail:"Interlocutore confermato.",profileID:match.profileID) }
        if let id = segment.speakerID, let name = speakers[id], !name.isEmpty, name != id {
            return SpeakerAttribution(name:actual,state:.assigned,detail:"Nome assegnato manualmente.",profileID:nil)
        }
        if let match, match.state == .suggested { return SpeakerAttribution(name:match.name,state:.uncertain,detail:"Possibile \(match.name): conferma l’identità prima di considerarla certa. Il nome proposto non viene trattato come confermato nei file esportati.",profileID:match.profileID) }
        return SpeakerAttribution(name:actual,state:.unidentified,detail:"Identità non assegnata: puoi scegliere il nome dal menu o dall’editor.",profileID:nil)
    }
    mutating func changeTitle(_ value: String) throws {
        let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 160 else { throw VerbaleError.message("Inserisci un titolo da 1 a 160 caratteri.") }
        guard title != value else { return }
        title = value; invalidateReport()
    }
}
