import Foundation
import VerbaleCore

enum MeetingManagementChecks {
    static func run() async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VerbaleArchive-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            let store = try SessionStore(root:root.appendingPathComponent("sessions"))
            var meeting = Meeting(title:"Titolo iniziale",sources:[.system],destination:root,keepAudio:false)
            // Reproduce with: sh scripts/test.sh -AppleLocale 'th_TH@calendar=buddhist'
            let stamp = DateFormatter(); stamp.locale = Locale(identifier:"en_US_POSIX"); stamp.calendar = Calendar(identifier:.gregorian); stamp.dateFormat = "yyyy-MM-dd_HHmmss"
            try VoiceChecks.require(meeting.folderName.hasPrefix(stamp.string(from:meeting.started)+"_"),"export folder date depends on the system calendar: "+meeting.folderName)
            print("PASS export folder name uses a Gregorian ASCII date under any system locale")
            let damaged = store.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:damaged,withIntermediateDirectories:true)
            try Data("{ not json".utf8).write(to:damaged.appendingPathComponent("meeting.json"))
            try VoiceChecks.require(store.unreadableSessions().map(\.lastPathComponent) == [damaged.lastPathComponent],"damaged manifest not reported")
            try VoiceChecks.require(try store.list().isEmpty,"damaged manifest listed")
            try FileManager.default.removeItem(at:damaged)
            print("PASS an undecodable meeting manifest is reported instead of silently vanishing")
            meeting.segments = [Segment(source:.system,start:1,end:5,text:"Passaggio di prova",speakerID:"speaker-1")]
            meeting.state = .complete; try store.save(meeting); meeting = try store.export(meeting)
            let exportedManifest = try JSONCoding.decoder().decode(Meeting.self,from:Data(contentsOf:root.appendingPathComponent(meeting.folderName).appendingPathComponent("meeting.json")))
            try VoiceChecks.require(exportedManifest.destination.isEmpty && exportedManifest.id == meeting.id,"exported manifest carries an absolute path")
            try VoiceChecks.require(try store.read(meeting.id).destination == root.path,"internal manifest lost its destination")
            print("PASS exported manifest is portable while the internal one keeps the destination")
            // A separate store and destination: the archive assertions below count the meetings in `store`.
            let audioStore = try SessionStore(root:root.appendingPathComponent("audio-sessions")), audioOut = root.appendingPathComponent("audio-out")
            try FileManager.default.createDirectory(at:audioOut,withIntermediateDirectories:true)
            var audible = Meeting(title:"Audio unico",sources:[.system],destination:audioOut,keepAudio:true)
            // Two chunks with a one-second hole between them: the hole must become silence.
            for (index,start) in [0.0,2.0].enumerated() {
                let chunk = AudioChunk(source:.system,start:start,sampleCount:16000,filename:"audio/system_\(index).caf")
                try FileManager.default.createDirectory(at:audioStore.workspace(audible.id).appendingPathComponent("audio"),withIntermediateDirectories:true)
                try AudioFiles.write([Float](repeating:index == 0 ? 0.25 : -0.25,count:16000),to:audioStore.workspace(audible.id).appendingPathComponent(chunk.filename))
                audible.chunks.append(chunk)
            }
            audible.state = .recording; try audioStore.save(audible); audible = try audioStore.export(audible)
            let wav = audioOut.appendingPathComponent(audible.folderName).appendingPathComponent("audio/sistema.wav")
            try VoiceChecks.require(!FileManager.default.fileExists(atPath:wav.path),"playable audio written while still recording")
            audible.state = .complete; audible = try audioStore.export(audible)
            let bytes = try Data(contentsOf:wav), played = try AudioFiles.samples(wav)
            try VoiceChecks.require(bytes.count == 44 + 48000*2 && String(decoding:bytes.prefix(4),as:UTF8.self) == "RIFF","unexpected WAV size or header: \(bytes.count)")
            try VoiceChecks.require(played.count == 48000 && abs(played[8000]-0.25) < 0.01 && abs(played[24000]) < 0.001 && abs(played[40000]+0.25) < 0.01,"WAV timeline does not match the chunks")
            try VoiceChecks.require(FileManager.default.fileExists(atPath:audioOut.appendingPathComponent(audible.folderName).appendingPathComponent("audio/system_0.caf").path),"chunk files must stay")
            print("PASS export adds one playable WAV per source with gaps as silence, keeping the chunks")
            let id = meeting.id, folder = meeting.folderName
            try meeting.changeTitle("  Titolo aggiornato  "); try store.save(meeting); meeting = try store.export(meeting)
            try VoiceChecks.require(meeting.id == id && meeting.folderName == folder && meeting.title == "Titolo aggiornato","title changed identity or folder")
            try VoiceChecks.require(try String(contentsOf:root.appendingPathComponent(folder).appendingPathComponent("transcript.md")).contains("Titolo aggiornato"),"export title not updated")
            try VoiceChecks.refuses { try meeting.changeTitle(" \n ") }
            try VoiceChecks.refuses { try meeting.changeTitle(String(repeating:"x",count:161)) }
            let other = Meeting(title:"Conserva",sources:[.system],destination:root,keepAudio:false); try store.save(other)
            let trashed = try store.trashWorkspace(id,testingTrash:root.appendingPathComponent("trash"))
            try VoiceChecks.require(try store.list().map(\.id) == [other.id],"removed meeting remains listed or other removed")
            try VoiceChecks.require(FileManager.default.fileExists(atPath:trashed.appendingPathComponent("meeting.json").path) && FileManager.default.fileExists(atPath:root.appendingPathComponent(folder).appendingPathComponent("transcript.md").path),"trash lost recovery or export")
            try FileManager.default.moveItem(at:trashed,to:store.workspace(id))
            try VoiceChecks.require(try store.read(id).title == "Titolo aggiornato","trash recovery failed")
            print("PASS meeting title, export, reversible archive removal")
            let segment = meeting.segments[0], ranking = VoiceRanking(profileID:UUID(),name:"Ada",score:0.92,margin:0.24)
            meeting.applyVoiceGroup([segment.id],ranking:ranking,automatic:false)
            try VoiceChecks.require(meeting.attribution(for:segment).state == .uncertain && meeting.attribution(for:segment).name == "Ada" && meeting.speakerName(for:segment) != "Ada","uncertain proposal became a confirmed export name")
            meeting.applyVoiceGroup([segment.id],ranking:ranking,automatic:true)
            let assigned = meeting.segments[0]
            try VoiceChecks.require(meeting.attribution(for:assigned).state == .recognized && meeting.speakerName(for:assigned) == "Ada","strong recognition did not attach name")
            try meeting.correctSegment(assigned.id,text:assigned.text,speakerID:"manual-test"); meeting.speakers["manual-test"] = "Bea"
            try VoiceChecks.require(meeting.attribution(for:meeting.segments[0]).state == .assigned && meeting.attribution(for:meeting.segments[0]).name == "Bea","manual correction did not override recognition")
            print("PASS speaker recognition, uncertainty and manual override presentation")
            return 0
        } catch { print("FAIL archive/attribution: \(error)"); return 1 }
    }
}
