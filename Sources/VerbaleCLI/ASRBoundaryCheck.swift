import Foundation
import VerbaleCore

enum ASRBoundaryCheck {
    static func run(input:URL,asr:URL,vad:URL,start:Double,end:Double,output:URL) async throws {
        guard start.isFinite,end.isFinite,start >= 0,end > start,end-start <= 1200 else { throw VerbaleError.message("Scegli un estratto da 0 a 20 minuti.") }
        guard !FileManager.default.fileExists(atPath:output.path) else { throw VerbaleError.message("La cartella del test esiste già.") }
        let data = try Data(contentsOf:input), original = try JSONCoding.decoder().decode(Meeting.self,from:data)
        let audio = VoiceAudio(workspace:input.deletingLastPathComponent(),exported:URL(fileURLWithPath:original.destination).appendingPathComponent(original.folderName))
        let chunks = original.chunks.filter { $0.source == .system }.sorted { $0.start < $1.start }
        let indices = chunks.indices.filter { chunks[$0].start >= start && chunks[$0].start < end }
        guard !indices.isEmpty else { throw VerbaleError.message("Nessun blocco audio di sistema nell’intervallo scelto.") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var baseline = original; baseline.segments = []; baseline.speakers = [:]; baseline.voiceMatches = nil
        baseline.review = nil; baseline.report = nil; baseline.reportStatus = "Non richiesto"
        baseline.echoDuplicates = nil; baseline.transcriptBoundaryEdits = nil; baseline.screenshots = []; baseline.keepAudio = false
        var fixed = baseline, audioHashes:[String:String] = [:]
        let engine = TranscriptionEngine(), began = Date()
        try await engine.load(asr:asr,vad:vad)
        do {
            for (step,index) in indices.enumerated() {
                let neighborhood = chunks[max(0,index-1)...min(chunks.count-1,index+1)]
                let offset = neighborhood.first!.start
                var samples:[Float] = []
                for chunk in neighborhood {
                    let filename = try audio.filename(chunk,meeting:original), path = try audio.url(filename)
                    if audioHashes[path.path] == nil { audioHashes[path.path] = try ModelManager.digest(path) }
                    let position = Int((chunk.start-offset)*16000)
                    if position > samples.count { samples.append(contentsOf:repeatElement(0,count:position-samples.count)) }
                    let overlap = max(0,samples.count-position)
                    var block:[Float] = [], cursor = 0
                    while cursor < chunk.sampleCount {
                        let n = min(80000,chunk.sampleCount-cursor)
                        block += try audio.read(filename,offset:cursor,count:n); cursor += n
                    }
                    samples += block.dropFirst(overlap)
                }
                let raw = try await engine.transcribe(samples:samples,source:.system,offset:offset)
                let owned = TranscriptBoundaries.owned(raw,by:chunks[index])
                baseline.segments += owned; fixed.appendTranscription(owned,for:chunks[index])
                if step % 10 == 0 { FileHandle.standardError.write(Data("ASR \(step+1)/\(indices.count) blocchi · \(timecode(chunks[index].start))\n".utf8)) }
            }
        } catch { await engine.unload(); throw error }
        await engine.unload()
        let beforeCount = baseline.segments.reduce(0) { $0+$1.words.count }
        let afterCount = fixed.segments.reduce(0) { $0+$1.words.count }
        let edits = fixed.transcriptBoundaryEdits ?? [], removed = edits.reduce(0) { $0+$1.duplicates.count }
        let originals = Dictionary(uniqueKeysWithValues:baseline.segments.map { ($0.id,$0) })
        let editByID = Dictionary(uniqueKeysWithValues:edits.map { ($0.id,$0) })
        var checks:[String:Bool] = [:]
        checks["word count difference equals audited removals"] = beforeCount-afterCount == removed
        checks["remaining words and timestamps are exact subsequences"] = try fixed.segments.allSatisfy { segment in
            guard let previous = originals[segment.id] else { return false }
            let removedIndices = Set((editByID[segment.id]?.duplicates ?? []).map(\.originalIndex))
            let expected = previous.words.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
            return try JSONCoding.encoder().encode(segment.words) == JSONCoding.encoder().encode(expected)
        }
        checks["every removed hypothesis is preserved"] = try edits.allSatisfy { edit in
            guard let previous = originals[edit.id] else { return false }
            return try JSONCoding.encoder().encode(previous) == JSONCoding.encoder().encode(edit.original)
        }
        checks["source manifest unchanged"] = try Data(contentsOf:input) == data
        checks["source audio unchanged"] = try audioHashes.allSatisfy { try ModelManager.digest(URL(fileURLWithPath:$0.key)) == $0.value }
        for (name,meeting) in [("baseline",baseline),("reconciled",fixed)] {
            let destination = output.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            let store = try SessionStore(root:destination.appendingPathComponent("sessions"))
            var meeting = meeting; meeting.destination = destination.path; meeting.state = .complete
            let saved = try store.export(meeting)
            checks[name+" reopens after export"] = try store.read(saved.id).segments.count == meeting.segments.count
        }
        let report:[String:Any] = ["input":input.path,"start":start,"end":end,"blocks":indices.count,"beforeWords":beforeCount,"afterWords":afterCount,"removedWords":removed,"changedSegments":edits.count,"elapsedSeconds":Date().timeIntervalSince(began),"sourceFilesChecked":audioHashes.count+1,"checks":checks]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("checks.json"),options:.atomic)
        print("ASR test: \(indices.count) blocchi, \(beforeCount) → \(afterCount) parole; \(removed) rimozioni conservate nel registro; \(checks.values.filter { !$0 }.count) controlli falliti.")
        if checks.values.contains(false) { throw VerbaleError.message("Controlli ASR falliti: consulta checks.json.") }
    }
}
