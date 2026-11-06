import Foundation

/// One store per process. All mutations are serialized by the UI/processor coordinator.
public final class SessionStore {
    public let root: URL
    private let artifactVerification = ArtifactVerification()
    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Verbale/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func workspace(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ meeting: Meeting) throws {
        let path = workspace(meeting.id)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("audio"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONCoding.encoder().encode(meeting).write(to: path.appendingPathComponent("meeting.json"), options: .atomic)
    }
    public func list() throws -> [Meeting] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap {
            try? JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: $0.appendingPathComponent("meeting.json")))
        }.sorted { $0.started > $1.started }
    }
    public func read(_ id: UUID) throws -> Meeting {
        try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: workspace(id).appendingPathComponent("meeting.json")))
    }
    public func append(_ chunk: AudioChunk, id: UUID) throws {
        let path = workspace(id).appendingPathComponent("journal.jsonl")
        var data = try JSONEncoder().encode(chunk); data.append(10)
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let f = try FileHandle(forWritingTo: path); defer { try? f.close() }
        try f.seekToEnd(); try f.write(contentsOf: data); try f.synchronize()
    }
    /// Replay only complete, durable journal rows. A torn trailing row is ignored.
    public func recover(_ input: Meeting) throws -> Meeting {
        var meeting = input
        let path = workspace(meeting.id).appendingPathComponent("journal.jsonl")
        if let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) {
            for row in text.split(separator: "\n") {
                guard let bytes = row.data(using: .utf8), let chunk = try? JSONDecoder().decode(AudioChunk.self, from: bytes),
                      FileManager.default.fileExists(atPath: workspace(meeting.id).appendingPathComponent(chunk.filename).path),
                      !meeting.chunks.contains(where: { $0.id == chunk.id }) else { continue }
                meeting.chunks.append(chunk)
            }
        }
        if meeting.state == .recording || meeting.state == .processing { meeting.state = .interrupted }
        meeting.duration = max(meeting.duration, meeting.chunks.map { $0.start + $0.duration }.max() ?? 0)
        try save(meeting); return meeting
    }
    public func export(_ input: Meeting) throws -> Meeting {
        var meeting = input
        let destination = URL(fileURLWithPath: meeting.destination, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VerbaleError.message("Cartella di destinazione non disponibile. La sessione rimane recuperabile sul Mac.")
        }
        let target = destination.appendingPathComponent(meeting.folderName, isDirectory: true)
        let owner = target.appendingPathComponent(".verbale-id")
        if FileManager.default.fileExists(atPath: target.path) {
            guard (try? String(contentsOf: owner, encoding: .utf8)) == meeting.id.uuidString else {
                throw VerbaleError.message("La cartella esiste già e non è stata creata per questa riunione.")
            }
        }
        if let bytes = try? Data(contentsOf: target.appendingPathComponent("meeting.json")),
           let old = try? JSONCoding.decoder().decode(Meeting.self, from: bytes), old.id != meeting.id {
            throw VerbaleError.message("La cartella appartiene a un'altra riunione. Scegli una nuova destinazione.")
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try meeting.id.uuidString.write(to: owner, atomically: true, encoding: .utf8)
        let segments = meeting.segments.sorted { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        let body = segments.map { "<a id=\"\($0.anchor)\"></a>\n\n[\(timecode($0.start))] **\(meeting.speakerName(for: $0))**: \($0.text)" }.joined(separator: "\n\n")
        let markers = meeting.markers.sorted { $0.timestamp < $1.timestamp }.map {
            "<a id=\"\($0.anchor)\"></a>\n\n- [\(timecode($0.timestamp))] \($0.kind.label)"
        }.joined(separator: "\n\n")
        let shots = meeting.screenshots.map { "- [\(timecode($0.timestamp))](\($0.filename))" }.joined(separator: "\n")
        try "# \(meeting.title)\n\n\(body)\n\n\(markers.isEmpty ? "" : "## Momenti segnati\n\n" + markers + "\n\n")\(shots.isEmpty ? "" : "## Screenshot\n\n" + shots)\n".write(to: target.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try JSONCoding.encoder().encode(segments).write(to: target.appendingPathComponent("transcript.json"), options: .atomic)
        try meeting.notes.write(to: target.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try JSONCoding.encoder().encode(meeting.markers).write(to: target.appendingPathComponent("markers.json"), options: .atomic)
        try JSONCoding.encoder().encode(meeting.corrections).write(to: target.appendingPathComponent("corrections.json"), options: .atomic)
        if let duplicates = meeting.echoDuplicates, !duplicates.isEmpty {
            try JSONCoding.encoder().encode(duplicates).write(to: target.appendingPathComponent("echo-duplicates.json"), options: .atomic)
        }
        if let edits = meeting.transcriptBoundaryEdits, !edits.isEmpty {
            try JSONCoding.encoder().encode(edits).write(to:target.appendingPathComponent("transcript-boundaries.json"),options:.atomic)
        }
        let refinement = workspace(meeting.id).appendingPathComponent("transcription-refinement.json")
        if FileManager.default.fileExists(atPath:refinement.path) {
            try Data(contentsOf:refinement).write(to:target.appendingPathComponent("transcription-refinement.json"),options:.atomic)
        }
        if let report = meeting.reportDocument { try report.write(to: target.appendingPathComponent("report.md"), atomically: true, encoding: .utf8) }
        for shot in meeting.screenshots { try copyArtifact(shot.filename, meeting: meeting, target: target) }
        if meeting.keepAudio {
            for chunk in meeting.chunks {
                try copyArtifact(chunk.filename, meeting: meeting, target: target)
                if let cleaned = chunk.cleanedFilename { try copyArtifact(cleaned, meeting: meeting, target: target) }
            }
        }
        meeting.exported = true
        // Commit marker is written last; earlier failures never report successful export.
        try JSONCoding.encoder().encode(meeting).write(to: target.appendingPathComponent("meeting.json"), options: .atomic)
        try save(meeting)
        return meeting
    }
    private func copyArtifact(_ filename: String, meeting: Meeting, target: URL) throws {
        guard !filename.hasPrefix("/"), !filename.split(separator: "/").contains("..") else { throw VerbaleError.message("Percorso allegato non valido") }
        var source = workspace(meeting.id).appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: source.path), let previous = try? read(meeting.id) {
            source = URL(fileURLWithPath: previous.destination).appendingPathComponent(previous.folderName).appendingPathComponent(filename)
        }
        let output = target.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            if source.standardizedFileURL == output.standardizedFileURL { return }
            // A retry must not accept a partial copy as a successful export.
            if FileManager.default.fileExists(atPath: source.path) {
                try artifactVerification.verify(source,output)
            }
            return
        }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard try ModelManager.digest(source) == ModelManager.digest(temporary) else { throw VerbaleError.message("Verifica della copia non riuscita: \(filename)") }
        try FileManager.default.moveItem(at: temporary, to: output)
    }
    public func cleanupAudio(_ meeting: Meeting) throws {
        guard meeting.exported, meeting.state == .complete else { return }
        let folder = workspace(meeting.id).appendingPathComponent("audio")
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    /// Reversible archive removal. Exported files are deliberately outside this operation.
    @discardableResult public func trashWorkspace(_ id: UUID, testingTrash: URL? = nil) throws -> URL {
        let folder = workspace(id)
        guard FileManager.default.fileExists(atPath:folder.path) else { throw VerbaleError.message("La riunione non è più presente nell’archivio.") }
        if let testingTrash {
            try FileManager.default.createDirectory(at:testingTrash,withIntermediateDirectories:true)
            let target = testingTrash.appendingPathComponent(id.uuidString+"-"+UUID().uuidString)
            try FileManager.default.moveItem(at:folder,to:target); return target
        }
        var target: NSURL?
        try FileManager.default.trashItem(at:folder,resultingItemURL:&target)
        return target as URL? ?? folder
    }
    public func deleteWorkspace(_ id: UUID) throws { try FileManager.default.removeItem(at: workspace(id)) }
}
