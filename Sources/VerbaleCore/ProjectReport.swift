import Foundation
import CryptoKit

/// Operational reports use the model for evidence and one short overview; all
/// tables and detailed sections are rendered locally. Requests stay sequential.
enum ProjectReport {
    private struct Checkpoint:Codable { var responses:[String:String] = [:];var splits:Set<String> = [] }
    static func generate(meeting:Meeting,endpoint:String,model:String,key:String,session:URLSession,
                         checkpointDirectory:URL?,timing:ReportTiming,policy:ReportPolicy,
                         diagnostics:@escaping @Sendable (ReportMetric)->Void,
                         progress:@escaping @Sendable (String)->Void) async throws -> OperationalReport {
        let run = ReportRun(policy:policy,timing:timing,observe:diagnostics)
        defer { if Task.isCancelled { run.outcome = "cancelled" };run.finish() }
        do {
            guard policy.maxDuration.isFinite,policy.maxDuration > 0,policy.maxOutputTokens > 0,policy.maxAttempts > 0,policy.maxRequests > 0,policy.maxRequestedTokens > 0 else { throw ReportServiceError(kind:.workLimit,status:0,retryAfter:nil) }
            try LocalGateway.validateToken(key)
            let base = try LocalGateway.baseURL(endpoint)
            guard !meeting.segments.isEmpty else { throw VerbaleError.message("La trascrizione è vuota") }
            let transport = session === URLSession.shared ? LocalGateway.session:session
            progress("Verifica del gateway e del modello selezionato…")
            let models = try await LocalGateway.models(endpoint:endpoint,token:key,session:transport,transport:{ request in
                try await run.data(for:request,session:transport,context:ReportMetric(phase:request.url?.path == "/health" ? "health":"models"))
            })
            guard let selected = models.first(where:{ $0.id == model }) else { throw VerbaleError.message("Il modello selezionato non è configurato nel gateway. Aggiorna l’elenco nelle Impostazioni.") }
            // Never exceed an advertised budget. Older gateways retain the safe fallback.
            let limit = min(48000,max(512,selected.report_input_limit_bytes ?? selected.input_limit_bytes ?? 14000))
            let prefix = "FONTI DELLA RIUNIONE:\n",suffix = "\nFINE FONTI\n"
            let overhead = (prefix+suffix+ProjectReportPrompt.extraction(overview:true)).utf8.count
            guard limit-overhead >= 512 else { throw ReportServiceError(kind:.tooLarge,status:0,retryAfter:nil) }
            let batches = ReportService.sourceBatches(meeting:meeting,limit:limit-overhead)
            guard !batches.isEmpty else { throw VerbaleError.message("La trascrizione è vuota") }
            func hash(_ text:String)->String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
            let effort = selected.report_low_effort == true ? "low":nil
            let identity = hash((effort ?? "standard")+"\n"+ProjectReportPrompt.version+"\n"+endpoint+"\n"+model+"\n"+ProjectReportPrompt.system+"\n"+ProjectReportPrompt.extraction(overview:batches.count == 1)+"\n"+batches.map(\.text).joined(separator:"\0"))
            let file = checkpointDirectory?.appendingPathComponent(identity+".json")
            var cache:Checkpoint = file.flatMap { try? JSONDecoder().decode(Checkpoint.self,from:Data(contentsOf:$0)) } ?? Checkpoint()
            func save() throws {
                guard let file,let directory = checkpointDirectory else { return }
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try JSONEncoder().encode(cache).write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
            let client = ReportClient(url:base.appendingPathComponent("chat/completions"),model:model,key:key,session:transport,run:run,progress:progress,reasoningEffort:effort)
            func complete(_ user:String,valid:Set<String>,phase:String,index:Int,count:Int,summary:Bool = false) async throws -> ProjectEvidence {
                try run.check()
                guard user.utf8.count <= limit else { throw ReportServiceError(kind:.intermediateCapacity,status:0,retryAfter:nil) }
                let id = hash(phase+"\n"+user+"\n"+String(policy.budget(final:summary,bytes:user.utf8.count)))
                if let cached = cache.responses[id],let evidence = try? ProjectEvidence.parse(cached,validSources:valid,summary:summary) {
                    var metric = ReportMetric(phase:phase,index:index,count:count);metric.outcome = "checkpoint";diagnostics(metric)
                    return evidence
                }
                let budget:Int
                if summary { budget = min(policy.maxOutputTokens,6000) }
                else if selected.provider_type == "claude" {
                    budget = user.utf8.count > 32000 ? policy.maxOutputTokens:min(policy.maxOutputTokens,max(8192,4096+(user.utf8.count/4000)*1024))
                } else { budget = policy.budget(final:false,bytes:user.utf8.count) }
                let text = try await client.complete(system:ProjectReportPrompt.system,user:user,maxOutput:budget,phase:phase,index:index,count:count)
                let evidence = try ProjectEvidence.parse(text,validSources:valid,summary:summary)
                try run.check();cache.responses[id] = text;try save()
                var metric = ReportMetric(phase:"capsule",index:index,count:count);metric.records = evidence.facts.count;metric.outputBytes = text.utf8.count;diagnostics(metric)
                return evidence
            }
            func extract(_ batch:ReportSourceBatch,index:Int,depth:Int = 0) async throws -> [ProjectEvidence] {
                try run.check()
                let parent = hash(batch.text),canSplit = depth < 4 && batch.text.utf8.count > 8000
                if !cache.splits.contains(parent) {
                    do {
                        progress("Estrazione operativa \(index) di \(batches.count)"+(depth > 0 ? " · parte ridotta":""))
                        let user = prefix+batch.text+suffix+ProjectReportPrompt.extraction(overview:batches.count == 1 && depth == 0)
                        return [try await complete(user,valid:batch.refs,phase:"extraction",index:index,count:batches.count)]
                    } catch let error as ReportServiceError where canSplit && [.truncated,.tooLarge,.gatewayTimeout].contains(error.kind) {
                        cache.splits.insert(parent);try save()
                    }
                }
                guard canSplit else { throw ReportServiceError(kind:.intermediateCapacity,status:0,retryAfter:nil) }
                progress("Suddivisione del blocco \(index) · conservazione di tutte le fonti")
                let children = ReportSourceBatch.pack(batch.fragments,limit:max(1000,batch.text.utf8.count/2))
                guard children.count > 1 else { throw ReportServiceError(kind:.intermediateCapacity,status:0,retryAfter:nil) }
                var result:[ProjectEvidence] = []
                for child in children { result += try await extract(child,index:index,depth:depth+1) }
                return result
            }
            var partials:[ProjectEvidence] = []
            for (index,batch) in batches.enumerated() { partials += try await extract(batch,index:index+1) }
            let evidence = ProjectEvidence.merge(partials)
            var overview = evidence.overview ?? []
            if partials.count > 1 && !evidence.facts.isEmpty {
                progress("Sintesi esecutiva · composizione del report")
                let input = try ProjectReportRenderer.summaryInput(evidence,limit:limit)
                overview = try await complete(input.text,valid:input.refs,phase:"final_overview",index:1,count:1,summary:true).overview ?? []
            }
            if overview.isEmpty { overview = ProjectReportRenderer.fallbackOverview(evidence) }
            try run.check();progress("Impaginazione locale del report")
            let markdown = ProjectReportRenderer.render(evidence,overview:overview)
            let resolved = ReportService.resolveReferences(markdown,meeting:meeting)
            run.outcome = "success"
            let markdownResult = "# \(meeting.title)\n\n\(resolved)\n\n---\nReport operativo · Gateway locale / \(model) · \(ISO8601DateFormatter().string(from:timing.now())) · prompt \(ProjectReportPrompt.version)\nI rimandi identificano le fonti fornite; gli intervalli aprono il primo passaggio citato. Il contenuto del report richiede revisione.\n"
            let actions = evidence.facts.filter { $0.kind == "action" }.map {
                ActionProposal(meeting: meeting, text: $0.text, owner: $0.owner, deadline: $0.deadline,
                               declaredStatus: $0.status, dependencies: $0.dependencies,
                               commitment: $0.commitment ?? "unclear", references: $0.refs)
            }.filter { !$0.sources.isEmpty }
            return OperationalReport(markdown: markdownResult, actions: actions)
        } catch {
            run.outcome = error is CancellationError ? "cancelled":(error as? ReportServiceError).map { String(describing:$0.kind) } ?? "failed"
            if var failure = error as? ReportServiceError,let metric = run.currentMetric {
                failure.context = ReportFailureContext(phase:metric.phase,index:metric.index,count:metric.count,requestID:metric.requestID,errorCode:metric.errorCode);throw failure
            }
            throw error
        }
    }
}
