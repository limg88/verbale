import Foundation
import VerbaleCore

private enum GatewayFailure: Error { case failed(String) }
private func gatewayAssert(_ condition: Bool, _ label: String) throws { if !condition { throw GatewayFailure.failed(label) } }
private final class GatewayMock: URLProtocol {
    static var scenario = "ok", reports = 0, requestsValid = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var status = 200, body = "", headers: [String: String] = [:]
        if path == "/health" { body = #"{"status":"ok"}"# }
        else if path == "/v1/models" { body = #"{"data":[{"id":"local/test","owned_by":"fixture"}]}"# }
        else {
            Self.reports += 1
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096), all = Data()
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; all.append(contentsOf: buffer.prefix(n)) }
                data = all
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            Self.requestsValid = Self.requestsValid && request.timeoutInterval == 330 && json?["temperature"] == nil && json?["max_tokens"] as? Int != nil && request.value(forHTTPHeaderField: "Authorization") == "Bearer integration-test-token-no-secrets"
            switch Self.scenario {
            case "quota": status = 429; body = #"{"error":{"code":"rate_limit_exceeded","message":"SECRET"}}"#
            case "login": status = 401; body = #"{"error":{"code":"backend_authentication_error","message":"SECRET"}}"#
            case "busy" where Self.reports == 1: status = 429; body = #"{"error":{"code":"gateway_busy"}}"#; headers["Retry-After"] = "0"
            case "length": status = 422; body = #"{"error":{"code":"output_limit_exceeded"}}"#
            default: body = #"{"choices":[{"message":{"content":"Decisione [[S1]]. Nota [[N]]."},"finish_reason":"stop"}]}"#
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
enum GatewayChecks {
    static let token = "integration-test-token-no-secrets"
    static func run() async -> Int {
        var failures = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GatewayMock.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Prova gateway", sources: [.system], destination: root, keepAudio: false)
        meeting.segments = [Segment(source: .system, start: 0, end: 5, text: "Decisione di prova")]; meeting.notes = "Appunto dimostrativo"
        do {
            let work = root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try token.write(to: work.appendingPathComponent("verbale-token"), atomically: true, encoding: .utf8)
            try gatewayAssert(try LocalGateway.readToken(project: root.path) == token, "token file import")
            for url in ["http://localhost:8080/v1", "http://127.0.0.1:8080/v1/", "http://[::1]:8080/v1"] { _ = try LocalGateway.baseURL(url) }
            for url in ["https://example.org/v1", "http://127.evil.example/v1", "http://user:secret@localhost/v1", "http://localhost/v1?key=secret", "http://localhost/other"] {
                do { _ = try LocalGateway.baseURL(url); throw GatewayFailure.failed("remote/unsafe URL accepted") } catch is VerbaleError {}
            }
            let models = try await LocalGateway.models(endpoint: LocalGateway.defaultEndpoint, token: token, session: session)
            try gatewayAssert(models.map(\.id) == ["local/test"], "discovery")
            GatewayMock.scenario = "ok"; GatewayMock.reports = 0; GatewayMock.requestsValid = true
            let report = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "local/test", key: token, session: session)
            try gatewayAssert(report.contains("transcript.md#") && report.contains("notes.md") && report.contains("Gateway locale / local/test") && GatewayMock.requestsValid, "report contract and references")
            print("PASS gateway loopback validation, discovery and strict report contract")
            for (scenario, expected, count) in [("quota", ReportServiceError.Kind.backendQuota, 1), ("login", .backendLogin, 1), ("length", .truncated, 2)] {
                GatewayMock.scenario = scenario; GatewayMock.reports = 0
                do { _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "local/test", key: token, session: session); throw GatewayFailure.failed("error accepted") }
                catch let error as ReportServiceError { try gatewayAssert(error.kind == expected && GatewayMock.reports == count && !error.localizedDescription.contains("SECRET"), "gateway error category / bounded retry") }
            }
            var longMeeting = meeting
            longMeeting.segments[0].text = String(repeating:"Avanzamento del progetto. ",count:1000)
            GatewayMock.scenario = "length"; GatewayMock.reports = 0
            do { _ = try await ReportService.generate(meeting:longMeeting,endpoint:LocalGateway.defaultEndpoint,model:"local/test",key:token,session:session); throw GatewayFailure.failed("oversized extraction accepted") }
            catch let error as ReportServiceError { try gatewayAssert(error.kind == .truncated && GatewayMock.reports == 2,"extraction increases output budget with bounded attempts") }
            GatewayMock.scenario = "busy"; GatewayMock.reports = 0
            _ = try await ReportService.generate(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "local/test", key: token, session: session, timing: ReportTiming(sleep: { _ in }))
            try gatewayAssert(GatewayMock.reports == 2, "gateway concurrency retry")
            print("PASS gateway separates quota/login/concurrency and bounds output retries")
        } catch { failures += 1; print("FAIL gateway contract: \(error)") }
        if let i = CommandLine.arguments.firstIndex(of: "--gateway-metadata"), CommandLine.arguments.count > i + 1 {
            do {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) as! [String: String]
                let endpoint = json["endpoint"]!
                let models = try await LocalGateway.models(endpoint: endpoint, token: token)
                try gatewayAssert(models.contains(where: { $0.id == "local/test" }), "live gateway discovery")
                try gatewayAssert(models.first(where: { $0.id == "groq/test" })?.input_limit_bytes == 6000, "gateway supplies Groq input budget")
                let groqReport = try await ReportService.generate(meeting: meeting, endpoint: endpoint, model: "groq/test", key: token)
                try gatewayAssert(groqReport.contains("transcript.md#") && groqReport.contains("Gateway locale / groq/test"), "Groq via gateway")
                let expanded = try await ReportService.generate(meeting:meeting,endpoint:endpoint,model:"local/grow",key:token)
                try gatewayAssert(expanded.contains("transcript.md#"),"actual gateway retries truncated response at 8000 tokens")
                let checkpoints = root.appendingPathComponent("checkpoint")
                let report = try await ReportService.generate(meeting: meeting, endpoint: endpoint, model: "local/test", key: token, checkpointDirectory: checkpoints)
                try gatewayAssert(report.contains("transcript.md#") && report.contains("notes.md"), "actual gateway report citations")
                let repeated = try await ReportService.generate(meeting: meeting, endpoint: endpoint, model: "local/test", key: token, checkpointDirectory: checkpoints)
                try gatewayAssert(repeated.contains("Decisione"), "actual gateway checkpoint resume")
                do { _ = try await LocalGateway.models(endpoint: endpoint, token: "invalid-token-for-test"); throw GatewayFailure.failed("bad token accepted") }
                catch let error as ReportServiceError { try gatewayAssert(error.kind == .gatewayToken, "actual token rejection") }
                for (model, expected) in [("local/quota", ReportServiceError.Kind.backendQuota), ("local/length", .truncated)] {
                    do { _ = try await ReportService.generate(meeting: meeting, endpoint: endpoint, model: model, key: token); throw GatewayFailure.failed("actual gateway failure accepted") }
                    catch let error as ReportServiceError { try gatewayAssert(error.kind == expected, "actual gateway error category") }
                }
                do { _ = try await LocalGateway.models(endpoint: json["redirect"]!, token: token); throw GatewayFailure.failed("redirect accepted") }
                catch is ReportServiceError {}
                let task = Task { try await ReportService.generate(meeting: meeting, endpoint: endpoint, model: "local/slow", key: token) }
                try await Task.sleep(nanoseconds: 200_000_000); task.cancel()
                do { _ = try await task.value; throw GatewayFailure.failed("cancel ignored") } catch is CancellationError {}
                var idle = false
                for _ in 0..<30 {
                    let (data, _) = try await LocalGateway.session.data(from: URL(string: endpoint)!.deletingLastPathComponent().appendingPathComponent("health"))
                    let h = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    if h["active_requests"] as? Int == 0 { idle = true; break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try gatewayAssert(idle, "gateway cancellation releases active request")
                print("PASS actual llm-api integration: discovery, report, resume, auth, quota, truncation, redirect blocking and cancellation (fake local and Groq backends)")
            } catch { failures += 1; print("FAIL actual gateway integration: \(error)") }
        }
        return failures
    }
}
