import Foundation
import CryptoKit

public struct ModelSpec: Codable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let license: String
    public let url: URL
    public let revision: String
}
public actor ModelManager {
    public nonisolated let directory: URL
    public nonisolated let catalog: [ModelSpec]
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Verbale/Models")
        let resource = Bundle.main.url(forResource: "models", withExtension: "json") ?? Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Resources")!
        catalog = try JSONDecoder().decode([ModelSpec].self, from: Data(contentsOf: resource))
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    public nonisolated func path(_ id: String) -> URL { directory.appendingPathComponent(catalog.first { $0.id == id }!.filename) }
    public func verified(_ id: String) throws -> URL {
        guard let spec = catalog.first(where: { $0.id == id }) else { throw VerbaleError.message("Modello sconosciuto") }
        let file = path(id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw VerbaleError.message("Installa il modello \(spec.filename) nella sezione Modelli.") }
        // Hashing a ~1 GB model on every job is slow: reuse the verdict while the file is unchanged on disk.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\(attributes[.systemFileNumber] ?? 0)-\(attributes[.size] ?? 0)-\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if verifiedStamps[id] == stamp { return file }
        guard try Self.digest(file) == spec.sha256 else { verifiedStamps[id] = nil; throw VerbaleError.message("Digest non valido per \(spec.filename). Importa o scarica nuovamente il modello.") }
        verifiedStamps[id] = stamp
        return file
    }
    private var verifiedStamps: [String: String] = [:]
    public func install(_ id: String, from source: URL? = nil) async throws {
        guard let spec = catalog.first(where: { $0.id == id }) else { throw VerbaleError.message("Modello sconosciuto") }
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let source { try FileManager.default.copyItem(at: source, to: temporary) }
        else {
            let (download, response) = try await URLSession.shared.download(from: spec.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VerbaleError.message("Download non riuscito: \(spec.filename)") }
            try FileManager.default.moveItem(at: download, to: temporary)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
        guard size == spec.bytes, try Self.digest(temporary) == spec.sha256 else { throw VerbaleError.message("Modello incompleto o non autentico rispetto al catalogo fissato.") }
        if FileManager.default.fileExists(atPath: path(id).path) { _ = try FileManager.default.replaceItemAt(path(id), withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: path(id)) }
    }
    public nonisolated static func digest(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var hash = SHA256()
        while let bytes = try f.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
