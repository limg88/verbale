import Foundation
import VerbaleCore

enum SpeakerGroupChecks {
    static func run() -> Int {
        do {
            var meeting = Meeting(title:"Speaker list",sources:[.system,.microphone],destination:FileManager.default.temporaryDirectory,keepAudio:false)
            let keys = ["manual-audit-a","auto-learn-b","voice-c","Microfono 1","Interlocutore 2","Interlocutore 3"]
            meeting.segments = keys.enumerated().map { i,key in Segment(source:i == 3 ? .microphone:.system,start:Double(20-i*2),end:Double(21-i*2),text:"Passaggio \(i)",speakerID:key) }
            meeting.speakers = [keys[0]:"Cristian Lena",keys[1]:"Cristian Lena",keys[2]:"Cristian Lena",keys[3]:" cristian lena ","unused":"Persona assente"]
            let originalIDs = meeting.segments.map(\.speakerID), originalTimes = meeting.segments.map(\.start)
            let named = meeting.speakerGroups.filter { $0.speakerIDs.count > 1 }
            try VoiceChecks.require(meeting.speakerGroups.count == 3 && named.count == 1 && named[0].speakerIDs.count == 4,"same person not grouped or anonymous slots merged")
            let reversed = meeting.segments.reversed(); var reordered = meeting; reordered.segments = Array(reversed)
            try VoiceChecks.require(reordered.speakerGroups.map(\.id) == meeting.speakerGroups.map(\.id),"speaker rows depend on storage order")
            try VoiceChecks.require(meeting.firstSegment(forSpeaker:keys[0])?.id == meeting.segments[3].id,"navigation ignored other slots or sources of the person")
            let rank = VoiceRanking(profileID:UUID(),name:"Cristian Lena",score:0.65,margin:0.1)
            meeting.applyVoiceGroup([meeting.segments[4].id],ranking:rank,automatic:false)
            try VoiceChecks.require(meeting.speakerGroups.count == 3 && meeting.attribution(for:meeting.segments[4]).state == .uncertain,"uncertain proposal became part of a named person")
            try meeting.renameSpeakerPerson(keys[1],to:"Nome corretto")
            try VoiceChecks.require(keys.prefix(4).allSatisfy { meeting.speakers[$0] == "Nome corretto" },"rename only updated the representative slot")
            try VoiceChecks.require(meeting.segments.map(\.speakerID) == originalIDs && meeting.segments.map(\.start) == originalTimes && meeting.corrections.isEmpty,"grouping merged storage or rewrote correction history")
            try VoiceChecks.require(meeting.speakers["unused"] == "Persona assente" && meeting.speakers[keys[4]] == nil && meeting.voiceMatches?.first?.state == .suggested,"rename affected absent, anonymous or proposed identities")
            try VoiceChecks.refuses { try meeting.renameSpeakerPerson("missing",to:"Wrong") }
            try VoiceChecks.refuses { try meeting.renameSpeakerPerson(keys[0],to:"") }
            print("PASS unique speaker rows, anonymous separation and cross-source navigation")
            print("PASS person rename updates all slots without merging history or predictions")
            if let path = ProcessInfo.processInfo.environment["VERBALE_TEST_SPEAKER_MEETING"] {
                let url = URL(fileURLWithPath:path), before = try Data(contentsOf:url)
                var real = try JSONCoding.decoder().decode(Meeting.self,from:before)
                let all = real.speakerGroups, ids = Set(real.segments.compactMap(\.speakerID))
                try VoiceChecks.require(all.reduce(0) { $0+$1.speakerIDs.count } == ids.count,"real meeting grouping lost speaker slots")
                let combined = all.filter { $0.speakerIDs.count > 1 }
                try VoiceChecks.require(!combined.isEmpty,"real meeting fixture contains no duplicate identities")
                if let person = combined.first {
                    let idsBefore = real.segments.map(\.speakerID)
                    try real.renameSpeakerPerson(person.representativeID,to:"Persona di test")
                    try VoiceChecks.require(person.speakerIDs.allSatisfy { real.speakers[$0] == "Persona di test" } && real.segments.map(\.speakerID) == idsBefore,"real meeting rename lost group membership")
                }
                try VoiceChecks.require(try Data(contentsOf:url) == before,"real meeting manifest changed")
                print("PASS real meeting speaker list: \(ids.count) slots → \(all.count) visible people/anonymous groups; source unchanged")
            }
            return 0
        } catch { print("FAIL speaker grouping: \(error)");return 1 }
    }
}
