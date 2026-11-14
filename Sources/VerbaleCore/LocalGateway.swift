import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession lives here on Linux and Windows
#endif

public struct GatewayModel: Decodable, Hashable, Sendable {
    public let id: String
    public let owned_by: String?
    public let input_limit_bytes: Int?
    public let report_input_limit_bytes:Int?
    public let report_low_effort:Bool?
    public let provider_type:String?
}
private final class GatewayRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum LocalGateway {
    public static let defaultEndpoint = "http://127.0.0.1:8080/v1"
    public static var defaultProject: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/llm-api").path }
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 330; config.timeoutIntervalForResource = 360
        config.urlCache = nil
        return URLSession(configuration: config, delegate: GatewayRedirectPolicy(), delegateQueue: nil)
    }()
    public static func baseURL(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint), let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1" else {
            throw VerbaleError.message("Indica l’URL locale del gateway con /v1, ad esempio http://127.0.0.1:8080/v1.")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let loopbackIP = parts.count == 4 && parts.first == "127" && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        guard ["localhost", "::1", "[::1]"].contains(host) || loopbackIP else {
            throw VerbaleError.message("La modalità Gateway locale accetta soltanto indirizzi loopback del Mac.")
        }
        return url
    }
    public static func validateToken(_ token: String) throws {
        guard token.utf8.count >= 16, token.utf8.count <= 1024, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw VerbaleError.message("Inserisci il token Bearer del gateway (almeno 16 caratteri), oppure importa il token dalla sua cartella.")
        }
    }
    public static func readToken(project: String) throws -> String {
        let url = URL(fileURLWithPath: project, isDirectory: true).appendingPathComponent("work/verbale-token")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
              ((attrs[.size] as? NSNumber)?.intValue ?? 2048) <= 1024 else {
            throw VerbaleError.message("Token locale non trovato. Prepara il collegamento nella cartella del gateway o inserisci manualmente il token Bearer.")
        }
        let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try validateToken(token)
        return token
    }
    /// Only health/discovery: never invokes a model or sends meeting content.
    public static func models(endpoint: String, token: String, session: URLSession = LocalGateway.session,
                              transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> [GatewayModel] {
        let base = try baseURL(endpoint); try validateToken(token)
        var health = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("health")); health.timeoutInterval = 5
        var discovery = URLRequest(url: base.appendingPathComponent("models")); discovery.timeoutInterval = 10
        discovery.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (index, request) in [health, discovery].enumerated() {
            let data: Data, raw: URLResponse
            do {
                if let transport { (data, raw) = try await transport(request) }
                else { (data, raw) = try await session.data(for: request) }
            }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if let failure = error as? ReportServiceError { throw failure }
                throw ReportServiceError(kind: (error as? URLError)?.code == .timedOut ? .gatewayTimeout : .gatewayUnavailable, status: 0, retryAfter: nil)
            }
            guard let response = raw as? HTTPURLResponse else { throw VerbaleError.message("Risposta del gateway non riconosciuta.") }
            guard (200..<300).contains(response.statusCode) else { throw ReportServiceError.decode(data: data, response: response) }
            if index == 0 {
                struct Health: Decodable { let status: String }
                guard let health = try? JSONDecoder().decode(Health.self, from: data), health.status == "ok" else { throw VerbaleError.message("Il servizio locale non è un gateway pronto. Controlla l’URL o attendi il riavvio.") }
            } else {
                struct Models: Decodable { let data: [GatewayModel] }
                guard let reply = try? JSONDecoder().decode(Models.self, from: data), !reply.data.isEmpty,
                      reply.data.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw VerbaleError.message("Il gateway non espone modelli validi. Configura almeno un alias in config.json.")
                }
                return Array(Set(reply.data)).sorted { $0.id < $1.id }
            }
        }
        return []
    }
}
