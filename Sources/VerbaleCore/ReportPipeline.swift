import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession lives here on Linux and Windows
#endif
import OSLog

/// Limits apply to one invocation, including discovery, requests and retry waits.
public struct ReportPolicy: Sendable {
    public var maxAttempts = 3
    public var maxRequests = 48
    public var maxRequestedTokens = 384_000
    public var maxOutputTokens = 16_000
    public var maxDuration: Double = 900
    public init() {}

    func budget(final: Bool, bytes: Int) -> Int {
        min(maxOutputTokens, final ? min(12_000, 6_000 + (bytes / 4_000) * 2_000)
                                  : min(8_000, 4_096 + (bytes / 4_000) * 1_024))
    }
}

/// No free text, paths, meeting identifiers, content or credentials in diagnostics.
public struct ReportMetric: Codable, Sendable {
    public var phase: String
    public var index: Int = 0
    public var count: Int = 0
    public var attempt: Int = 0
    public var budget: Int = 0
    public var duration: Double = 0
    public var httpStatus: Int?
    public var errorCode: String?
    public var requestID: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var reasoningTokens:Int?
    public var resolvedModel:String?
    public var outcome: String = "success"
    public var requestSeconds: Double = 0
    public var retryWaitSeconds: Double = 0
    public var requests: Int = 0
    public var requestedTokens: Int = 0
    public var inputBytes: Int = 0
    public var outputBytes: Int = 0
    public var records: Int = 0
}

public enum ReportDiagnostics {
    private static let logger = Logger(subsystem: "io.verbale.reports", category: "pipeline")
    public static func record(_ metric: ReportMetric) {
        guard let data = try? JSONEncoder().encode(metric), let line = String(data: data, encoding: .utf8) else { return }
        logger.info("\(line, privacy: .public)")
    }
}

/// Used only by the sequential report pipeline; no concurrent mutations.
final class ReportRun {
    let policy: ReportPolicy, timing: ReportTiming
    let observe: @Sendable (ReportMetric) -> Void
    let started: Date
    // Learn only from numeric usage, separately for similarly sized extraction
    // inputs. A successful high-budget retry must not make every later block
    // restart from an already insufficient output allowance.
    private var extractionHints:[Int:Int] = [:]
    func outputBudget(base:Int,phase:String,bytes:Int)->Int {
        guard phase == "extraction" else { return base }
        return min(policy.maxOutputTokens,max(base,extractionHints[bytes/4000] ?? 0))
    }
    var requests = 0, requestedTokens = 0
    var requestSeconds: Double = 0, retryWaitSeconds: Double = 0
    var outcome = "failed"
    var currentMetric:ReportMetric?
    init(policy: ReportPolicy, timing: ReportTiming, observe: @escaping @Sendable (ReportMetric) -> Void) {
        self.policy = policy; self.timing = timing; self.observe = observe; started = timing.now()
    }
    var remaining: Double { policy.maxDuration - timing.now().timeIntervalSince(started) }
    func check() throws {
        try Task.checkCancellation()
        guard remaining > 0 else { throw ReportServiceError(kind: .deadline, status: 0, retryAfter: nil) }
    }
    func reserve(_ budget: Int) throws {
        try check()
        guard budget > 0, budget <= policy.maxOutputTokens, requests < policy.maxRequests,
              budget <= policy.maxRequestedTokens - requestedTokens else {
            throw ReportServiceError(kind: .workLimit, status: 0, retryAfter: nil)
        }
        requests += 1; requestedTokens += budget
    }
    func finish() {
        var metric = ReportMetric(phase: "total")
        metric.duration = max(0, timing.now().timeIntervalSince(started)); metric.outcome = outcome
        metric.requestSeconds = requestSeconds; metric.retryWaitSeconds = retryWaitSeconds
        metric.requests = requests; metric.requestedTokens = requestedTokens; observe(metric)
    }
    func data(for request: URLRequest, session: URLSession, context: ReportMetric) async throws -> (Data, URLResponse) {
        try check()
        let start = timing.now(), timeout = min(request.timeoutInterval, 330, remaining)
        let timeoutKind: ReportServiceError.Kind = remaining <= min(request.timeoutInterval, 330) ? .deadline : .gatewayTimeout
        var metric = context
        currentMetric = context
        defer { currentMetric = metric; metric.duration = max(0, timing.now().timeIntervalSince(start)); requestSeconds += metric.duration; observe(metric) }
        do {
            var bounded = request; bounded.timeoutInterval = min(request.timeoutInterval, timeout)
            let boundedRequest = bounded
            // Resource deadline also covers a connection that keeps trickling bytes.
            let result = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await session.data(for: boundedRequest) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw ReportServiceError(kind: timeoutKind, status: 0, retryAfter: nil)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            metric.outputBytes = result.0.count
            if let response = result.1 as? HTTPURLResponse {
                metric.httpStatus = response.statusCode
                if let id = response.value(forHTTPHeaderField: "X-Request-Id"), UUID(uuidString: id) != nil { metric.requestID = id }
                let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
                let code = (json?["error"] as? [String: Any])?["code"] as? String
                // Explicit vocabulary: never log arbitrary upstream strings.
                let codes = ["output_limit_exceeded", "backend_rate_limit", "backend_daily_quota", "rate_limit_exceeded", "gateway_busy", "backend_timeout", "authentication_error", "backend_authentication_error", "backend_credentials_missing", "backend_credentials_invalid", "invalid_request_error", "not_found", "backend_error", "backend_protocol_error", "backend_unavailable", "client_unavailable", "backend_output_too_large", "internal_error"]
                metric.errorCode = code.map { codes.contains($0) ? $0 : "unknown" }
                let usage = json?["usage"] as? [String: Any]
                func count(_ key: String) -> Int? {
                    guard let n = usage?[key] as? Int, n >= 0 else { return nil }; return n
                }
                metric.promptTokens = count("prompt_tokens"); metric.completionTokens = count("completion_tokens"); metric.totalTokens = count("total_tokens")
                if let n = (usage?["completion_tokens_details"] as? [String:Any])?["reasoning_tokens"] as? Int,n >= 0,n <= (metric.completionTokens ?? 0) { metric.reasoningTokens = n }
                if let name = response.value(forHTTPHeaderField:"X-LLM-Resolved-Model"),name.range(of:"^claude-[A-Za-z0-9._-]{1,80}$",options:.regularExpression) != nil { metric.resolvedModel = name }
                if context.phase == "extraction",(200..<300).contains(response.statusCode),let used = metric.completionTokens,used > 0 {
                    let padded = min(policy.maxOutputTokens,used+used/5)
                    let rounded = min(policy.maxOutputTokens,((padded+1023)/1024)*1024)
                    let bucket = context.inputBytes/4000
                    extractionHints[bucket] = max(extractionHints[bucket] ?? 0,rounded)
                }
                let choices = json?["choices"] as? [[String: Any]]
                metric.outcome = metric.errorCode == "output_limit_exceeded" ? "truncated" : choices?.first?["finish_reason"] as? String == "length" ? "truncated" : ((200..<300).contains(response.statusCode) ? "success" : "http_error")
            }
            try check()
            return result
        } catch {
            if !Task.isCancelled && remaining <= 0 {
                metric.outcome = "deadline"
                throw ReportServiceError(kind: .deadline, status: 0, retryAfter: nil)
            }
            metric.outcome = Task.isCancelled ? "cancelled" : ((error as? ReportServiceError)?.kind == .deadline ? "deadline" : "transport_error")
            throw error
        }
    }
}

/// Exact record equality only: different owners, dates, negations and conflicts survive.
/// Growth is linear in distinct records; exceeding capacity stops instead of deleting facts.
struct ReportCapsule: Codable {
    struct Fact: Codable, Hashable {
        let kind: String
        let text: String
        let refs: [String]
    }
    var facts: [Fact]
    static let schema: [String: Any] = {
        let fact: [String: Any] = ["type":"object","additionalProperties":false,"required":["kind","refs","text"],"properties":[
            "kind":["type":"string","enum":["fact","decision","action","risk","opportunity","question","note","conflict"]],
            "text":["type":"string"],"refs":["type":"array","items":["type":"string"]]]]
        return ["type":"object","additionalProperties":false,"required":["facts"],"properties":["facts":["type":"array","items":fact]]]
    }()
    static func parse(_ text: String, sources: String) throws -> Self {
        var json = text.trimmingCharacters(in:.whitespacesAndNewlines)
        // Some otherwise valid providers wrap JSON in one Markdown fence.
        // Accept only that wrapper, never extract arbitrary JSON from prose.
        if (json.hasPrefix("```json\n") || json.hasPrefix("```\n")),json.hasSuffix("```") {
            json = String(json.dropFirst(json.hasPrefix("```json\n") ? 8:4).dropLast(3)).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        func invalid(_ detail: String) -> ReportServiceError {
            var error = ReportServiceError(kind: .invalidResponse, status: 200, retryAfter: nil)
            error.validationDetail = detail
            return error
        }
        guard let capsule = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else {
            throw invalid("Il modello non ha restituito il JSON richiesto per l’estrazione.")
        }
        guard capsule.facts.allSatisfy({ $0.refs.allSatisfy { sources.contains("[[\($0)]]") } }) else {
            throw invalid("Il modello ha citato fonti non presenti nella parte di trascrizione elaborata.")
        }
        guard capsule.facts.allSatisfy({ fact in
            ["fact", "decision", "action", "risk", "opportunity", "question", "note", "conflict"].contains(fact.kind)
            && !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fact.refs.isEmpty
        }) else { throw invalid("Il modello ha prodotto record con categoria, testo o fonti non validi.") }
        // "note" is often used by text models for an observation heard in the
        // call. Personal notes are defined by source N, never by that label alone.
        return Self(facts:capsule.facts.map { fact in
            let kind = fact.refs.contains("N") ? "note" : (fact.kind == "note" ? "fact":fact.kind)
            return Fact(kind:kind,text:fact.text,refs:fact.refs)
        })
    }
    func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    static func merge(_ capsules: [Self]) -> Self {
        struct Identity: Hashable { let kind: String; let text: String }
        var facts: [Fact] = [], indices: [Identity: Int] = [:]
        for fact in capsules.flatMap(\.facts) {
            let identity = Identity(kind: fact.kind, text: fact.text)
            if let index = indices[identity] {
                let previous = facts[index]
                facts[index] = Fact(kind: fact.kind, text: fact.text, refs: Array(Set(previous.refs + fact.refs)).sorted())
            } else {
                indices[identity] = facts.count
                facts.append(Fact(kind: fact.kind, text: fact.text, refs: Array(Set(fact.refs)).sorted()))
            }
        }
        return Self(facts: facts)
    }
}
