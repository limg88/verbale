import Foundation
import VerbaleCore

private enum ReportCheckError: Error { case failed(String) }
private func require(_ value: Bool, _ label: String) throws { if !value { throw ReportCheckError.failed(label) } }
private final class ReportMock: URLProtocol {
    static var inputLimit = 14000
    static var responseDelay: Double = 0
    static var transportError: URLError.Code?
    static let stopped = ReportBox(0)
    private var delivery: DispatchWorkItem?
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
        else if request.url?.path == "/v1/models" { (status, headers, body) = (200, [:], "{\"data\":[{\"id\":\"test\",\"input_limit_bytes\":\(Self.inputLimit)}]}") }
        else {
            if let code = Self.transportError { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
            (status, headers, body) = Self.handler(request)
        }
        if Self.responseDelay > 0 && request.url?.path == "/v1/chat/completions" {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(body.utf8)); self.client?.urlProtocolDidFinishLoading(self)
            }
            delivery = work; DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay, execute: work); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { delivery?.cancel(); Self.stopped.update { $0 += 1 } }
}
private final class ReportBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func update<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    var snapshot: T { update { $0 } }
}
private final class ReportClock: @unchecked Sendable {
    let date = ReportBox(Date(timeIntervalSince1970: 0))
    func advance(_ seconds: Double) { date.update { $0 = $0.addingTimeInterval(seconds) } }
    var timing: ReportTiming { ReportTiming(now: { self.date.snapshot }, sleep: { self.advance($0) }) }
}

enum ReportChecks {
    static func reply(_ content: String, finish: String = "stop") -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]], "usage": ["prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150]]), as: UTF8.self)
    }
    static func user(_ request: URLRequest) -> String {
        (ReportMock.payload(request)["messages"] as? [[String: String]])?.last?["content"] ?? ""
    }
    static func capsule(_ user: String, duplicate: Bool = false) -> String {
        let ids = (1...20).filter { user.contains("[[S\($0)]]") }
        var facts = ids.map { ["kind": "action", "text": "Anna consegna task\($0) venerdì; pianificato; dipende dal collaudo; proposta non approvata", "refs": ["S\($0)"]] as [String: Any] }
        if duplicate {
            for id in ids {
                facts.append(["kind": "decision", "text": "Decisione: adottare piano A", "refs": ["S\(id)"]])
                facts.append(["kind": "conflict", "text": id == 1 ? "Luca contesta piano A: costo non approvato" : "Costo del piano A dichiarato approvato, fonti in conflitto", "refs": ["S\(id)"]])
            }
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["facts": duplicate ? facts + facts : facts]), as: UTF8.self)
    }
    static func run() async -> Int {
        var failures = 0, checks = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReportMock.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Synthetic", sources: [.system], destination: root, keepAudio: false)
        meeting.segments = [Segment(source: .system, start: 0, end: 5, text: "Anna consegna venerdì; proposta non approvata")]
        let key = "test-gateway-token-for-report", success = reply("Decisione [[S1]]")
        if CommandLine.arguments.contains("--report-benchmark") {
            do { try await benchmark(session: session, root: root) } catch { print("FAIL report benchmark: \(error)"); return 1 }
            return 0
        }
        func check(_ name: String, _ body: () async throws -> Void) async {
            checks += 1
            do { try await body(); print("PASS report \(name)") }
            catch { failures += 1; print("FAIL report \(name): \(error)") }
        }
        func generate(_ input: Meeting, directory: URL? = nil, policy: ReportPolicy = ReportPolicy(), timing: ReportTiming = ReportTiming(sleep: { _ in }), metrics: ReportBox<[ReportMetric]>? = nil, progress: ReportBox<[String]>? = nil) async throws -> String {
            try await ReportService.generate(meeting: input, endpoint: LocalGateway.defaultEndpoint, model: "test", key: key, session: session,
                checkpointDirectory: directory, timing: timing, policy: policy, diagnostics: { m in metrics?.update { $0.append(m) } }, progress: { p in progress?.update { $0.append(p) } })
        }
        await check("short meeting, final schema, headroom and metadata privacy") {
            let metrics = ReportBox<[ReportMetric]>([]), progress = ReportBox<[String]>([])
            var sent: [[String: Any]] = []
            let clock = ReportClock()
            ReportMock.handler = { request in
                clock.advance(3); sent.append(ReportMock.payload(request))
                return (200, ["X-Request-Id": "12345678-1234-1234-1234-123456789abc"], success)
            }
            let report = try await generate(meeting, timing: clock.timing, metrics: metrics, progress: progress)
            try require(sent.count == 1 && sent[0]["max_tokens"] as? Int == 6000, "one final request, 6000 tokens")
            let system = (sent[0]["messages"] as? [[String: String]])?.first?["content"] ?? ""
            try require(system.contains("## Decisioni") && system.contains("Responsabile | Scadenza | Stato e dipendenze | Fonti") && system.contains("Non indicata") && system.contains("Chi parla non è necessariamente il responsabile"), "PM evidence rules")
            try require(report.contains("prompt v5-records") && report.contains("transcript.md#"), "provenance and references")
            let request = metrics.snapshot.first { $0.phase == "final" }
            try require(request?.httpStatus == 200 && request?.requestID != nil && request?.completionTokens == 50 && request?.duration == 3, "request metadata and usage")
            try require(metrics.snapshot.last?.requestSeconds == 3 && metrics.snapshot.last?.duration == 3 && metrics.snapshot.last?.retryWaitSeconds == 0, "separate total/request/wait")
            let diagnostic = String(decoding: try JSONEncoder().encode(metrics.snapshot), as: UTF8.self)
            try require(!diagnostic.contains(key) && !diagnostic.contains(meeting.title) && !diagnostic.contains("Anna") && !diagnostic.contains("Decisione"), "no content in metadata")
            try require(progress.snapshot.contains("Rapporto finale") && metrics.snapshot.contains { $0.phase == "health" } && metrics.snapshot.contains { $0.phase == "models" }, "discovery and UI stages")
        }
        await check("HTTP 422 and finish_reason length get just one expansion") {
            for http in [true, false] {
                var budgets: [Int] = []
                ReportMock.handler = { request in
                    budgets.append(ReportMock.payload(request)["max_tokens"] as? Int ?? 0)
                    return budgets.count == 1 ? (http ? 422 : 200, [:], http ? #"{"error":{"code":"output_limit_exceeded","message":"PRIVATE"}}"# : reply("INCOMPLETE", finish: "length")) : (200, [:], success)
                }
                let report = try await generate(meeting)
                try require(budgets == [6000, 16000] && !report.contains("INCOMPLETE"), "one expansion straight to ceiling")
            }
            var budgets: [Int] = []
            ReportMock.handler = { request in budgets.append(ReportMock.payload(request)["max_tokens"] as? Int ?? 0); return (422, [:], #"{"error":{"code":"output_limit_exceeded"}}"#) }
            do { _ = try await generate(meeting); throw ReportCheckError.failed("published truncation") }
            catch let error as ReportServiceError { try require(error.kind == .truncated && budgets == [6000, 16000], "no repeated regenerations at ceiling") }
            let response = HTTPURLResponse(url: URL(string: LocalGateway.defaultEndpoint)!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            try require(ReportServiceError.decode(data: Data(#"{"error":{"code":"invalid_request_error"}}"#.utf8), response: response).kind == .gatewayConfig, "422 is not always truncation")
        }
        await check("429/502/503 bounded retries and separately measured waits") {
            for status in [429, 502, 503] {
                var attempts = 0
                let clock = ReportClock(), metrics = ReportBox<[ReportMetric]>([])
                ReportMock.handler = { _ in attempts += 1; clock.advance(1); return (status, [:], #"{"error":{"code":"unknown SECRET"}}"#) }
                do { _ = try await generate(meeting, timing: clock.timing, metrics: metrics); throw ReportCheckError.failed("unbounded retry") }
                catch let error as ReportServiceError { try require(error.retryable && attempts == 3, "three attempts maximum") }
                let total = metrics.snapshot.last!
                try require(total.duration == 9 && total.requestSeconds == 3 && total.retryWaitSeconds == 6 && total.requestedTokens == 18000, "3 seconds requests + 2/4 seconds waits")
                try require(!String(decoding: try JSONEncoder().encode(metrics.snapshot), as: UTF8.self).contains("SECRET"), "unknown upstream code redacted")
            }
            for code in ["backend_daily_quota", "rate_limit_exceeded", "backend_authentication_error"] {
                var attempts = 0
                ReportMock.handler = { _ in attempts += 1; return (429, [:], "{\"error\":{\"code\":\"\(code)\"}}") }
                do { _ = try await generate(meeting); throw ReportCheckError.failed("permanent failure accepted") }
                catch is ReportServiceError { try require(attempts == 1, "no retry of permanent quota/auth") }
            }
            var attempts = 0
            ReportMock.handler = { _ in attempts += 1; return (429, ["Retry-After": "120"], #"{"error":{"code":"backend_rate_limit"}}"#) }
            do { _ = try await generate(meeting); throw ReportCheckError.failed("long automatic wait") }
            catch let error as ReportServiceError { try require(error.retryAfter == 120 && attempts == 1, "long waits stop") }
        }
        await check("maximum output, cumulative work, request count and deadlines") {
            for scenario in 0..<5 {
                var policy = ReportPolicy(), attempts = 0
                let clock = ReportClock()
                switch scenario {
                case 0: policy.maxRequestedTokens = 5999
                case 1: policy.maxRequestedTokens = 21999
                case 2: policy.maxRequests = 1
                case 3: policy.maxOutputTokens = 6000
                default: policy.maxDuration = 3
                }
                ReportMock.handler = { _ in attempts += 1; if scenario == 4 { clock.advance(4) }; return (422, [:], #"{"error":{"code":"output_limit_exceeded"}}"#) }
                do { _ = try await generate(meeting, policy: policy, timing: clock.timing); throw ReportCheckError.failed("limit ignored") }
                catch let error as ReportServiceError {
                    try require(error.kind == (scenario == 4 ? .deadline : (scenario == 3 ? .truncated : .workLimit)), "specific work/deadline error")
                    try require(attempts == (scenario == 0 ? 0 : 1), "stop before exceeding work")
                }
            }
            var policy = ReportPolicy(); policy.maxDuration = 2
            let clock = ReportClock()
            ReportMock.handler = { _ in clock.advance(1); return (503, ["Retry-After": "2"], "{}") }
            do { _ = try await generate(meeting, policy: policy, timing: clock.timing); throw ReportCheckError.failed("retry beyond deadline") }
            catch let error as ReportServiceError { try require(error.kind == .deadline, "wait included in deadline") }
        }
        await check("in-flight deadline, cancellation and distinct timeout feedback") {
            ReportMock.handler = { _ in (200, [:], success) }
            ReportMock.responseDelay = 5
            defer { ReportMock.responseDelay = 0; ReportMock.transportError = nil }
            var policy = ReportPolicy(); policy.maxDuration = 0.08
            let started = Date()
            do { _ = try await generate(meeting, policy: policy); throw ReportCheckError.failed("in-flight deadline ignored") }
            catch let error as ReportServiceError { try require(error.kind == .deadline && Date().timeIntervalSince(started) < 1, "hard wall deadline interrupts request") }
            let stopped = ReportMock.stopped.snapshot
            let task = Task { try await generate(meeting) }
            try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
            do { _ = try await task.value; throw ReportCheckError.failed("in-flight cancel ignored") } catch is CancellationError {}
            try require(ReportMock.stopped.snapshot > stopped, "URLSession transport cancelled")
            ReportMock.responseDelay = 0
            ReportMock.transportError = .timedOut
            do { _ = try await generate(meeting); throw ReportCheckError.failed("network timeout ignored") }
            catch let error as ReportServiceError { try require(error.kind == .gatewayTimeout && error.localizedDescription.contains("tempo disponibile"), "timeout differs from truncation") }
        }
        var long = meeting
        long.segments = (1...8).map { Segment(source: .system, start: Double($0), end: Double($0 + 1), text: "Task\($0). " + String(repeating: "x", count: 12300)) }
        await check("long meeting, local multi-level consolidation and essential evidence") {
            let metrics = ReportBox<[ReportMetric]>([]), progress = ReportBox<[String]>([])
            var extractions = 0, finals = 0, finalUser = ""
            ReportMock.handler = { request in
                let user = user(request)
                if user.hasPrefix("FONTI DELLA RIUNIONE") {
                    extractions += 1
                    let system = (ReportMock.payload(request)["messages"] as? [[String: String]])?.first?["content"] ?? ""
                    if system.contains("## Sintesi") { return (400, [:], "{}") }
                    return (200, [:], reply(capsule(user, duplicate: true)))
                }
                finals += 1; finalUser = user
                let json = String(user.drop { $0 != "{" })
                let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
                let records = object["facts"] as! [[String: Any]]
                let text = records.map { ($0["text"] as! String) + " " + ($0["refs"] as! [String]).map { "[[\($0)]]" }.joined(separator: " ") }.joined(separator: "\n")
                return (200, [:], reply(text))
            }
            let report = try await generate(long, metrics: metrics, progress: progress)
            try require(extractions == 8 && finals == 1, "eight extractions, no LLM consolidation, one final")
            for i in 1...8 { try require(finalUser.components(separatedBy: "Anna consegna task\(i) venerdì").count == 2 && report.contains("task\(i) venerdì"), "each action appears once and reaches report") }
            try require(report.contains("dipende dal collaudo") && report.contains("proposta non approvata"), "dependencies and negation preserved")
            try require(report.contains("Luca contesta piano A: costo non approvato") && report.contains("fonti in conflitto") && finalUser.components(separatedBy: "Decisione: adottare piano A").count == 2, "decision deduplicated, opposing evidence preserved")
            try require(metrics.snapshot.filter { $0.phase == "consolidation" }.count == 4 && metrics.snapshot.last?.requests == 9, "multiple local reduce levels")
            try require(progress.snapshot.contains("Estrazione 3 di 8") && !progress.snapshot.contains { $0.contains("%") }, "honest progress")
        }
        await check("checkpoint resume after quota, full reuse, input invalidation") {
            let directory = root.appendingPathComponent("resume")
            var requests = 0
            ReportMock.handler = { request in
                requests += 1
                return requests == 2 ? (429, [:], #"{"error":{"code":"backend_daily_quota"}}"#) : (200, [:], reply(capsule(user(request))))
            }
            do { _ = try await generate(long, directory: directory); throw ReportCheckError.failed("quota ignored") }
            catch let error as ReportServiceError { try require(error.kind == .backendQuota && requests == 2, "first extraction checkpointed") }
            var extracted: [String] = []
            ReportMock.handler = { request in
                let u = user(request)
                if u.hasPrefix("FONTI DELLA RIUNIONE") { extracted.append(u); return (200, [:], reply(capsule(u))) }
                return (200, [:], success)
            }
            _ = try await generate(long, directory: directory)
            try require(extracted.count == 7 && !extracted.contains { $0.contains("Task1.") }, "successful extraction not repeated")
            extracted = []; requests = 0
            ReportMock.handler = { _ in requests += 1; return (500, [:], "{}") }
            _ = try await generate(long, directory: directory)
            try require(requests == 0, "all completed steps reused")
            var edited = long; edited.notes = "Nota personale aggiunta"
            ReportMock.handler = { request in requests += 1; return (200, [:], user(request).hasPrefix("REPORT FINALE") ? success : reply(capsule(user(request)))) }
            _ = try await generate(edited, directory: directory)
            try require(requests > 0, "changed input invalidates checkpoint")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let mode = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o600, "private checkpoint permissions")
        }
        await check("truncated final resume reuses extractions and completed final") {
            let directory = root.appendingPathComponent("final-resume")
            var finalAttempts = 0
            ReportMock.handler = { request in
                let u = user(request)
                if u.hasPrefix("REPORT FINALE") { finalAttempts += 1; return (422, [:], #"{"error":{"code":"output_limit_exceeded"}}"#) }
                return (200, [:], reply(capsule(u)))
            }
            do { _ = try await generate(long, directory: directory); throw ReportCheckError.failed("incomplete final published") }
            catch let error as ReportServiceError { try require(error.kind == .truncated && finalAttempts == 2, "bounded final truncation") }
            var users: [String] = []
            ReportMock.handler = { request in users.append(user(request)); return (200, [:], success) }
            _ = try await generate(long, directory: directory)
            try require(users.count == 1 && users[0].hasPrefix("REPORT FINALE"), "resume only failed final")
            users = []
            _ = try await generate(long, directory: directory)
            try require(users.isEmpty, "successful final checkpoint reused")
        }
        await check("declared gateway input capacity and Unicode byte bounds") {
            ReportMock.inputLimit = 6000
            defer { ReportMock.inputLimit = 14000 }
            var unicode = meeting
            unicode.segments[0].text = String(repeating: "è😊 azione. ", count: 1200)
            try require(ReportService.inputBatches(meeting: unicode, limit: 512).allSatisfy { $0.utf8.count <= 512 }, "UTF8 input batches")
            var valid = true
            ReportMock.handler = { request in
                let u = user(request); valid = valid && u.utf8.count <= 6000
                return (200, [:], u.hasPrefix("REPORT FINALE") ? success : reply(capsule(u)))
            }
            _ = try await generate(unicode)
            try require(valid, "user content includes actual instruction overhead within advertised limit")
            var empty = meeting; empty.segments[0].text = ""
            do { _ = try await generate(empty); throw ReportCheckError.failed("empty batches accepted") }
            catch is VerbaleError {}
        }
        await check("cancellation during retry and resume without successful repeats") {
            let directory = root.appendingPathComponent("cancel"), enteredWait = ReportBox(false)
            var requests = 0
            ReportMock.handler = { request in
                requests += 1
                return requests == 2 ? (503, [:], "{}") : (200, [:], reply(capsule(user(request))))
            }
            let timing = ReportTiming(sleep: { _ in enteredWait.update { $0 = true }; try await Task.sleep(nanoseconds: 10_000_000_000) })
            let task = Task { try await generate(long, directory: directory, timing: timing) }
            for _ in 0..<200 where !enteredWait.snapshot { try await Task.sleep(nanoseconds: 1_000_000) }
            try require(enteredWait.snapshot, "retry reached")
            task.cancel()
            do { _ = try await task.value; throw ReportCheckError.failed("cancellation ignored") } catch is CancellationError {}
            var extracted = 0
            ReportMock.handler = { request in
                if user(request).hasPrefix("FONTI DELLA RIUNIONE") { extracted += 1; return (200, [:], reply(capsule(user(request)))) }
                return (200, [:], success)
            }
            _ = try await generate(long, directory: directory)
            try require(extracted == 7, "cancelled work resumes after saved first extraction")
        }
        await check("oversized distinct evidence stops without lossy compaction") {
            let directory = root.appendingPathComponent("capacity")
            var requests = 0
            ReportMock.handler = { request in
                requests += 1
                let ids = (1...8).filter { user(request).contains("[[S\($0)]]") }
                let facts = ids.map { ["kind": "fact", "text": "Distinct\($0) " + String(repeating: "e", count: 3000), "refs": ["S\($0)"]] as [String: Any] }
                let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["facts": facts]), as: UTF8.self)
                return (200, [:], reply(content))
            }
            do { _ = try await generate(long, directory: directory); throw ReportCheckError.failed("capacity exceeded silently") }
            catch let error as ReportServiceError { try require(error.kind == .intermediateCapacity && requests == 8, "no expensive compaction or incomplete final") }
            requests = 0
            do { _ = try await generate(long, directory: directory); throw ReportCheckError.failed("capacity ignored on resume") }
            catch is ReportServiceError { try require(requests == 0, "all oversized evidence remains checkpointed") }
        }
        await check("invalid intermediate is not checkpointed") {
            let directory = root.appendingPathComponent("invalid")
            var requests = 0
            ReportMock.handler = { _ in requests += 1; return (200, [:], reply(#"{"facts":[{"kind":"decision","text":"Inventata","refs":["S999"]}]}"#)) }
            for _ in 0..<2 {
                do { _ = try await generate(long, directory: directory); throw ReportCheckError.failed("invalid source accepted") }
                catch let error as ReportServiceError { try require(error.kind == .invalidResponse, "invalid references rejected") }
            }
            try require(requests == 2, "invalid completed response not reused")
        }
        print("Report pipeline: \(checks) groups, \(failures) failures (fake gateway; no real inference)")
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
                    let ids = (1...8).filter { user.hasPrefix("FONTI DELLA RIUNIONE") ? user.contains("[[S\($0)]]") : user.contains("\"S\($0)\"") }
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
