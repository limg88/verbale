import Foundation
import VerbaleCore

enum ReviewExportChecks {
    static func run() -> Int {
        do {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("verbale-review-"+UUID().uuidString)
            defer{try? FileManager.default.removeItem(at:root)}
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let store=try SessionStore(root:root.appendingPathComponent("private"))
            var meeting=Meeting(title:"Review",sources:[.system],destination:root,keepAudio:true)
            meeting.state = .complete
            meeting.segments=[Segment(source:.system,start:0,end:1,text:"Originale")]
            try store.save(meeting)
            let chunk=AudioChunk(source:.system,start:0,sampleCount:160,filename:"audio/one.caf")
            meeting.chunks=[chunk]
            try AudioFiles.write([Float](repeating:0.1,count:160),to:store.workspace(meeting.id).appendingPathComponent(chunk.filename))
            meeting=try store.export(meeting)
            let output=root.appendingPathComponent(meeting.folderName)
            let transcript=output.appendingPathComponent("transcript.md"),audio=output.appendingPathComponent(chunk.filename)
            func inode(_ path:URL)throws->UInt64 {(try FileManager.default.attributesOfItem(atPath:path.path)[.systemFileNumber] as! NSNumber).uint64Value}
            let originalTranscript=try inode(transcript),originalAudio=try inode(audio)
            meeting.notes="Nuove note";meeting.invalidateReport();try store.save(meeting)
            meeting=try store.export(meeting,documentsOnly:true)
            guard try inode(transcript)==originalTranscript,try inode(audio)==originalAudio,
                  try String(contentsOf:output.appendingPathComponent("notes.md"),encoding:.utf8)=="Nuove note",
                  try store.read(meeting.id).exported else{throw VerbaleError.message("export riscrive file invariati")}
            // Missing attachments must be repaired even by a review-only export.
            try FileManager.default.removeItem(at:audio)
            meeting=try store.export(meeting,documentsOnly:true)
            guard FileManager.default.fileExists(atPath:audio.path) else{throw VerbaleError.message("allegato mancante non recuperato")}
            let next=AudioChunk(source:.system,start:1,sampleCount:160,filename:"audio/two.caf")
            try AudioFiles.write([Float](repeating:0.2,count:160),to:store.workspace(meeting.id).appendingPathComponent(next.filename))
            meeting.chunks.append(next)
            meeting=try store.export(meeting,documentsOnly:true)
            guard FileManager.default.fileExists(atPath:output.appendingPathComponent(next.filename).path) else{throw VerbaleError.message("nuovo allegato ignorato")}
            // Ordinary exports retain full integrity verification.
            try Data("corrupted".utf8).write(to:audio)
            do {_=try store.export(meeting);throw NSError(domain:"accepted-corrupt-audio",code:1)} catch is VerbaleError {}
            var voices=meeting
            let ranking=VoiceRanking(profileID:UUID(),name:"Persona",score:0.9,margin:0.2)
            voices.applyVoiceGroup(Set(voices.segments.map(\.id)),ranking:ranking,automatic:true)
            if let match=voices.voiceMatches?.first {
                var rejected=match;rejected.state = .rejected
                voices.voiceMatches?.insert(rejected,at:0)
            }
            let index=TranscriptIndex(voices)
            for segment in voices.segments {
                let old=voices.attribution(for:segment),indexed=voices.attribution(for:segment,match:index.matches[segment.id])
                guard old.name==indexed.name,old.state==indexed.state,old.profileID==indexed.profileID else{throw VerbaleError.message("indice cambia attribuzione")}
            }
            print("PASS transcript index preserves attribution with rejected duplicate matches")
            print("PASS review exports preserve unchanged documents and recover attachments")
            return 0
        } catch {print("FAIL review exports: \(error)");return 1}
    }
}
