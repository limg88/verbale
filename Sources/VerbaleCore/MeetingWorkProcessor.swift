import Foundation

/// All archive reads, encodes, copies and hashes are isolated from MainActor.
public actor MeetingWorkDisk {
    private let store:SessionStore
    public init(root:URL) throws { store=try SessionStore(root:root) }
    public func read(_ id:UUID) throws -> Meeting { try store.read(id) }
    public func recover(_ id:UUID) throws -> Meeting { try store.recover(store.read(id)) }
    public func list() throws -> [Meeting] { try store.list() }
    public func save(_ meeting:Meeting) throws { try store.save(meeting) }
    public func export(_ meeting:Meeting) throws -> Meeting { try store.export(meeting) }
    public func exportReview(_ meeting:Meeting) throws -> Meeting { try store.export(meeting,documentsOnly:true) }
    public func commit(_ value:Meeting,expected:Meeting,export:Bool) throws -> Meeting {
        let latest=try store.read(value.id)
        guard try JSONCoding.encoder().encode(latest) == JSONCoding.encoder().encode(expected) else { throw VerbaleError.message("La riunione è cambiata durante l’elaborazione. I dati più recenti sono stati conservati.") }
        try store.save(value)
        return export ? try store.export(value):value
    }
    public func cleanup(_ meeting:Meeting) throws { if !meeting.keepRecovery { try store.cleanupAudio(meeting) } }
}
public protocol MeetingTranscribing:Sendable {
    func load(asr:URL,vad:URL) async throws
    func transcribe(samples:[Float],source:AudioSource,offset:Double) async throws -> [Segment]
    func unload() async
}
public actor MeetingWorkProcessor {
    private let root:URL,models:ModelManager,disk:MeetingWorkDisk
    private let makeEngine:@Sendable ()->any MeetingTranscribing
    private let modelFiles:(@Sendable () async throws -> (URL,URL))?
    private let credential:@Sendable (ReportWorkSettings) throws -> String
    private let generateReport:(@Sendable (Meeting,ReportWorkSettings,@escaping MeetingWorkQueue.Progress) async throws -> String)?
    public init(root:URL,models:ModelManager,disk:MeetingWorkDisk,
                makeEngine:(@Sendable ()->any MeetingTranscribing)? = nil,
                modelFiles:(@Sendable () async throws -> (URL,URL))? = nil,
                credential:@escaping @Sendable (ReportWorkSettings)throws->String = { try LocalGateway.readToken(project:$0.project) },
                generateReport:(@Sendable (Meeting,ReportWorkSettings,@escaping MeetingWorkQueue.Progress) async throws -> String)? = nil) {
        self.root=root;self.models=models;self.disk=disk;self.makeEngine=makeEngine ?? { BackgroundTranscriber() };self.modelFiles=modelFiles;self.credential=credential;self.generateReport=generateReport
    }
    public func run(_ job:MeetingWorkJob,progress:@escaping MeetingWorkQueue.Progress) async throws {
        if job.kind == .report { try await report(job,progress:progress) }
        else { try await transcribe(job,progress:progress) }
    }
    private func audio(_ meeting:Meeting,_ name:String)->URL {
        let local=root.appendingPathComponent(meeting.id.uuidString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath:local.path) ? local:URL(fileURLWithPath:meeting.destination).appendingPathComponent(meeting.folderName).appendingPathComponent(name)
    }
    private func transcribe(_ job:MeetingWorkJob,progress:@escaping MeetingWorkQueue.Progress) async throws {
        var meeting=try await disk.recover(job.meetingID)
        let engine=makeEngine(),echo=EchoCancellation()
        do {
            try Task.checkCancellation()
            if meeting.chunks.contains(where:{!$0.processed}) {
                let files:(URL,URL)
                if let modelFiles { files=try await modelFiles() }
                else { files=(try await models.verified("asr"),try await models.verified("vad")) }
                try Task.checkCancellation();try await engine.load(asr:files.0,vad:files.1)
            }
            var next=meeting;next.state = .processing;next.resumeAfterTeams=false
            meeting=try await disk.commit(next,expected:meeting,export:false)
            let total=meeting.chunks.count
            var lastExport=ProcessInfo.processInfo.systemUptime
            while let chunk=meeting.chunks.filter({!$0.processed}).sorted(by:{$0.start<$1.start}).first {
                try Task.checkCancellation()
                await progress("Trascrizione \(meeting.chunks.filter(\.processed).count+1) di \(total) blocchi")
                let siblings=meeting.chunks.filter{$0.source==chunk.source}.sorted{$0.start<$1.start}
                let index=siblings.firstIndex{$0.id==chunk.id}!,aec=chunk.source == .microphone && meeting.usesEchoCancellation
                let neighborhood=siblings[max(0,index-(aec ? 2:1))...min(index+1,siblings.count-1)]
                let transcriptionOffset=siblings[max(0,index-1)].start
                var samples:[Float]=[],offset=neighborhood.first!.start
                for item in neighborhood {
                    let position=Int((item.start-offset)*16000)
                    guard position < 60*16000 else { continue }
                    if position>samples.count { samples += repeatElement(0,count:position-samples.count) }
                    let values=try AudioFiles.samples(audio(meeting,item.filename))
                    samples += values.dropFirst(max(0,samples.count-position))
                }
                var cleaned:String?,incomplete=false
                if aec {
                    let result=try await echo.cleanWindow(microphone:samples,start:offset,chunks:meeting.chunks,workspace:root.appendingPathComponent(meeting.id.uuidString),exported:URL(fileURLWithPath:meeting.destination).appendingPathComponent(meeting.folderName))
                    samples=result.samples
                    let begin=max(0,Int(((chunk.start-offset)*16000).rounded())),end=min(samples.count,begin+chunk.sampleCount)
                    guard end-begin==chunk.sampleCount else { throw VerbaleError.message("Blocco microfono incompleto") }
                    incomplete=result.covered[begin..<end].contains(0);cleaned="audio/cleaned_\(chunk.id.uuidString).caf"
                    try AudioFiles.write(Array(samples[begin..<end]),to:root.appendingPathComponent(meeting.id.uuidString).appendingPathComponent(cleaned!))
                }
                if transcriptionOffset>offset { samples=Array(samples.dropFirst(Int(((transcriptionOffset-offset)*16000).rounded())));offset=transcriptionOffset }
                let result=try await engine.transcribe(samples:samples,source:chunk.source,offset:offset)
                try Task.checkCancellation()
                var updated=meeting
                updated.appendTranscription(TranscriptBoundaries.owned(result,by:chunk),for:chunk)
                updated.reconcileEchoTranscript(near:chunk.start,end:chunk.start+chunk.duration);updated.invalidateReport()
                if let i=updated.chunks.firstIndex(where:{$0.id==chunk.id}) { updated.chunks[i].processed=true;updated.chunks[i].cleanedFilename=cleaned }
                if incomplete { let warning="Riferimento eco incompleto: microfono conservato senza trattamento nelle porzioni mancanti.";if !updated.warnings.contains(warning) { updated.warnings.append(warning) } }
                updated.exported=false
                let export=ProcessInfo.processInfo.systemUptime-lastExport>15
                meeting=try await disk.commit(updated,expected:meeting,export:export)
                if export { lastExport=ProcessInfo.processInfo.systemUptime }
            }
            await engine.unload();await echo.unload()
            try Task.checkCancellation()
            // Voice separation/recognition follows the ASR in the same protected lane.
            if job.automaticVoices {
                do {
                    let voice=VoiceAnalysisEngine(),diar=try await models.verified("diarization")
                    try Task.checkCancellation();await progress("Separazione interlocutori…")
                    let workspace=root.appendingPathComponent(meeting.id.uuidString)
                    let audio=VoiceAudio(workspace:workspace,exported:URL(fileURLWithPath:meeting.destination).appendingPathComponent(meeting.folderName))
                    let input=try meeting.preparingVoiceAnalysis(learning:try? SpeakerAudit.load(from:workspace.appendingPathComponent("speaker-analysis.json")))
                    var analyzed=try await voice.diarize(meeting:input,audio:audio,model:diar,progress:{ text in Task { await progress(text) } })
                    analyzed.modelDigests["diarization"]=models.catalog.first{$0.id=="diarization"}?.sha256
                    if let profiles=try? VoiceProfileStore(directory:root.deletingLastPathComponent().appendingPathComponent("VoiceProfiles")),profiles.profiles.contains(where: \.enabled) {
                        let encoder=try await models.verified("voice")
                        analyzed=try await voice.recognize(meeting:analyzed,audio:audio,model:encoder,hash:models.catalog.first{$0.id=="voice"}!.sha256,profiles:profiles.profiles,progress:{text in Task{await progress(text)}})
                        analyzed.modelDigests["voice"]=models.catalog.first{$0.id=="voice"}?.sha256
                    }
                    try Task.checkCancellation();meeting=try await disk.commit(analyzed,expected:meeting,export:false)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    var warned=meeting;warned.warnings.append("Trascrizione completata; analisi voci da riprovare: "+error.localizedDescription)
                    meeting=try await disk.commit(warned,expected:meeting,export:false)
                }
            }
            var done=meeting;done.state = .complete;done.resumeAfterTeams=false;done.exported=false
            done.warnings.removeAll{$0.hasPrefix("Trascrizione in pausa per dare priorità alla chiamata Teams.")}
            meeting=try await disk.commit(done,expected:meeting,export:true)
            do {try await disk.cleanup(meeting)}
            catch {
                var warned=meeting;warned.warnings.append("Output salvato; impossibile rimuovere l’audio temporaneo: "+error.localizedDescription)
                meeting=try await disk.commit(warned,expected:meeting,export:false)
            }
        } catch {
            await engine.unload();await echo.unload()
            if let latest=try? await disk.read(meeting.id),latest.state != .complete {
                var stopped=latest;stopped.state = error is CancellationError ? .interrupted:.failed;stopped.exported=false
                _=try? await disk.commit(stopped,expected:latest,export:true)
            }
            throw error
        }
    }
    private func report(_ job:MeetingWorkJob,progress:@escaping MeetingWorkQueue.Progress) async throws {
        guard let config=job.report else { throw VerbaleError.message("Configurazione report mancante") }
        let input=try await disk.read(job.meetingID)
        let text:String
        var proposals:[ActionProposal]?
        if let generateReport { text=try await generateReport(input,config,progress) }
        else {
            let token=try config.token ?? credential(config)
            let checkpoint=root.appendingPathComponent(input.id.uuidString).appendingPathComponent("report-jobs")
            if (ReportStyle(rawValue:config.style) ?? .operational) == .operational {
                let result = try await ReportService.generateOperational(meeting:input,endpoint:config.endpoint,model:config.model,key:token,checkpointDirectory:checkpoint,progress:{text in Task{await progress(text)}})
                text=result.markdown;proposals=result.actions
            } else {
                text=try await ReportService.generate(meeting:input,endpoint:config.endpoint,model:config.model,key:token,style:.detailed,checkpointDirectory:checkpoint,progress:{text in Task{await progress(text)}})
            }
        }
        try Task.checkCancellation()
        var output=try await disk.read(input.id)
        guard output.reportInputRevision==input.reportInputRevision,output.title==input.title,
              ReportService.sourceBatches(meeting:output,limit:48000).map(\.text)==ReportService.sourceBatches(meeting:input,limit:48000).map(\.text) else { throw VerbaleError.message("Le fonti sono cambiate: il report precedente è conservato. Rigenera il report aggiornato.") }
        let expected=output;output.actionProposals=proposals;output.report=text;output.reportStatus="Completato";output.exported=false
        _=try await disk.commit(output,expected:expected,export:true)
    }
}


private actor BackgroundTranscriber:MeetingTranscribing {
    let engine=TranscriptionEngine()
    func load(asr:URL,vad:URL) async throws { try await engine.load(asr:asr,vad:vad) }
    func transcribe(samples:[Float],source:AudioSource,offset:Double) async throws -> [Segment] { try await engine.transcribe(samples:samples,source:source,offset:offset) }
    func unload() async { await engine.unload() }
}
