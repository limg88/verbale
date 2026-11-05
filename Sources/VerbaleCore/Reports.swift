import Foundation
import Security
import CryptoKit

public enum Keychain {
    public static func read(account: String = "gateway-token") -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.verbale.reports", kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static func save(_ secret: String, account: String = "gateway-token") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.verbale.reports", kSecAttrAccount as String: account]
        if secret.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, new in new }
            let s = SecItemAdd(item as CFDictionary, nil)
            guard s == errSecSuccess else { throw VerbaleError.message("Portachiavi: errore \(s)") }
        } else if status != errSecSuccess { throw VerbaleError.message("Portachiavi: errore \(status)") }
    }
}
public enum ReportService {
    private static func sources(_ meeting: Meeting) -> [(token: String, label: String, text: String, link: String)] {
        var result = meeting.segments.sorted { $0.start < $1.start }.enumerated().map { index, segment in
            (token: "S\(index + 1)", label: "TRASCRIZIONE [\(timecode(segment.start))] \(meeting.speakerName(for: segment))",
             text: segment.text, link: "transcript.md#\(segment.anchor)")
        }
        if !meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append((token: "N", label: "NOTE PERSONALI — appunti dell’utente, non parole pronunciate", text: meeting.notes, link: "notes.md"))
        }
        for (index, marker) in meeting.markers.sorted(by: { $0.timestamp < $1.timestamp }).enumerated() {
            result.append((token: "M\(index + 1)", label: "MARCATORE DELL’UTENTE [\(timecode(marker.timestamp))]",
                           text: marker.kind.label + " — indica un passaggio da esaminare, non conferma da solo una decisione o un impegno.", link: "transcript.md#\(marker.anchor)"))
        }
        return result
    }

    /// Bounded input chunks, including long notes/segments, with source identity on every fragment.
    public static func inputBatches(meeting: Meeting, limit: Int = 14000) -> [String] {
        let limit = max(512, limit)
        var batches: [String] = [], current = ""
        for source in sources(meeting) {
            let prefix = "[[\(source.token)]] \(String(source.label.unicodeScalars.prefix(60))):\n"
            var remaining = source.text[...]
            while !remaining.isEmpty {
                let budget = limit - prefix.utf8.count - 2
                let scalars = remaining.unicodeScalars
                var end = scalars.startIndex, bytes = 0
                while end < scalars.endIndex, bytes + scalars[end].utf8.count <= budget {
                    bytes += scalars[end].utf8.count; end = scalars.index(after: end)
                }
                let part = String(remaining[..<end]); remaining = remaining[end...]
                let entry = prefix + part + "\n\n"
                if current.utf8.count + entry.utf8.count > limit && !current.isEmpty { batches.append(current); current = "" }
                current += entry
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Only IDs present in this snapshot become links. Unknown references remain explicitly unverified.
    public static func resolveReferences(_ text: String, meeting: Meeting) -> String {
        let entries = sources(meeting)
        let links = Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0.link) })
        let regex = try! NSRegularExpression(pattern: #"\[\[([A-Za-z][A-Za-z0-9_-]*)\]\]"#)
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: output) else { continue }
            let token = String(text[tokenRange])
            let label: String
            if token == "N" { label = "Note personali" }
            else if let entry = entries.first(where: { $0.token == token }) { label = entry.label.replacingOccurrences(of: "TRASCRIZIONE ", with: "").replacingOccurrences(of: "MARCATORE DELL’UTENTE ", with: "") }
            else { label = "Fonte non verificata" }
            let escaped = label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            output.replaceSubrange(range, with: links[token].map { "[\(escaped)](\($0))" } ?? "(fonte non verificata)")
        }
        return output
    }

    public static func generate(meeting: Meeting, endpoint: String, model: String, key: String,
                                session: URLSession = .shared, checkpointDirectory: URL? = nil,
                                timing: ReportTiming = ReportTiming(), policy: ReportPolicy = ReportPolicy(),
                                diagnostics: @escaping @Sendable (ReportMetric) -> Void = { ReportDiagnostics.record($0) },
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let run = ReportRun(policy: policy, timing: timing, observe: diagnostics)
        defer { if Task.isCancelled { run.outcome = "cancelled" }; run.finish() }
        do {
            guard policy.maxDuration.isFinite, policy.maxDuration > 0, policy.maxOutputTokens > 0,
                  policy.maxAttempts > 0, policy.maxRequests > 0, policy.maxRequestedTokens > 0 else {
                throw ReportServiceError(kind: .workLimit, status: 0, retryAfter: nil)
            }
            try run.check()
            let base = try LocalGateway.baseURL(endpoint)
            try LocalGateway.validateToken(key)
            guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw VerbaleError.message("Scegli un modello del gateway.") }
            guard !meeting.segments.isEmpty else { throw VerbaleError.message("La trascrizione è vuota") }
            let requestSession = session === URLSession.shared ? LocalGateway.session : session
            progress("Verifica del gateway e del modello selezionato…")
            let models = try await LocalGateway.models(endpoint: endpoint, token: key, session: requestSession, transport: { request in
                try await run.data(for: request, session: requestSession, context: ReportMetric(phase: request.url?.path == "/health" ? "health" : "models"))
            })
            guard let selected = models.first(where: { $0.id == model }) else { throw VerbaleError.message("L’alias selezionato non è configurato nel gateway. Premi Verifica e aggiorna modelli nelle Impostazioni e scegli un modello disponibile.") }
            let system = ReportPrompt.system
            let limit = min(14000, max(512, selected.input_limit_bytes ?? 14000))
            // Reserve the actual instruction overhead rather than an approximate 400 bytes.
            let extractionPrefix = "FONTI DELLA RIUNIONE:\n", extractionSuffix = "\nFINE FONTI\n" + ReportPrompt.extraction
            let finalPrefix = "REPORT FINALE dalle seguenti FONTI DELLA RIUNIONE:\n", finalSuffix = "\nFINE FONTI"
            let sourceLimit = limit - max((extractionPrefix + extractionSuffix).utf8.count, (finalPrefix + finalSuffix).utf8.count)
            guard sourceLimit >= 512 else { throw ReportServiceError(kind: .tooLarge, status: 0, retryAfter: nil) }
            let batches = inputBatches(meeting: meeting, limit: sourceLimit)
            guard !batches.isEmpty else { throw VerbaleError.message("La trascrizione è vuota") }
            func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
            let identity = hash(ReportPrompt.version + "\nlocal-gateway-v1\n" + endpoint + "\n" + model + "\n" + system + "\n" + batches.joined(separator: "\u{0}"))
            let checkpoint = checkpointDirectory?.appendingPathComponent(identity + ".json")
            var cache: [String: String] = [:]
            if let checkpoint, FileManager.default.fileExists(atPath: checkpoint.path) {
                cache = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: checkpoint))) ?? [:]
            }
            let client = ReportClient(url: base.appendingPathComponent("chat/completions"), model: model, key: key,
                                      session: requestSession, run: run, progress: progress)
            func request(_ user: String, final: Bool, index: Int = 1, count: Int = 1) async throws -> String {
                let output = policy.budget(final: final, bytes: user.utf8.count)
                let phase = final ? "final" : "extraction"
                try run.check()
                let id = hash(user + "\n" + String(output))
                if let saved = cache[id] {
                    var metric = ReportMetric(phase: phase, index: index, count: count); metric.outcome = "checkpoint"; diagnostics(metric)
                    return saved
                }
                guard user.utf8.count <= limit else { throw ReportServiceError(kind: .intermediateCapacity, status: 0, retryAfter: nil) }
                let text = try await client.complete(system: final ? system : ReportPrompt.evidence, user: user, maxOutput: output,
                                                     phase: phase, index: index, count: count)
                if !final {
                    let capsule = try ReportCapsule.parse(text, sources: user)
                    var metric = ReportMetric(phase: "capsule", index: index, count: count)
                    metric.outputBytes = text.utf8.count; metric.records = capsule.facts.count; diagnostics(metric)
                }
                try run.check()
                cache[id] = text
                if let checkpoint, let checkpointDirectory {
                    try FileManager.default.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try JSONEncoder().encode(cache).write(to: checkpoint, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpoint.path)
                }
                return text
            }
            let finalText: String
            if batches.count == 1 {
                progress("Rapporto finale")
                finalText = try await request(finalPrefix + batches[0] + finalSuffix, final: true)
            } else {
                var partials: [ReportCapsule] = []
                for (index, batch) in batches.enumerated() {
                    progress("Estrazione \(index + 1) di \(batches.count)")
                    let user = extractionPrefix + batch + extractionSuffix
                    let text = try await request(user, final: false, index: index + 1, count: batches.count)
                    partials.append(try ReportCapsule.parse(text, sources: user))
                }
                // Local union never asks the model to rewrite a growing summary.
                var level = 0
                while partials.count > 1 {
                    level += 1
                    var next: [ReportCapsule] = []
                    let groups = (partials.count + 2) / 3
                    for start in stride(from: 0, to: partials.count, by: 3) {
                        try run.check()
                        let index = start / 3 + 1
                        progress("Consolidamento locale \(index) di \(groups) · livello \(level)")
                        let began = timing.now()
                        next.append(ReportCapsule.merge(Array(partials[start..<min(start + 3, partials.count)])))
                        var metric = ReportMetric(phase: "consolidation", index: index, count: groups)
                        metric.duration = max(0, timing.now().timeIntervalSince(began))
                        metric.outputBytes = try next.last!.encoded().utf8.count; metric.records = next.last!.facts.count; diagnostics(metric)
                    }
                    partials = next
                }
                progress("Rapporto finale")
                finalText = try await request("REPORT FINALE dai record della riunione (ogni record conserva le proprie fonti):\n" + partials[0].encoded(), final: true)
            }
            try Task.checkCancellation()
            try run.check()
            run.outcome = "success"
            let body = resolveReferences(finalText, meeting: meeting)
            return "# \(meeting.title)\n\n\(body)\n\n---\nGenerato con Gateway locale / \(model) · \(ISO8601DateFormatter().string(from: timing.now())) · prompt \(ReportPrompt.version)\nI rimandi identificano le fonti fornite; il contenuto del report richiede revisione.\n"
        } catch {
            run.outcome = error is CancellationError ? "cancelled" : (error as? ReportServiceError).map { String(describing: $0.kind) } ?? "failed"
            throw error
        }
    }
}
