import Foundation
import VerbaleCore

private enum OperationalFailure:Error { case failed(String) }
private func opRequire(_ value:Bool,_ label:String) throws { if !value { throw OperationalFailure.failed(label) } }
private final class OperationalMock:URLProtocol {
    static var reportLimit:Int? = 48000
    static var inputLimit = 14000
    static var lowEffort:Bool?
    static var handler:(URLRequest)->(Int,String) = { _ in (500,"") }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let status:Int,body:String
        if request.url?.path == "/health" { (status,body) = (200,#"{"status":"ok"}"#) }
        else if request.url?.path == "/v1/models" {
            var model:[String:Any] = ["id":"test","input_limit_bytes":Self.inputLimit]
            if let limit = Self.reportLimit { model["report_input_limit_bytes"] = limit }
            if let lowEffort = Self.lowEffort { model["report_low_effort"] = lowEffort }
            (status,body) = (200,String(decoding:try! JSONSerialization.data(withJSONObject:["data":[model]]),as:UTF8.self))
        } else { (status,body) = Self.handler(request) }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func payload(_ request:URLRequest)->[String:Any] {
        var data = request.httpBody
        if data == nil,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var all = Data(),bytes = [UInt8](repeating:0,count:4096)
            while true { let n = stream.read(&bytes,maxLength:bytes.count);if n <= 0 { break };all.append(contentsOf:bytes.prefix(n)) };data = all
        }
        return (try? JSONSerialization.jsonObject(with:data ?? Data())) as? [String:Any] ?? [:]
    }
    static func user(_ request:URLRequest)->String { (payload(request)["messages"] as? [[String:String]])?.last?["content"] ?? "" }
}
enum OperationalReportChecks {
    static func reply(_ object:[String:Any],finish:String = "stop")->String {
        let content = String(decoding:try! JSONSerialization.data(withJSONObject:object),as:UTF8.self)
        return String(decoding:try! JSONSerialization.data(withJSONObject:["choices":[["message":["content":content],"finish_reason":finish]],"usage":["prompt_tokens":100,"completion_tokens":100,"total_tokens":200]]),as:UTF8.self)
    }
    static func evidence(_ input:String,owner:String = "Anna",overview:Bool = false)->[String:Any] {
        let ids = (1...100).filter { input.contains("[[S\($0)]]") }.map { "S\($0)" }
        var facts:[[String:Any]] = ids.map { ["kind":"action","text":"Consegnare task \($0) con a|b","refs":[$0],"owner":owner,"deadline":"venerdì","status":"Pianificata esplicitamente","dependencies":"collaudo","commitment":"agreed"] }
        if input.contains("[[N]]") { facts.append(["kind":"decision","text":"Ipotesi personale da verificare","refs":["N"]]) }
        var object:[String:Any] = ["facts":facts]
        if overview,let id = ids.first { object["overview"] = [["kind":"summary","text":"Consegne concordate","refs":[id]]] }
        return object
    }
    static func run() async -> Int {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [OperationalMock.self]
        let session = URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("operational-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var failures = 0
        var short = Meeting(title:"Synthetic project",sources:[.system],destination:root,keepAudio:false)
        short.segments = [Segment(source:.system,start:0,end:5,text:"Anna consegna il task venerdì dopo il collaudo.")]
        var long = short
        long.segments = (1...12).map { Segment(source:.system,start:Double($0),end:Double($0+1),text:"Attività \($0). "+String(repeating:"è😊 contesto tecnico ",count:650)) }
        func generate(_ meeting:Meeting,directory:URL? = nil,policy:ReportPolicy = ReportPolicy()) async throws -> String {
            try await ReportService.generate(meeting:meeting,endpoint:LocalGateway.defaultEndpoint,model:"test",key:"operational-test-token-not-secret",session:session,checkpointDirectory:directory,timing:ReportTiming(sleep:{ _ in }),policy:policy)
        }
        func check(_ name:String,_ body:() async throws->Void) async {
            OperationalMock.reportLimit = 48000;OperationalMock.inputLimit = 14000;OperationalMock.lowEffort = nil
            do { try await body();print("PASS operational report \(name)") } catch { failures += 1;print("FAIL operational report \(name): \(error)") }
        }
        await check("short report uses one structured response and local tables") {
            var requests = 0
            OperationalMock.handler = { request in requests += 1;return (200,reply(evidence(OperationalMock.user(request),overview:true))) }
            let report = try await generate(short)
            try opRequire(requests == 1 && report.contains("v6-operational") && report.contains("| Anna | venerdì |"),"one call and explicit owner/deadline")
            let table = report.split(separator:"\n").first { $0.contains("Consegnare task") && $0.hasPrefix("|") }!
            try opRequire(ReportMarkdown.cells(String(table)).count == 5 && report.contains("a\\|b"),"escaped technical pipes do not create extra columns")
            try opRequire(report.contains("Dipende da: collaudo") && report.contains("transcript.md#"),"dependency and navigable evidence preserved")
        }
        await check("structured action proposals preserve stable transcript evidence") {
            OperationalMock.handler = { request in (200,reply(evidence(OperationalMock.user(request),overview:true))) }
            let result = try await ReportService.generateOperational(meeting:short,endpoint:LocalGateway.defaultEndpoint,model:"test",key:"operational-test-token-not-secret",session:session)
            try opRequire(result.actions.count == 1 && result.actions[0].owner == "Anna" && result.actions[0].deadline == "venerdì", "structured values retained")
            try opRequire(result.actions[0].sources.first?.segmentID == short.segments[0].id && result.actions[0].sources.first?.quote == short.segments[0].text, "stable source with snapshot")
        }
        await check("large advertised blocks reduce calls to extractions plus one overview") {
            var extraction = 0,summary = 0,bounded = true
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request);bounded = bounded && input.utf8.count <= 48000
                if input.hasPrefix("FONTI") { extraction += 1;return (200,reply(evidence(input))) }
                summary += 1
                return (200,reply(["facts":[],"overview":[["kind":"summary","text":"Avanzamenti e consegne","refs":["S1"]]]]))
            }
            let report = try await generate(long)
            try opRequire(extraction < 12 && summary == 1 && bounded,"larger inputs, one final AI overview, no section rewriting")
            try opRequire((1...12).allSatisfy { report.contains("task S\($0)") },"all distinct activities survive local rendering")
        }
        await check("low effort is opt-in and part of checkpoint identity") {
            let folder = root.appendingPathComponent("effort");var profiles:[String] = []
            OperationalMock.handler = { request in
                profiles.append(OperationalMock.payload(request)["reasoning_effort"] as? String ?? "standard")
                return (200,reply(evidence(OperationalMock.user(request),overview:true)))
            }
            _ = try await generate(short,directory:folder)
            OperationalMock.lowEffort = true
            _ = try await generate(short,directory:folder)
            _ = try await generate(short,directory:folder)
            try opRequire(profiles == ["standard","low"],"old gateways get no new parameter and low profile does not reuse a standard-profile result")
        }
        await check("old gateways retain the declared small input budget") {
            OperationalMock.reportLimit = nil;OperationalMock.inputLimit = 6000
            var bounded = true
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request);bounded = bounded && input.utf8.count <= 6000
                return input.hasPrefix("FONTI") ? (200,reply(evidence(input))):(200,reply(["facts":[],"overview":[["kind":"summary","text":"Sintesi","refs":["S1"]]]]))
            }
            var sample = long;sample.segments = Array(long.segments.prefix(3))
            _ = try await generate(sample);try opRequire(bounded,"generic model limits are not ignored")
        }
        await check("unknown action fields remain unknown and notes do not become commitments") {
            var sample = short;sample.notes = "Ipotesi personale"
            OperationalMock.handler = { request in
                (200,reply(["facts":[["kind":"action","text":"Verificare requisito","refs":["S1"]],["kind":"action","text":"Proposta personale","refs":["N"],"owner":"Anna","commitment":"agreed"]]]))
            }
            let report = try await generate(sample)
            try opRequire(report.contains("| Da assegnare | Non indicata | Non indicato; Da confermare"),"no invented status/owner/date")
            try opRequire(report.contains("## Note personali") && report.contains("Persona indicata: Anna"),"personal-note metadata is retained separately")
            let actions = report.components(separatedBy:"## Attività e responsabilità")[1].components(separatedBy:"## Rischi")[0]
            try opRequire(!actions.contains("Proposta personale"),"personal hypothesis is not a project commitment")
        }
        await check("evidence requests constrain the answer with a strict JSON schema") {
            var extraction:[[String:Any]] = [],summary:[[String:Any]] = []
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request)
                let format = OperationalMock.payload(request)["response_format"] as? [String:Any] ?? [:]
                let schema = (format["json_schema"] as? [String:Any])?["schema"] as? [String:Any] ?? [:]
                if input.hasPrefix("FONTI") { extraction.append(format["type"] as? String == "json_schema" ? schema:[:]);return (200,reply(evidence(input))) }
                summary.append(schema)
                return (200,reply(["facts":[],"overview":[["kind":"summary","text":"Sintesi","refs":["S1"]]]]))
            }
            _ = try await generate(long)
            func required(_ schema:[String:Any])->Set<String> { Set(schema["required"] as? [String] ?? []) }
            try opRequire(extraction.count > 1 && extraction.allSatisfy { required($0) == ["facts"] && $0["additionalProperties"] as? Bool == false },"multi-block extraction allows facts only")
            try opRequire(summary.count == 1 && required(summary[0]) == ["facts","overview"],"overview request requires the overview")
            let item = (((extraction[0]["properties"] as? [String:Any])?["facts"] as? [String:Any])?["items"] as? [String:Any]) ?? [:]
            let kinds = ((item["properties"] as? [String:Any])?["kind"] as? [String:Any])?["enum"] as? [String] ?? []
            try opRequire(Set(kinds) == ["fact","decision","action","risk","opportunity","question","note","conflict"] && required(item).count == 8 && item["additionalProperties"] as? Bool == false,"records are closed, with the accepted kinds only")
        }
        await check("a gateway refusing the schema falls back once to the prompt contract") {
            var constrained = 0,plain = 0
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request)
                if OperationalMock.payload(request)["response_format"] != nil { constrained += 1;return (400,#"{"error":{"code":"backend_invalid_request"}}"#) }
                plain += 1
                return input.hasPrefix("FONTI") ? (200,reply(evidence(input))):(200,reply(["facts":[],"overview":[["kind":"summary","text":"Sintesi","refs":["S1"]]]]))
            }
            let report = try await generate(long)
            try opRequire(constrained == 1 && plain > 2 && report.contains("task S12"),"one refusal, then the whole report without the parameter")
        }
        await check("failed final resumes without re-extracting successful blocks") {
            let folder = root.appendingPathComponent("resume");var extractions = 0
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request)
                if input.hasPrefix("FONTI") { extractions += 1;return (200,reply(evidence(input))) }
                return (429,#"{"error":{"code":"backend_daily_quota"}}"#)
            }
            do { _ = try await generate(long,directory:folder);throw OperationalFailure.failed("quota ignored") } catch let error as ReportServiceError { try opRequire(error.kind == .backendQuota,"quota classified") }
            let before = extractions
            OperationalMock.handler = { request in
                if OperationalMock.user(request).hasPrefix("FONTI") { extractions += 1 }
                return (200,reply(["facts":[],"overview":[["kind":"summary","text":"Sintesi","refs":["S1"]]]]))
            }
            _ = try await generate(long,directory:folder);try opRequire(extractions == before,"successful extractions reused")
            var calls = 0;OperationalMock.handler = { _ in calls += 1;return (500,"") }
            _ = try await generate(long,directory:folder);try opRequire(calls == 0,"completed whole report uses only checkpoints")
        }
        await check("oversize output splits once and remembers the smaller source layout") {
            let folder = root.appendingPathComponent("split");var largeAttempts = 0
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request)
                if input.hasPrefix("FONTI") && input.utf8.count > 22000 { largeAttempts += 1;return (422,#"{"error":{"code":"output_limit_exceeded"}}"#) }
                return input.hasPrefix("FONTI") ? (200,reply(evidence(input))):(200,reply(["facts":[],"overview":[["kind":"summary","text":"Sintesi","refs":["S1"]]]]))
            }
            let report = try await generate(long,directory:folder)
            try opRequire(largeAttempts > 0 && (1...12).allSatisfy { report.contains("task S\($0)") },"split preserves every activity and reference")
            let before = largeAttempts;_ = try await generate(long,directory:folder);try opRequire(largeAttempts == before,"oversized parents are not retried on resume")
        }
        await check("invalid large extraction is split and validated before caching") {
            let folder = root.appendingPathComponent("invalid-large")
            var invalidAttempts = 0
            OperationalMock.handler = { request in
                let input = OperationalMock.user(request)
                if input.hasPrefix("FONTI") && input.utf8.count > 22000 {
                    invalidAttempts += 1
                    return (200, reply(["facts":[["kind":"action","text":"Invalid","refs":["S999"]]]]))
                }
                return input.hasPrefix("FONTI") ? (200,reply(evidence(input))):(200,reply(["facts":[],"overview":[["kind":"summary","text":"Sintesi","refs":["S1"]]]]))
            }
            let report = try await generate(long, directory: folder)
            try opRequire(invalidAttempts > 0 && !report.contains("Invalid") && (1...12).allSatisfy { report.contains("task S\($0)") }, "only validated evidence published after split")
            let before = invalidAttempts
            _ = try await generate(long, directory: folder)
            try opRequire(invalidAttempts == before, "resume reuses validated children")
        }
        await check("invalid citations rejected and failed responses not cached") {
            let folder = root.appendingPathComponent("invalid");var attempts = 0
            OperationalMock.handler = { _ in attempts += 1;return (200,reply(["facts":[["kind":"action","text":"Inventata","refs":["S999"]]]])) }
            for _ in 0..<2 {
                do { _ = try await generate(short,directory:folder);throw OperationalFailure.failed("bad evidence published") } catch let error as ReportServiceError { try opRequire(error.kind == .invalidResponse && error.validationDetail?.contains("fonti non presenti") == true,"invalid references rejected with diagnostic") }
            }
            try opRequire(attempts == 2,"bad output not reused")
        }
        await check("cancellation and cumulative work remain bounded") {
            OperationalMock.handler = { request in (200,reply(evidence(OperationalMock.user(request)))) }
            var policy = ReportPolicy();policy.maxRequestedTokens = 1
            do { _ = try await generate(short,policy:policy);throw OperationalFailure.failed("work bound ignored") } catch let error as ReportServiceError { try opRequire(error.kind == .workLimit,"work guard retained") }
            let task = Task { try await generate(short) };task.cancel()
            do { _ = try await task.value;throw OperationalFailure.failed("cancel ignored") } catch is CancellationError {}
        }
        return failures
    }
}
