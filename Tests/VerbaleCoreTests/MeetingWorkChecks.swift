import Foundation
import VerbaleCore

private actor WorkSignal { var value:TeamsCallSignal = .inactive;func set(_ value:TeamsCallSignal){self.value=value} }
private actor StaleWorkSignal {
    private var first=true
    func sample() async -> TeamsCallSignal {
        if first { first=false;try? await Task.sleep(for:.milliseconds(200));return .inactive }
        return .active
    }
}
private actor WorkRecorder {
    var active:[MeetingWorkKind:Int]=[:],maximum:[MeetingWorkKind:Int]=[:],events:[String]=[]
    func run(_ job:MeetingWorkJob,_ progress:@escaping MeetingWorkQueue.Progress) async throws {
        active[job.kind,default:0]+=1;maximum[job.kind]=max(maximum[job.kind,default:0],active[job.kind]!)
        events.append("start:"+job.title)
        defer { active[job.kind,default:0]-=1;events.append("end:"+job.title) }
        await progress("Lavorazione "+job.title)
        for _ in 0..<10 { try await Task.sleep(for:.milliseconds(15)) }
        if job.title == "failure" { throw VerbaleError.message("Errore controllato") }
    }
    func state()->([MeetingWorkKind:Int],[String]) { (maximum,events) }
}
private actor WorkASR:MeetingTranscribing {
    var calls=0,loads=0
    let delay:Duration
    init(delay:Duration = .zero){self.delay=delay}
    func load(asr:URL,vad:URL) { loads+=1 }
    func unload() {}
    func transcribe(samples:[Float],source:AudioSource,offset:Double) async throws -> [Segment] {
        calls+=1;try await Task.sleep(for:delay)
        return (0..<((samples.count+1599)/1600)).map { i in Segment(source:source,start:offset+Double(i)/10,end:offset+Double(i)/10+0.09,text:"Passaggio \(Int(((offset+Double(i)/10)*10).rounded()))") }
    }
}
enum MeetingWorkChecks {
    static func run() async -> Int {
        var failures=0
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("work-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        func check(_ value:Bool,_ message:String)throws {if !value {throw VerbaleError.message(message)}}
        func wait(_ queue:MeetingWorkQueue,_ test:([MeetingWorkJob])->Bool) async throws {
            for _ in 0..<300 {if test(await queue.snapshot()){return};try await Task.sleep(for:.milliseconds(10))}
            throw VerbaleError.message("Timeout coda")
        }
        do {
            let signal=WorkSignal(),rec=WorkRecorder()
            let queue=try MeetingWorkQueue(file:root.appendingPathComponent("fifo.json"),probe:{await signal.value},execute:{j,p in try await rec.run(j,p)})
            await queue.start(observe:{_ in})
            let a=MeetingWorkJob(meetingID:UUID(),title:"a",kind:.transcription),b=MeetingWorkJob(meetingID:UUID(),title:"b",kind:.transcription)
            let report=MeetingWorkJob(meetingID:a.meetingID,title:"report-a",kind:.report)
            let other=MeetingWorkJob(meetingID:UUID(),title:"report-other",kind:.report)
            let id=await queue.enqueue(a),duplicate=await queue.enqueue(a)
            try check(id==duplicate,"duplicazione lavoro")
            _=await queue.enqueue(b);_=await queue.enqueue(other);_=await queue.enqueue(report)
            try await wait(queue,{$0.count==4 && $0.allSatisfy{!$0.state.pending}})
            let (maximum,events)=await rec.state()
            try check(maximum.values.allSatisfy{$0==1},"lavori concorrenti nella stessa coda")
            try check(events.firstIndex(of:"start:b")! > events.firstIndex(of:"end:a")!,"ordine trascrizioni")
            try check(events.firstIndex(of:"start:report-a")! > events.firstIndex(of:"end:a")!,"report prima della trascrizione")
            try check(events.firstIndex(of:"start:report-other")! < events.firstIndex(of:"end:a")!,"code indipendenti")
            await queue.shutdown();print("PASS work queue FIFO, independent lanes, deduplication and report dependency")
        } catch {failures+=1;print("FAIL work queue FIFO: \(error)")}
        do {
            let signal=WorkSignal(),rec=WorkRecorder();await signal.set(.active)
            let path=root.appendingPathComponent("gate.json")
            let queue=try MeetingWorkQueue(file:path,probe:{await signal.value},execute:{j,p in try await rec.run(j,p)})
            await queue.start(observe:{_ in})
            let job=MeetingWorkJob(meetingID:UUID(),title:"gated",kind:.transcription)
            _=await queue.enqueue(job)
            try await wait(queue,{$0.first?.state == .waitingForTeams})
            await signal.set(.unavailable);await queue.refresh()
            let initial=await rec.state();try check(initial.1.isEmpty,"inferenza con stato Teams sconosciuto")
            await signal.set(.inactive);await queue.refresh()
            try await wait(queue,{$0.first?.state == .running})
            await queue.setCaptureActive(true)
            let paused=await queue.snapshot();try check(paused.first?.state == .waitingForTeams,"cattura non mette in pausa")
            await queue.setCaptureActive(false)
            try await wait(queue,{$0.first?.state == .completed})
            let failing=MeetingWorkJob(meetingID:UUID(),title:"failure",kind:.report)
            _=await queue.enqueue(failing)
            let next=MeetingWorkJob(meetingID:UUID(),title:"after-failure",kind:.report);_=await queue.enqueue(next)
            try await wait(queue,{$0.last?.state == .completed})
            let all=await queue.snapshot();try check(all.first(where:{$0.id==failing.id})?.state == .failed,"errore perso")
            let cancelled=MeetingWorkJob(meetingID:UUID(),title:"cancel-running",kind:.report)
            _=await queue.enqueue(cancelled)
            try await wait(queue,{$0.last?.state == .running})
            await queue.cancel(cancelled.id)
            let stopping=await queue.snapshot();try check(stopping.last?.state.pending == true,"riunione sbloccata prima del termine del worker")
            try await wait(queue,{$0.last?.state == .cancelled})
            await queue.shutdown();print("PASS work queue Teams/unknown/capture protection, resumption and failure isolation")
        } catch {failures+=1;print("FAIL work queue gate: \(error)")}
        do {
            let signal=StaleWorkSignal(),rec=WorkRecorder()
            let q=try MeetingWorkQueue(file:root.appendingPathComponent("stale-probe.json"),probe:{await signal.sample()},execute:{j,p in try await rec.run(j,p)})
            let job=MeetingWorkJob(meetingID:UUID(),title:"stale",kind:.transcription)
            _=await q.enqueue(job)
            try await Task.sleep(for:.milliseconds(30))
            await q.refresh()
            try await Task.sleep(for:.milliseconds(250))
            let events=await rec.state().1,state=await q.snapshot().first?.state
            try check(events.isEmpty && state == .waitingForTeams,"segnale vecchio avvia lavoro durante Teams")
            await q.shutdown();print("PASS work queue ignores stale Teams probe after newer active signal")
        } catch {failures+=1;print("FAIL work queue stale probe: \(error)")}
        do {
            let rec=WorkRecorder(),file=root.appendingPathComponent("restart.json")
            let q=try MeetingWorkQueue(file:file,probe:{.inactive},execute:{j,p in try await rec.run(j,p)})
            await q.start(observe:{_ in})
            let a=MeetingWorkJob(meetingID:UUID(),title:"restart-a",kind:.transcription),b=MeetingWorkJob(meetingID:UUID(),title:"restart-b",kind:.transcription)
            _=await q.enqueue(a);_=await q.enqueue(b)
            try await wait(q,{$0.first?.state == .running})
            await q.shutdown()
            let restored=try MeetingWorkQueue(file:file,probe:{.inactive},execute:{j,p in try await rec.run(j,p)})
            let snapshot=await restored.snapshot();try check(snapshot.count==2 && snapshot.allSatisfy{$0.state.pending},"lavori persi al riavvio")
            await restored.cancel(b.id);await restored.start(observe:{_ in})
            try await wait(restored,{$0.first?.state == .completed})
            let final=await restored.snapshot();try check(final.last?.state == .cancelled,"annullamento in coda perso")
            let secret=ReportWorkSettings(endpoint:"fixture",model:"fixture",project:"fixture",style:"operational",token:"PRIVATE-TEST-TOKEN")
            let encoded=try JSONCoding.encoder().encode(secret)
            try check(!String(decoding:encoded,as:UTF8.self).contains("PRIVATE-TEST-TOKEN"),"token salvato nella coda")
            let decoded=try JSONCoding.decoder().decode(ReportWorkSettings.self,from:encoded)
            try check(decoded.token == nil,"token ricreato dal manifest")
            let permissions=(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue
            try check(permissions==0o600,"permessi manifest coda")
            await restored.shutdown();print("PASS work queue graceful shutdown, persistence, restart and queued cancellation")
        } catch {failures+=1;print("FAIL work queue restart: \(error)")}
        do {
            let file=root.appendingPathComponent("corrupt.json")
            try Data("{invalid".utf8).write(to:file)
            let q=try MeetingWorkQueue(file:file,probe:{.inactive},execute:{_,_ in})
            let warning=await q.restorationWarning()
            try check(warning != nil,"coda corrotta ignorata silenziosamente")
            let backups=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("corrupt.json.invalid-")}
            let backup=backups.first.flatMap{try? Data(contentsOf:$0)}
            try check(backups.count==1 && backup==Data("{invalid".utf8),"vecchia coda sovrascritta senza backup")
            await q.start(observe:{_ in});await q.shutdown()
            print("PASS work queue corrupt manifest preserves backup and exposes recovery warning")
        } catch {failures+=1;print("FAIL work queue corrupt manifest: \(error)")}
        do {
            let base=root.appendingPathComponent("processor"),store=try SessionStore(root:base.appendingPathComponent("Sessions"))
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
            var meeting=Meeting(title:"ASR",sources:[.system],destination:base,keepAudio:true)
            meeting.keepRecovery=true;meeting.state = .interrupted
            try store.save(meeting)
            for i in 0..<3 {
                var c=AudioChunk(source:.system,start:Double(i)/10,sampleCount:1600,filename:"audio/\(i).caf")
                try AudioFiles.write([Float](repeating:0.1,count:1600),to:store.workspace(meeting.id).appendingPathComponent(c.filename))
                if i==0 {c.processed=true}
                if i<2 {meeting.chunks.append(c)}
                try store.append(c,id:meeting.id)
            }
            let original=Segment(source:.system,start:0,end:0.09,text:"Originale confermato")
            meeting.segments=[original];try store.save(meeting)
            var other=Meeting(title:"Altro",sources:[.system],destination:base,keepAudio:false);other.state = .complete;other.notes="Da conservare";try store.save(other)
            let before=try Data(contentsOf:store.workspace(other.id).appendingPathComponent("meeting.json"))
            let disk=try MeetingWorkDisk(root:store.root),models=try ModelManager(directory:base.appendingPathComponent("models")),asr=WorkASR()
            let processor=MeetingWorkProcessor(root:store.root,models:models,disk:disk,makeEngine:{asr},modelFiles:{(base,base)})
            var job=MeetingWorkJob(meetingID:meeting.id,title:meeting.title,kind:.transcription);job.automaticVoices=false
            try await processor.run(job,progress:{_ in})
            let result=try store.read(meeting.id),calls=await asr.calls
            try check(result.state == .complete && result.chunks.count==3 && result.chunks.allSatisfy(\.processed) && calls==2,"recupero journal e blocchi gia trascritti")
            try check(result.segments.contains(where:{$0.id==original.id && $0.text==original.text}),"segmenti originali cambiati")
            try check(try Data(contentsOf:store.workspace(other.id).appendingPathComponent("meeting.json"))==before,"altra riunione modificata")
            let reportJob=MeetingWorkJob(meetingID:meeting.id,title:meeting.title,kind:.report,report:ReportWorkSettings(endpoint:"local",model:"fixture",project:"fixture",style:"operational"))
            let reportProcessor=MeetingWorkProcessor(root:store.root,models:models,disk:disk,generateReport:{m,_,_ in "# "+m.title+"\nReport fixture"})
            try await reportProcessor.run(reportJob,progress:{_ in})
            let reported=try store.read(meeting.id);try check(reported.report?.contains("Report fixture")==true,"report non salvato")
            let stale=MeetingWorkProcessor(root:store.root,models:models,disk:disk,generateReport:{_,_,_ in try await Task.sleep(for:.milliseconds(150));return "Stale report"})
            let task=Task {try await stale.run(reportJob,progress:{_ in})}
            try await Task.sleep(for:.milliseconds(40));var changed=try store.read(meeting.id);changed.notes="Modifica esterna";try store.save(changed)
            do {try await task.value;throw VerbaleError.message("report obsoleto accettato")} catch is CancellationError {throw VerbaleError.message("cancellazione inattesa")} catch {
                let kept=try store.read(meeting.id);try check(kept.notes=="Modifica esterna" && kept.report==reported.report,"report vecchio sovrascritto")
            }
            var partial=Meeting(title:"Partial",sources:[.system],destination:base,keepAudio:true)
            partial.keepRecovery=true;partial.state = .interrupted;try store.save(partial)
            for i in 0..<4 {
                let chunk=AudioChunk(source:.system,start:Double(i)/10,sampleCount:1600,filename:"audio/partial-\(i).caf")
                try AudioFiles.write([Float](repeating:0.2,count:1600),to:store.workspace(partial.id).appendingPathComponent(chunk.filename))
                partial.chunks.append(chunk)
            }
            try store.save(partial)
            let slow=WorkASR(delay:.milliseconds(200))
            let partialProcessor=MeetingWorkProcessor(root:store.root,models:models,disk:disk,makeEngine:{slow},modelFiles:{(base,base)})
            var partialJob=MeetingWorkJob(meetingID:partial.id,title:partial.title,kind:.transcription);partialJob.automaticVoices=false
            let partialTask=Task {try await partialProcessor.run(partialJob,progress:{_ in})}
            for _ in 0..<200 {
                if (try store.read(partial.id)).chunks.contains(where:\.processed) {break}
                try await Task.sleep(for:.milliseconds(10))
            }
            partialTask.cancel();_=try? await partialTask.value
            let stopped=try store.read(partial.id),count=stopped.chunks.filter(\.processed).count
            try check(stopped.state == .interrupted && count>0 && count<4,"checkpoint parziale perso")
            try await partialProcessor.run(partialJob,progress:{_ in})
            let resumed=try store.read(partial.id)
            try check(resumed.state == .complete && resumed.chunks.allSatisfy(\.processed) && resumed.segments.count==4,"ripresa parziale duplicata o incompleta")
            print("PASS background processor journal recovery, partial ASR, isolated meetings, report persistence and stale source rejection")
        } catch {failures+=1;print("FAIL work processor: \(error)")}
        return failures
    }
}
