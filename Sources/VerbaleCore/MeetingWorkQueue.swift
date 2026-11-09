import Foundation

public enum MeetingWorkKind:String,Codable,CaseIterable,Sendable { case transcription,report }
public enum MeetingWorkState:String,Codable,Sendable {
    case queued,running,waitingForTeams,completed,failed,cancelled
    public var pending:Bool { [.queued,.running,.waitingForTeams].contains(self) }
}
public struct ReportWorkSettings:Codable,Equatable,Sendable {
    public var endpoint,model,project,style:String
    public var token:String? = nil
    enum CodingKeys:String,CodingKey {case endpoint,model,project,style}
    public init(endpoint:String,model:String,project:String,style:String,token:String?=nil) { self.endpoint=endpoint;self.model=model;self.project=project;self.style=style;self.token=token }
}
public struct MeetingWorkJob:Codable,Equatable,Identifiable,Sendable {
    public var id=UUID(),meetingID:UUID
    public var kind:MeetingWorkKind,state:MeetingWorkState = .queued
    public var title:String,progress="In coda",error:String?
    public var report:ReportWorkSettings?
    public var automaticVoices = true
    public var transcriptionDependency:UUID?
    public var failureDismissedAt:Date?
    public var showsBanner:Bool { state.pending || (state == .failed && failureDismissedAt == nil) }
    public init(meetingID:UUID,title:String,kind:MeetingWorkKind,report:ReportWorkSettings?=nil) { self.meetingID=meetingID;self.title=title;self.kind=kind;self.report=report }
}
/// One serial lane per kind. Jobs never hold or mutate the UI's selection.
public actor MeetingWorkQueue {
    public typealias Progress = @Sendable (String) async -> Void
    public typealias Execute = @Sendable (MeetingWorkJob,@escaping Progress) async throws -> Void
    public nonisolated let initialSnapshot:[MeetingWorkJob]
    private var jobs:[MeetingWorkJob]
    private let file:URL,execute:Execute,probe:@Sendable () async -> TeamsCallSignal
    private var restoreIssue:String?
    private var canPersist=true
    private var lastPublished:[MeetingWorkJob]?
    private var observer:(@Sendable ([MeetingWorkJob])->Void)?
    private var cancelRequested:Set<UUID> = []
    private var runners:[MeetingWorkKind:Task<Void,Never>] = [:]
    private var monitor:Task<Void,Never>?
    private var probeGeneration:UInt64=0
    private var captureActive=false,closing=false,callState:TeamsCallSignal = .unavailable
    public init(file:URL,probe:@escaping @Sendable () async -> TeamsCallSignal = { await Task.detached(priority:.utility) { TeamsCallProbe.sample() }.value },execute:@escaping Execute) throws {
        self.file=file;self.probe=probe;self.execute=execute
        if FileManager.default.fileExists(atPath:file.path) {
            do { jobs=try JSONCoding.decoder().decode([MeetingWorkJob].self,from:Data(contentsOf:file)) }
            catch {
                jobs=[];restoreIssue="La coda salvata non è leggibile. Le registrazioni sono conservate: riavvia le attività dall’archivio."
                do {
                    let backup=file.appendingPathExtension("invalid-"+UUID().uuidString)
                    try FileManager.default.copyItem(at:file,to:backup)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
                } catch {canPersist=false}
            }
        } else {jobs=[]}
        for i in jobs.indices where jobs[i].state == .running { jobs[i].state = .queued;jobs[i].progress="Ripresa dopo riavvio" }
        initialSnapshot=jobs
    }
    public func start(observe:@escaping @Sendable ([MeetingWorkJob])->Void) async {
        observer=observe;observer?(jobs);publish()
        guard monitor == nil else { return }
        monitor=Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }
    private func publish() {
        guard jobs != lastPublished else{return}
        var persisted=false
        do {
            for i in jobs.indices where jobs[i].error?.hasPrefix("La coda non è stata salvata sul disco:")==true {jobs[i].error=nil}
            try persist(jobs)
            persisted=true
        } catch {
            for i in jobs.indices where jobs[i].state.pending { jobs[i].error="La coda non è stata salvata sul disco: "+error.localizedDescription }
        }
        lastPublished=persisted ? jobs:nil;observer?(jobs)
    }
    private func persist(_ snapshot:[MeetingWorkJob]) throws {
        guard canPersist else {throw VerbaleError.message("Impossibile conservare una copia della vecchia coda; riprova dopo il riavvio.")}
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONCoding.encoder().encode(snapshot).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public func dismissFailure(_ id:UUID) throws {
        guard let i=jobs.firstIndex(where:{$0.id==id}),jobs[i].state == .failed,jobs[i].failureDismissedAt == nil else{return}
        var updated=jobs
        updated[i].failureDismissedAt=Date()
        // Hide only after the acknowledgement is durable; retain the failed job and its diagnostics.
        try persist(updated)
        jobs=updated;lastPublished=jobs;observer?(jobs)
    }
    public func restorationWarning()->String? {restoreIssue}
    public func snapshot()->[MeetingWorkJob] { jobs }
    public func refresh() async { await tick() }
    @discardableResult public func enqueue(_ job:MeetingWorkJob)->UUID {
        if let old=jobs.first(where:{$0.meetingID==job.meetingID && $0.kind==job.kind && $0.state.pending}) { return old.id }
        var submitted=job
        submitted.failureDismissedAt=nil
        if job.kind == .report { submitted.transcriptionDependency=jobs.last(where:{$0.meetingID==job.meetingID && $0.kind == .transcription && $0.state.pending})?.id }
        jobs.append(submitted);publish();Task { await tick() };return job.id
    }
    public func forget(_ meetingID:UUID) {
        guard !jobs.contains(where:{$0.meetingID==meetingID && $0.state.pending}) else{return}
        jobs.removeAll{$0.meetingID==meetingID};publish()
    }
    public func cancel(_ id:UUID) {
        guard let i=jobs.firstIndex(where:{$0.id==id}),jobs[i].state.pending else { return }
        if jobs[i].state == .running {
            guard cancelRequested.insert(id).inserted else{return}
            jobs[i].progress="Sospensione…";runners[jobs[i].kind]?.cancel()
        } else { jobs[i].state = .cancelled;jobs[i].progress="Sospeso · dati conservati" }
        publish()
    }
    public func setCaptureActive(_ active:Bool) async {
        captureActive=active
        if active,let task=runners[.transcription] { task.cancel();await task.value }
        await tick()
    }
    private func tick() async {
        guard !closing,jobs.contains(where:{$0.state.pending}) else { return }
        probeGeneration &+= 1
        let generation=probeGeneration
        let signal=await probe()
        guard !closing,generation==probeGeneration else{return}
        callState=signal
        if captureActive || callState != .inactive { runners[.transcription]?.cancel() }
        for kind in MeetingWorkKind.allCases where runners[kind] == nil {
            let blocked=kind == .transcription && (captureActive || callState != .inactive)
            for i in jobs.indices where jobs[i].kind==kind && jobs[i].state.pending && jobs[i].state != .running {
                if blocked { jobs[i].state = .waitingForTeams;jobs[i].progress="Attesa della fine della chiamata" }
                else if jobs[i].state == .waitingForTeams { jobs[i].state = .queued;jobs[i].progress="In coda" }
            }
            if blocked { continue }
            guard let index=jobs.firstIndex(where:{$0.kind==kind && $0.state == .queued}) else { continue }
            let candidate=jobs[index]
            if kind == .transcription && jobs.contains(where:{$0.meetingID==candidate.meetingID && $0.kind == .report && $0.state == .running}) { continue }
            if kind == .report {
                if jobs[index].transcriptionDependency == nil,let trans=jobs.last(where:{$0.meetingID==candidate.meetingID && $0.kind == .transcription && $0.state.pending}) {jobs[index].transcriptionDependency=trans.id}
                if let dependency=jobs[index].transcriptionDependency,let trans=jobs.first(where:{$0.id==dependency}) {
                    if trans.state.pending {continue}
                    if [.failed,.cancelled].contains(trans.state) {jobs[index].state = .failed;jobs[index].error="Completa la trascrizione prima di generare il report.";continue}
                }
            }
            jobs[index].state = .running;jobs[index].progress="Preparazione…";publish()
            runners[kind]=Task.detached(priority:.utility) { [execute] in
                do { try await execute(candidate,{ message in await self.progress(candidate.id,message) });try Task.checkCancellation();await self.finished(candidate.id,error:nil) }
                catch { await self.finished(candidate.id,error:Task.isCancelled ? CancellationError():error) }
            }
        }
        publish()
    }
    private func progress(_ id:UUID,_ text:String) {
        guard let i=jobs.firstIndex(where:{$0.id==id}),jobs[i].state == .running else { return }
        jobs[i].progress=text;observer?(jobs)
    }
    private func finished(_ id:UUID,error:Error?) {
        guard let i=jobs.firstIndex(where:{$0.id==id}) else { return }
        runners[jobs[i].kind]=nil
        if cancelRequested.remove(id) != nil {
            jobs[i].state = .cancelled;jobs[i].progress="Sospeso · dati conservati"
        } else if jobs[i].state != .cancelled {
            if error is CancellationError {
                jobs[i].state = closing ? .queued:.waitingForTeams
                jobs[i].progress=closing ? "In coda":"Attesa della fine della chiamata"
            } else if let error { jobs[i].state = .failed;jobs[i].error=error.localizedDescription;jobs[i].progress="Interrotto" }
            else { jobs[i].state = .completed;jobs[i].progress="Completato" }
        }
        publish();if !closing { Task { await tick() } }
    }
    public func shutdown() async {
        closing=true;monitor?.cancel();monitor=nil
        let tasks=Array(runners.values);tasks.forEach{$0.cancel()}
        for task in tasks { await task.value }
        publish()
    }
}
