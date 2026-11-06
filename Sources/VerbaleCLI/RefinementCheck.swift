import Foundation
import VerbaleCore

enum RefinementCheck {
    static func run(input:URL,asr:URL,vad:URL,output:URL,start:Double,end:Double,source:AudioSource = .system) async throws {
        guard !FileManager.default.fileExists(atPath:output.path),start.isFinite,end.isFinite,start >= 0,end > start else { throw VerbaleError.message("Intervallo o cartella non validi.") }
        let before = try Data(contentsOf:input),original = try JSONCoding.decoder().decode(Meeting.self,from:before)
        let selected = Set(original.segments.filter { $0.source == source && $0.start >= start && $0.start < end }.map(\.id))
        guard !selected.isEmpty else { throw VerbaleError.message("Nessun passaggio nell’intervallo.") }
        let audio = VoiceAudio(workspace:input.deletingLastPathComponent(),exported:URL(fileURLWithPath:original.destination).appendingPathComponent(original.folderName))
        var hashes:[String:String] = [:]
        for chunk in original.chunks where chunk.source == source {
            let url = try audio.url(audio.filename(chunk,meeting:original));hashes[url.path] = try ModelManager.digest(url)
        }
        let engine = TranscriptionEngine(),began = Date();try await engine.load(asr:asr,vad:vad)
        var draft:TranscriptRefinement
        do { draft = try await engine.refine(meeting:original,audio:audio,scope:.all,selected:selected,progress: { text in FileHandle.standardError.write(Data((text+"\n").utf8)) });await engine.unload() }
        catch { await engine.unload();throw error }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try draft.save(to:output.appendingPathComponent("proposals.json"))
        var checks:[String:Bool] = [:]
        checks["source manifest unchanged"] = try Data(contentsOf:input) == before
        checks["source audio unchanged"] = try hashes.allSatisfy { try ModelManager.digest(URL(fileURLWithPath:$0.key)) == $0.value }
        checks["preview leaves original transcript unchanged"] = draft.isCurrent(for:original)
        checks["manual text corrections excluded"] = draft.proposals.allSatisfy { proposal in !original.corrections.contains { $0.segmentID == proposal.id && $0.previousText != $0.text } }
        if let proposal = draft.proposals.first {
            var test = original;let previousSegments = try JSONCoding.encoder().encode(test.segments)
            try draft.apply([proposal.id],to:&test)
            checks["selective adoption preserves every speaker assignment"] = test.segments.map(\.speakerID) == original.segments.map(\.speakerID)
            checks["selective adoption preserves segment ids and times"] = zip(test.segments,original.segments).allSatisfy { $0.id == $1.id && $0.start == $1.start && $0.end == $1.end }
            try draft.undo(in:&test)
            checks["undo restores all original words and alignment"] = try JSONCoding.encoder().encode(test.segments) == previousSegments
        }
        let report:[String:Any] = ["start":start,"end":end,"selectedSegments":selected.count,"proposals":draft.proposals.count,"elapsedSeconds":Date().timeIntervalSince(began),"filesChecked":hashes.count+1,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("checks.json"),options:.atomic)
        print("Riascolto: \(selected.count) passaggi, \(draft.proposals.count) proposte; \(checks.values.filter { !$0 }.count) errori; originali invariati.")
        if checks.values.contains(false) { throw VerbaleError.message("Controlli falliti.") }
    }
}
