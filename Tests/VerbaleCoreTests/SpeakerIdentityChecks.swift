import Foundation
import VerbaleCore

enum SpeakerIdentityChecks {
    static func run() -> Int {
        do {
            var meeting = Meeting(title:"Reserved identities",sources:[.system],destination:FileManager.default.temporaryDirectory,keepAudio:false)
            let named = Segment(source:.system,start:0,end:2,text:"Voce confermata",speakerID:"Interlocutore 1",words:[Word(w:"Voce confermata",start:0,end:2)])
            let unknown = Segment(source:.system,start:3,end:6,text:"Un’altra persona",words:[Word(w:"Un’altra persona",start:3,end:6)])
            meeting.segments = [named,unknown]; meeting.speakers["Interlocutore 1"] = "Persona confermata"
            let split = SpeakerDiarization.split(meeting.segments,regions:[SpeakerRegion(start:0,end:6,speaker:0)],protected:meeting.voiceProtectedSegments)
            meeting.applyDiarization(split)
            try VoiceChecks.require(meeting.speakerName(for:meeting.segments[0]) == "Persona confermata","manual name changed")
            try VoiceChecks.require(meeting.speakerName(for:meeting.segments[1]) != "Persona confermata","new local slot inherited a manually confirmed name")
            print("PASS reanalysis never aliases anonymous slots to confirmed identities")
            let anonymousID = meeting.segments[1].id
            let rank = VoiceRanking(profileID:UUID(),name:"Profilo automatico",score:0.95,margin:0.3)
            let originalSlot = meeting.segments[1].speakerID
            meeting.applyVoiceGroup([anonymousID],ranking:rank,automatic:true)
            let prepared = try meeting.preparingVoiceAnalysis()
            try VoiceChecks.require(prepared.segments[1].speakerID == originalSlot && prepared.voiceMatches?.isEmpty == true,"rerun kept previous automatic name")
            try VoiceChecks.require(prepared.speakers[prepared.segments[0].speakerID!] == "Persona confermata","rerun lost manually named slot")
            meeting.confirmVoice(rank.profileID)
            let confirmed = try meeting.preparingVoiceAnalysis()
            try VoiceChecks.require(confirmed.speakerName(for:confirmed.segments[1]) == rank.name && confirmed.voiceMatches?.first?.state == .confirmed,"rerun reset explicit profile confirmation")
            print("PASS reanalysis resets predictions and preserves profile confirmations")
            return 0
        } catch { print("FAIL speaker identity isolation: \(error)"); return 1 }
    }
}
