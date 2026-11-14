import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession lives here on Linux and Windows
#endif

/// Verbale speaks only to the local gateway. Provider details stay behind that boundary.
public struct ReportFailureContext: Sendable {
    public let phase:String
    public let index:Int
    public let count:Int
    public let requestID:String?
    public let errorCode:String?
}
public struct ReportServiceError: LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        case gatewayToken, backendLogin, backendCredentials, gatewayBusy, backendQuota, backendRateLimit, gatewayConfig,
             gatewayUnavailable, gatewayTimeout, tooLarge, invalidResponse, truncated, workLimit, deadline, intermediateCapacity
    }
    public let kind: Kind
    public let status: Int
    public let retryAfter: Double?
    public var context:ReportFailureContext? = nil
    public var retryable: Bool { [.gatewayBusy, .backendRateLimit, .gatewayUnavailable].contains(kind) }
    public var errorDescription:String? {
        guard let context else { return explanation }
        let stages = ["extraction":"Estrazione","capsule":"Lettura scheda","final":"Rapporto finale","final_overview":"Sintesi del report","final_section":"Sezione del report","health":"Verifica gateway","models":"Verifica modello"]
        let stage = stages[context.phase] ?? "Generazione report"
        var details = [stage+(context.count > 0 ? " \(context.index)/\(context.count)":"")]
        if status > 0 { details.append("HTTP \(status)") }
        if let code = context.errorCode { details.append(code) }
        if let id = context.requestID { details.append("ID richiesta: \(id)") }
        return explanation+"\n"+details.joined(separator:" · ")
    }
    private var explanation:String {
        let wait = retryAfter.map { $0 > 86400 ? " Il ripristino richiede più di un giorno." : " Riprova fra circa \(Int(ceil($0))) secondi." } ?? ""
        switch kind {
        case .workLimit: return "Raggiunto il limite di richieste o budget complessivo. Le parti completate restano salvate; riprendi il report per continuare."
        case .deadline: return "Raggiunto il tempo massimo complessivo del report. Le parti completate restano salvate; riprendi per continuare."
        case .intermediateCapacity: return "Una singola informazione estratta è troppo estesa per la richiesta al modello. Nessun contenuto è stato tagliato: le schede completate restano salvate."
        case .gatewayToken: return "Il token del gateway locale non è valido. Importa il token dalla cartella llm-api o correggilo nelle Impostazioni."
        case .backendLogin: return "Il gateway è raggiungibile, ma il login del backend non è valido. Verifica il client ufficiale e il metodo di accesso configurato nel gateway."
        case .backendCredentials: return "La chiave del servizio scelto nel gateway è assente o non valida. Verifica la variabile API o la voce Portachiavi indicata in config.json; il token locale non è una chiave del provider."
        case .gatewayBusy: return "Il gateway sta già elaborando altre richieste.\(wait)"
        case .backendQuota: return "Il backend scelto nel gateway ha raggiunto la quota giornaliera o un limite di utilizzo.\(wait) Verifica quota e ripristino del provider prima di riprendere il report."
        case .backendRateLimit: return "Il backend scelto nel gateway richiede un’attesa fra le richieste.\(wait)"
        case .gatewayConfig: return "Il gateway non accetta il modello o i parametri richiesti. Aggiorna l’elenco modelli e verifica gli alias in config.json."
        case .gatewayUnavailable: return "Il gateway non riesce a usare il backend selezionato. Verifica client, connessione o server del modello locale."
        case .gatewayTimeout: return "Il backend non ha completato la richiesta nel tempo disponibile. Prova un modello più rapido o verifica il timeout del gateway."
        case .tooLarge: return "La richiesta supera i limiti del backend. Verifica il modello e i limiti configurati nel gateway."
        case .invalidResponse: return "Il gateway ha restituito una risposta vuota o non riconosciuta. Controlla la configurazione e riprova."
        case .truncated: return "La risposta è stata troncata perché supera il limite di lunghezza, anche dopo i tentativi automatici con un budget maggiore. Nessun report incompleto è stato pubblicato e le parti completate restano salvate."
        }
    }
    public static func duration(_ text: String?) -> Double? {
        guard let text else { return nil }
        if let n = Double(text), n.isFinite, n >= 0 { return n }
        let regex = try! NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)(ms|h|m|s)"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return nil }
        let total = matches.reduce(0.0) { sum, match in
            let n = Double(text[Range(match.range(at: 1), in: text)!])!
            let unit = String(text[Range(match.range(at: 2), in: text)!])
            return sum + n * (["ms": 0.001, "s": 1, "m": 60, "h": 3600][unit] ?? 0)
        }
        return total.isFinite ? total : nil
    }
    public static func decode(data: Data, response: HTTPURLResponse, now: Date = Date()) -> Self {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (json?["error"] as? [String: Any])?["code"] as? String ?? ""
        var retry = duration(response.value(forHTTPHeaderField: "retry-after"))
        if retry == nil, let header = response.value(forHTTPHeaderField: "retry-after") {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            retry = parser.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
        }
        let kind: Kind
        switch code {
        case "authentication_error": kind = .gatewayToken
        case "backend_authentication_error": kind = .backendLogin
        case "backend_credentials_missing", "backend_credentials_invalid": kind = .backendCredentials
        case "gateway_busy": kind = .gatewayBusy
        case "rate_limit_exceeded", "backend_daily_quota": kind = .backendQuota
        case "backend_rate_limit": kind = .backendRateLimit
        case "output_limit_exceeded": kind = .truncated
        case "backend_timeout": kind = .gatewayTimeout
        case "invalid_request_error", "not_found": kind = .gatewayConfig
        default:
            switch response.statusCode {
            case 401: kind = .gatewayToken
            case 400, 404: kind = .gatewayConfig
            case 413: kind = .tooLarge
            case 422: kind = .gatewayConfig
            case 429: kind = .backendRateLimit
            case 502, 503: kind = .gatewayUnavailable
            case 504: kind = .gatewayTimeout
            default: kind = .invalidResponse
            }
        }
        return Self(kind: kind, status: response.statusCode, retryAfter: retry)
    }
}
public struct ReportTiming: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Double) async throws -> Void
    public init(now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }) {
        self.now = now; self.sleep = sleep
    }
}
final class ReportClient {
    let url: URL, model: String, key: String, session: URLSession
    let run: ReportRun
    let reasoningEffort:String?
    let progress: @Sendable (String) -> Void
    init(url: URL, model: String, key: String, session: URLSession, run: ReportRun, progress: @escaping @Sendable (String) -> Void, reasoningEffort:String? = nil) {
        self.url = url; self.model = model; self.key = key; self.session = session; self.run = run; self.progress = progress; self.reasoningEffort = reasoningEffort
    }
    func wait(_ seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0, seconds <= 60 else { throw ReportServiceError(kind: .gatewayUnavailable, status: 0, retryAfter: seconds) }
        try run.check()
        guard seconds < run.remaining else { throw ReportServiceError(kind: .deadline, status: 0, retryAfter: nil) }
        let start = run.timing.now()
        defer {
            let duration = max(0, run.timing.now().timeIntervalSince(start))
            run.retryWaitSeconds += duration
            var metric = ReportMetric(phase: "retry_wait"); metric.duration = duration; run.observe(metric)
        }
        var remaining = seconds
        while remaining > 0 {
            try run.check()
            progress("Attesa del gateway: ripresa fra \(Int(ceil(remaining))) s")
            let step = min(1, remaining); try await run.timing.sleep(step); remaining -= step
        }
        try run.check()
    }
    func complete(system: String, user: String, maxOutput: Int, phase: String, index: Int, count: Int) async throws -> String {
        var budget = run.outputBudget(base:maxOutput,phase:phase,bytes:user.utf8.count), expanded = false
        for attempt in 1...max(1, run.policy.maxAttempts) {
            run.currentMetric = ReportMetric(phase:phase,index:index,count:count,attempt:attempt,budget:budget,inputBytes:user.utf8.count)
            try run.reserve(budget)
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 330
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var body:[String:Any] = ["model":model,"max_tokens":budget,"messages":[["role":"system","content":system],["role":"user","content":user]]]
            if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
            request.httpBody = try JSONSerialization.data(withJSONObject:body)
            let data: Data, reply: URLResponse
            do {
                (data, reply) = try await run.data(for: request, session: session,
                    context: ReportMetric(phase: phase, index: index, count: count, attempt: attempt, budget: budget, inputBytes: user.utf8.count))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let error = error as? ReportServiceError { throw error }
                throw ReportServiceError(kind: (error as? URLError)?.code == .timedOut ? .gatewayTimeout : .gatewayUnavailable, status: 0, retryAfter: nil)
            }
            guard let response = reply as? HTTPURLResponse else { throw ReportServiceError(kind: .invalidResponse, status: 0, retryAfter: nil) }
            var failure: ReportServiceError?
            if !(200..<300).contains(response.statusCode) {
                failure = ReportServiceError.decode(data: data, response: response, now: run.timing.now())
            } else {
                struct Reply: Decodable {
                    struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message; var finish_reason: String? }
                    var choices: [Choice]
                }
                guard let decoded = try? JSONDecoder().decode(Reply.self, from: data), let choice = decoded.choices.first else { throw ReportServiceError(kind: .invalidResponse, status: response.statusCode, retryAfter: nil) }
                if choice.finish_reason == "length" {
                    failure = ReportServiceError(kind: .truncated, status: response.statusCode, retryAfter: nil)
                } else {
                    guard choice.finish_reason == "stop", let content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { throw ReportServiceError(kind: .invalidResponse, status: response.statusCode, retryAfter: nil) }
                    return content
                }
            }
            guard let error = failure else { throw ReportServiceError(kind: .invalidResponse, status: response.statusCode, retryAfter: nil) }
            if error.kind == .truncated && !expanded && budget < run.policy.maxOutputTokens && attempt < run.policy.maxAttempts {
                expanded = true; budget = run.policy.maxOutputTokens
                progress("Risposta troncata · ultimo tentativo con \(budget) token")
                continue
            }
            if error.retryable && attempt < run.policy.maxAttempts {
                let delay = error.retryAfter ?? pow(2, Double(attempt))
                guard delay <= 60 else { throw error }
                progress("Gateway temporaneamente indisponibile · tentativo \(attempt + 1) di \(run.policy.maxAttempts)")
                try await wait(delay); continue
            }
            throw error
        }
        throw ReportServiceError(kind: .workLimit, status: 0, retryAfter: nil)
    }
}
