import Foundation
import VerbaleCore

enum BackgroundWorkCheck {
    static func run(input:URL,output:URL,start:Double,end:Double) async throws {
        guard TeamsCallProbe.sample() == .inactive else {throw VerbaleError.message("Call Teams attiva o stato non verificabile: prova reale non avviata.")}
        guard !FileManager.default.fileExists(atPath:output.path) else {throw VerbaleError.message("La cartella di prova esiste già.")}
        let data=try Data(contentsOf:input),original=try JSONCoding.decoder().decode(Meeting.self,from:data)
        let chunks=original.chunks.filter{$0.source == .system && $0.start<end && $0.start+$0.duration>start}.sorted{$0.start<$1.start}
        guard !chunks.isEmpty else {throw VerbaleError.message("Nessun blocco audio nell’intervallo.")}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let store=try SessionStore(root:output.appendingPathComponent("sessions"))
        var copy=Meeting(title:original.title+" · prova isolata",sources:[.system],destination:output,keepAudio:true)
        copy.keepRecovery=true;copy.state = .interrupted;copy.listeningMode = .headphones
        try store.save(copy)
        var hashes:[String:String]=[:]
        for originalChunk in chunks {
            var chunk=originalChunk;chunk.processed=false;chunk.cleanedFilename=nil
            var source=input.deletingLastPathComponent().appendingPathComponent(chunk.filename)
            if !FileManager.default.fileExists(atPath:source.path) {source=URL(fileURLWithPath:original.destination).appendingPathComponent(original.folderName).appendingPathComponent(chunk.filename)}
            hashes[source.path]=try ModelManager.digest(source)
            let target=store.workspace(copy.id).appendingPathComponent(chunk.filename)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:source,to:target)
            copy.chunks.append(chunk)
        }
        copy.duration=copy.chunks.map{$0.start+$0.duration}.max() ?? 0;try store.save(copy)
        let disk=try MeetingWorkDisk(root:store.root),models=try ModelManager()
        let processor=MeetingWorkProcessor(root:store.root,models:models,disk:disk)
        let queue=try MeetingWorkQueue(file:output.appendingPathComponent("jobs.json"),execute:{job,progress in try await processor.run(job,progress:progress)})
        await queue.start(observe:{_ in})
        var job=MeetingWorkJob(meetingID:copy.id,title:copy.title,kind:.transcription);job.automaticVoices=false
        let began=Date();_=await queue.enqueue(job)
        for _ in 0..<1800 {
            let state=await queue.snapshot().first?.state
            if state == .completed || state == .failed || state == .cancelled || state == .waitingForTeams {break}
            try await Task.sleep(for:.milliseconds(100))
        }
        let snapshot=await queue.snapshot();await queue.shutdown()
        let result=try await disk.read(copy.id)
        let audioUnchanged=try hashes.allSatisfy{try ModelManager.digest(URL(fileURLWithPath:$0.key))==$0.value}
        let originalUnchanged=try Data(contentsOf:input)==data
        let checks:[String:Bool] = ["completed":snapshot.first?.state == .completed,"allChunksProcessed":result.chunks.allSatisfy(\.processed),"originalUnchanged":originalUnchanged,"sourceAudioUnchanged":audioUnchanged]
        let summary:[String:Any] = ["chunks":chunks.count,"segments":result.segments.count,"seconds":Date().timeIntervalSince(began),"checks":checks]
        try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"),options:.atomic)
        guard checks.values.allSatisfy({$0}) else {throw VerbaleError.message("Prova incompleta: consulta verification.json e jobs.json.")}
        print("PASS isolated background ASR: \(chunks.count) chunks, \(result.segments.count) segments; original and audio unchanged")
    }
}
