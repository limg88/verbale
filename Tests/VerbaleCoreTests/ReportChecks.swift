import Foundation
import VerbaleCore

private enum ReportCheckError: Error { case failed(String) }
private func require(_ value: Bool, _ label: String) throws { if !value { throw ReportCheckError.failed(label) } }
private final class ReportMock: URLProtocol {
    static var handler: (URLRequest) -> (Int, [String: String], String) = { _ in (500, [:], "") }
    static func payload(_ request:URLRequest)->[String:Any] {
        var data = request.httpBody
        if data == nil,let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:4096),value = Data()
            while true { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; value.append(contentsOf:buffer.prefix(n)) }
            data = value
        }
        return (data.flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int, headers: [String: String], body: String
        if request.url?.path == "/health" { (status, headers, body) = (200, [:], #"{"status":"ok"}"#) }
        else if request.url?.path == "/v1/models" { (status, headers, body) = (200, [:], #"{"data":[{"id":"test"}]}"#) }
        else { (status, headers, body) = Self.handler(request) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
enum ReportChecks {
    static func run() async -> Int {
        var failures = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReportMock.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Test", sources: [.system], destination: root, keepAudio: false)
        meeting.segments = [Segment(source: .system, start: 0, end: 5, text: "Decisione di prova")]
        let success = #"{"choices":[{"message":{"content":"Decisione [[S1]]"},"finish_reason":"stop"}]}"#
        let key = "test-gateway-token-for-report"
        if CommandLine.arguments.contains("--report-benchmark") {
            do { try await benchmark(session: session, root: root) } catch { print("FAIL report benchmark: \(error)"); return 1 }
            return 0
        }
        do {
            var budgets: [Int] = []
            ReportMock.handler = { request in
                budgets.append(ReportMock.payload(request)["max_tokens"] as? Int ?? 0)
                return (200, [:], success)
            }
            _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session)
            try require(budgets == [6000], "short report starts with phase-appropriate headroom")
            print("PASS initial phase budget")
        } catch { failures += 1; print("FAIL initial phase budget: \(error)") }
        do {
            let response = HTTPURLResponse(url: URL(string: LocalGateway.defaultEndpoint)!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After":"2"])!
            let error = ReportServiceError.decode(data: Data(#"{"error":{"code":"backend_rate_limit","message":"SECRET"}}"#.utf8), response: response)
            try require(error.kind == .backendRateLimit && error.retryable && error.retryAfter == 2 && !error.localizedDescription.contains("SECRET"), "temporary quota contract")
            try require(ReportServiceError.duration("1m2.5s") == 62.5, "duration")
            var count = 0
            ReportMock.handler = { _ in count += 1; return count == 1 ? (429, ["Retry-After":"2"], #"{"error":{"code":"backend_rate_limit"}}"#) : (200, [:], success) }
            _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session, timing: ReportTiming(sleep: { _ in }))
            try require(count == 2, "temporary backend limit retried")
            count = 0
            ReportMock.handler = { _ in count += 1; return (429, ["Retry-After":"120"], #"{"error":{"code":"backend_rate_limit"}}"#) }
            do { _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session); throw ReportCheckError.failed("unbounded wait") }
            catch let error as ReportServiceError { try require(error.retryAfter == 120 && count == 1, "long waits stop") }
            print("PASS gateway temporary quota retry, bounded waits and redaction")
        } catch { failures += 1; print("FAIL gateway retry: \(error)") }
        do {
            for httpFailure in [true,false] {
                var budgets:[Int] = []
                ReportMock.handler = { request in
                    let budget = ReportMock.payload(request)["max_tokens"] as? Int ?? 0
                    budgets.append(budget)
                    if budget < 8000 {
                        return httpFailure ? (422,[:],#"{"error":{"code":"output_limit_exceeded"}}"#) : (200,[:],#"{"choices":[{"message":{"content":"INCOMPLETE_DO_NOT_PUBLISH"},"finish_reason":"length"}]}"#)
                    }
                    return (200,[:],success)
                }
                let report = try await ReportService.generate(meeting:meeting,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session)
                try require(budgets == [4000,8000] && !report.contains("INCOMPLETE_DO_NOT_PUBLISH"),"final response retries above 4000 for HTTP and finish_reason truncation")
            }
            var budgets:[Int] = []
            ReportMock.handler = { request in
                budgets.append(ReportMock.payload(request)["max_tokens"] as? Int ?? 0)
                return (422,[:],#"{"error":{"code":"output_limit_exceeded"}}"#)
            }
            do { _ = try await ReportService.generate(meeting:meeting,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session); throw ReportCheckError.failed("unbounded truncated report") }
            catch let error as ReportServiceError { try require(error.kind == .truncated && budgets == [4000,8000,16000],"ceiling remains bounded") }
            var long = meeting
            long.segments[0].text = String(repeating:"Attività di test con responsabile e scadenza. ",count:700)
            let directory = root.appendingPathComponent("truncation-resume")
            ReportMock.handler = { request in
                let user = (ReportMock.payload(request)["messages"] as? [[String:String]])?.first(where:{ $0["role"] == "user" })?["content"] ?? ""
                return user.hasPrefix("REPORT FINALE") ? (422,[:],#"{"error":{"code":"output_limit_exceeded"}}"#):(200,[:],success)
            }
            do { _ = try await ReportService.generate(meeting:long,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session,checkpointDirectory:directory); throw ReportCheckError.failed("truncated final accepted") }
            catch let error as ReportServiceError { try require(error.kind == .truncated,"failed final preserves checkpoints") }
            var resumedUsers:[String] = []; budgets = []
            ReportMock.handler = { request in
                let payload = ReportMock.payload(request),budget = payload["max_tokens"] as? Int ?? 0
                resumedUsers.append((payload["messages"] as? [[String:String]])?.first(where:{ $0["role"] == "user" })?["content"] ?? "")
                budgets.append(budget)
                return budget < 8000 ? (422,[:],#"{"error":{"code":"output_limit_exceeded"}}"#):(200,[:],success)
            }
            _ = try await ReportService.generate(meeting:long,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session,checkpointDirectory:directory)
            try require(budgets == [4000,8000] && resumedUsers.allSatisfy { $0.hasPrefix("REPORT FINALE") },"resuming retries only the failed final and reuses extraction/consolidation")
            resumedUsers = []
            _ = try await ReportService.generate(meeting:long,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session,checkpointDirectory:directory)
            try require(resumedUsers.isEmpty,"expanded successful response is checkpointed")
            print("PASS report retries final truncation at 8000 tokens and stops at 16000 (HTTP and finish reason)")
        } catch { failures += 1; print("FAIL report output budget: \(error)") }
        do {
            var long = meeting
            long.segments = [Segment(source: .system, start: 0, end: 5, text: String(repeating: "è😊dato ", count: 3000))]
            try require(ReportService.inputBatches(meeting: long, limit: 6000).allSatisfy { $0.utf8.count <= 6000 }, "Unicode byte bounds")
            var count = 0
            ReportMock.handler = { _ in count += 1; return count == 2 ? (429, [:], #"{"error":{"code":"backend_daily_quota"}}"#) : (200, [:], success) }
            do { _ = try await ReportService.generate(meeting: long, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session, checkpointDirectory: root); throw ReportCheckError.failed("daily quota accepted") }
            catch let error as ReportServiceError { try require(error.kind == .backendQuota && count == 2, "daily quota no retries") }
            var resumed = 0
            ReportMock.handler = { _ in resumed += 1; return (200, [:], success) }
            _ = try await ReportService.generate(meeting: long, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session, checkpointDirectory: root)
            try require(resumed > 0, "unfinished work resumed")
            resumed = 0
            _ = try await ReportService.generate(meeting: long, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session, checkpointDirectory: root)
            try require(resumed == 0, "completed work reused")
            long.notes = "Nota nuova"
            _ = try await ReportService.generate(meeting: long, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session, checkpointDirectory: root)
            try require(resumed > 0, "edited inputs invalidate work")
            print("PASS report Unicode bounds, daily quota, durable resume and invalidation")
        } catch { failures += 1; print("FAIL report resume: \(error)") }
        do {
            var example = meeting
            example.segments[0].text = "Anna: il collaudo è completato. Luca aggiorna il piano entro venerdì. Il fornitore non ha ancora consegnato: rischio di ritardo. Valutiamo un'automazione, nessuna decisione presa."
            example.notes = "Ipotesi personale: assegnare un secondo sviluppatore."
            var sent:[[String:Any]] = []
            ReportMock.handler = { request in
                sent.append(ReportMock.payload(request))
                return (200,[:],success)
            }
            let shortReport = try await ReportService.generate(meeting:example,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session)
            let messages = sent.first?["messages"] as? [[String:String]] ?? []
            let system = messages.first(where:{ $0["role"] == "system" })?["content"] ?? ""
            let user = messages.first(where:{ $0["role"] == "user" })?["content"] ?? ""
            try require(sent.count == 1 && user.hasPrefix("REPORT FINALE") && user.contains(example.segments[0].text),"short calls request a full report directly from original sources")
            try require(system.contains("Responsabile | Scadenza | Stato e dipendenze | Fonti") && system.contains("Chi parla non è necessariamente il responsabile") && system.contains("Da assegnare") && system.contains("Non indicata"),"PM actions and unknown ownership/deadline contract")
            try require(system.contains("## Rischi e problemi aperti") && system.contains("## Opportunità") && system.contains("## Fatti e avanzamenti") && system.contains("correzione esplicita") && system.contains("note personali"),"PM sections and evidence distinctions")
            try require(shortReport.contains("prompt v4-pm") && shortReport.contains("transcript.md#"),"PM provenance")
            sent = []
            example.segments.append(Segment(source:.system,start:6,end:10,text:String(repeating:"Aggiornamento tecnico. ",count:1700)))
            _ = try await ReportService.generate(meeting:example,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session)
            let users = sent.compactMap { ($0["messages"] as? [[String:String]])?.first(where:{ $0["role"] == "user" })?["content"] }
            try require(users.filter { $0.hasPrefix("FONTI DELLA RIUNIONE") }.count > 1 && users.contains(where:{ $0.hasPrefix("Consolida") }),"long calls extract and consolidate")
            try require(users.filter { $0.hasPrefix("REPORT FINALE") }.count == 1 && users.last?.hasPrefix("REPORT FINALE") == true,"long calls always finish with one distinct PM composition")
            try require(sent.allSatisfy { (($0["messages"] as? [[String:String]])?.first?["content"] ?? "").contains("Chi parla non è necessariamente il responsabile") },"evidence contract survives every stage")
            var requests = 0
            ReportMock.handler = { request in
                requests += 1
                let payload = ReportMock.payload(request)
                let user = (payload["messages"] as? [[String:String]])?.first(where:{ $0["role"] == "user" })?["content"] ?? ""
                // Two exact half-budget responses used to prevent the reduce step
                // from grouping anything, because the separator exceeded the cap.
                let content = user.hasPrefix("FONTI DELLA RIUNIONE") ? String(repeating:"x",count:6800):"Scheda compatta [[S1]]"
                let body = String(data:try! JSONSerialization.data(withJSONObject:["choices":[["message":["content":content],"finish_reason":"stop"]]]),encoding:.utf8)!
                return requests > 20 ? (500,[:],""):(200,[:],body)
            }
            _ = try await ReportService.generate(meeting:example,endpoint:LocalGateway.defaultEndpoint,model:"test",key:key,session:session)
            try require(requests <= 20,"exact-budget consolidation makes progress")
            print("PASS PM report: short and long calls, final composition, responsibility and evidence contract")
        } catch { failures += 1; print("FAIL PM report: \(error)") }
        do {
            ReportMock.handler = { _ in (200, [:], #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#) }
            do { _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session); throw ReportCheckError.failed("truncated response accepted") }
            catch let error as ReportServiceError { try require(error.kind == .truncated, "truncation") }
            let task = Task { try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session) }
            task.cancel()
            do { _ = try await task.value; throw ReportCheckError.failed("cancellation ignored") } catch is CancellationError {}
            print("PASS report rejects truncation and observes cancellation")
        } catch { failures += 1; print("FAIL report cancellation: \(error)") }
        return failures
    }
}

extension ReportChecks {
    /// Same fake gateway and input for both versions. No model inference or real latency.
    static func benchmark(session: URLSession, root: URL) async throws {
        for long in [false, true] {
            var meeting = Meeting(title: "Synthetic benchmark", sources: [.system], destination: root, keepAudio: false)
            meeting.segments = (1...(long ? 8 : 1)).map { i in
                Segment(source: .system, start: Double(i), end: Double(i + 1), text: "Fatto \(i): Anna consegna task\(i) venerdì. " + String(repeating: "x", count: long ? 12_300 : 30))
            }
            var budgets: [Int] = [], users: [String] = [], attempts: [String: Int] = [:]
            ReportMock.handler = { request in
                let payload = ReportMock.payload(request), budget = payload["max_tokens"] as? Int ?? 0
                let user = (payload["messages"] as? [[String: String]])?.last?["content"] ?? ""
                budgets.append(budget); users.append(user); attempts[user, default: 0] += 1
                let final = user.hasPrefix("REPORT FINALE")
                if budget < (long ? (final ? 10_000 : 7_000) : 6_000) { return (422, [:], #"{"error":{"code":"output_limit_exceeded"}}"#) }
                let content: String
                if final { content = "Rapporto sintetico completo [[S1]]" }
                else {
                    // Fixed small union: fixture models repeated information, not a claim
                    // about the compression or accuracy of a real model.
                    let ids = (1...8).filter { user.contains("[[S\($0)]]") || user.contains("\"S\($0)\"") }
                    let facts = ids.map { ["kind": "action", "text": "Anna consegna task\($0) venerdì; pianificato", "refs": ["S\($0)"]] as [String: Any] }
                    content = String(decoding: try! JSONSerialization.data(withJSONObject: ["facts": facts], options: .sortedKeys), as: UTF8.self)
                }
                let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]]), as: UTF8.self)
                return (200, [:], body)
            }
            _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: "test-gateway-token-for-report", session: session)
            let repeated = attempts.values.reduce(0) { $0 + max(0, $1 - 1) }
            let cumulative = budgets.reduce(0, +)
            // Declared latency model: 2 seconds per request + budget / 1000 seconds.
            let simulated = Double(budgets.count) * 2 + Double(cumulative) / 1000
            print("BENCH \(long ? "long" : "short") requests=\(budgets.count) requested_tokens=\(cumulative) repeated_steps=\(repeated) simulated_seconds=\(simulated) budgets=\(budgets)")
        }
    }
}
