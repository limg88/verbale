import Foundation

/// One store per process. All mutations are serialized by the UI/processor coordinator.
public final class SessionStore {
    public let root: URL
    private let artifactVerification = ArtifactVerification()
    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Verbale/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing folder's mode untouched; recordings must stay private.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }
    public func workspace(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ meeting: Meeting) throws {
        let path = workspace(meeting.id)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("audio"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONCoding.encoder().encode(meeting).write(to: path.appendingPathComponent("meeting.json"), options: .atomic)
    }
    public func list() throws -> [Meeting] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder -> Meeting? in
            let manifest = folder.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            do { return try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: manifest)) }
            catch { CoreLog.warning("Session \(folder.lastPathComponent) skipped: manifest not readable (\(type(of: error)))"); return nil }
        }.sorted { $0.started > $1.started }
    }
    /// Session folders whose manifest exists but cannot be decoded. `list()` skips them, so the
    /// caller must tell the user: the recording is still on disk even though it is not shown.
    public func unreadableSessions() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            let manifest = folder.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return false }
            return (try? JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: manifest))) == nil
        }
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
                      !chunk.filename.hasPrefix("/"), !chunk.filename.split(separator: "/").contains(".."),
                      FileManager.default.fileExists(atPath: workspace(meeting.id).appendingPathComponent(chunk.filename).path),
                      !meeting.chunks.contains(where: { $0.id == chunk.id }) else { continue }
                meeting.chunks.append(chunk)
            }
        }
        if meeting.state == .recording || meeting.state == .processing { meeting.state = .interrupted }
        meeting.duration = max(meeting.duration, meeting.chunks.map { $0.start + $0.duration }.max() ?? 0)
        try save(meeting); return meeting
    }
    public func export(_ input: Meeting,documentsOnly:Bool = false) throws -> Meeting {
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
        let previous=(try? Data(contentsOf:target.appendingPathComponent("meeting.json"))).flatMap {try? JSONCoding.decoder().decode(Meeting.self,from:$0)}
        if let previous,previous.id != meeting.id {
            throw VerbaleError.message("La cartella appartiene a un'altra riunione. Scegli una nuova destinazione.")
        }
        // Review-only exports reuse attachments already committed by a full export.
        // Added/removed audio or screenshots, missing/corrupt metadata, or a new
        // destination always take the verified full export path.
        var reuseArtifacts=documentsOnly && previous.map { old in
            old.keepAudio==meeting.keepAudio && old.chunks.count==meeting.chunks.count &&
            zip(old.chunks,meeting.chunks).allSatisfy {$0.id==$1.id && $0.filename==$1.filename && $0.cleanedFilename==$1.cleanedFilename} &&
            old.screenshots.map(\.filename)==meeting.screenshots.map(\.filename)
        } == true
        if reuseArtifacts {
            let paths=meeting.screenshots.map(\.filename)+(meeting.keepAudio ? meeting.chunks.flatMap {[$0.filename]+($0.cleanedFilename.map{[$0]} ?? [])}:[])
            reuseArtifacts=paths.allSatisfy {FileManager.default.fileExists(atPath:target.appendingPathComponent($0).path)}
        }
        func writeDocument(_ bytes:Data,_ name:String) throws {
            let path=target.appendingPathComponent(name)
            if documentsOnly,(try? Data(contentsOf:path))==bytes {return}
            try bytes.write(to:path,options:.atomic)
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try meeting.id.uuidString.write(to: owner, atomically: true, encoding: .utf8)
        let segments = meeting.segments.sorted { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        let body = segments.map { "<a id=\"\($0.anchor)\"></a>\n\n[\(timecode($0.start))] **\(meeting.speakerName(for: $0))**: \($0.text)" }.joined(separator: "\n\n")
        let markers = meeting.markers.sorted { $0.timestamp < $1.timestamp }.map {
            "<a id=\"\($0.anchor)\"></a>\n\n- [\(timecode($0.timestamp))] \($0.kind.label)"
        }.joined(separator: "\n\n")
        let shots = meeting.screenshots.map { "- [\(timecode($0.timestamp))](\($0.filename))" }.joined(separator: "\n")
        try writeDocument(Data(("# \(meeting.title)\n\n\(body)\n\n\(markers.isEmpty ? "" : "## Momenti segnati\n\n" + markers + "\n\n")\(shots.isEmpty ? "" : "## Screenshot\n\n" + shots)\n").utf8),"transcript.md")
        try writeDocument(JSONCoding.encoder().encode(segments),"transcript.json")
        try writeDocument(Data(meeting.notes.utf8),"notes.md")
        try writeDocument(JSONCoding.encoder().encode(meeting.markers),"markers.json")
        try writeDocument(JSONCoding.encoder().encode(meeting.corrections),"corrections.json")
        if let duplicates = meeting.echoDuplicates, !duplicates.isEmpty {
            try writeDocument(JSONCoding.encoder().encode(duplicates),"echo-duplicates.json")
        }
        if let edits = meeting.transcriptBoundaryEdits, !edits.isEmpty {
            try writeDocument(JSONCoding.encoder().encode(edits),"transcript-boundaries.json")
        }
        let refinement = workspace(meeting.id).appendingPathComponent("transcription-refinement.json")
        if FileManager.default.fileExists(atPath:refinement.path) {
            try writeDocument(Data(contentsOf:refinement),"transcription-refinement.json")
        }
        if let report = meeting.reportDocument { try writeDocument(Data(report.utf8),"report.md") }
        if !reuseArtifacts { for shot in meeting.screenshots { try copyArtifact(shot.filename, meeting: meeting, target: target) } }
        if meeting.keepAudio && !reuseArtifacts {
            for chunk in meeting.chunks {
                try copyArtifact(chunk.filename, meeting: meeting, target: target)
                if let cleaned = chunk.cleanedFilename { try copyArtifact(cleaned, meeting: meeting, target: target) }
            }
        }
        meeting.exported = true
        // Commit marker is written last; earlier failures never report successful export.
        // The exported copy must be portable: it does not carry the absolute folder of this Mac.
        // The internal manifest keeps it, since it is how the app finds the export again.
        var portable = meeting; portable.destination = ""
        try writeDocument(JSONCoding.encoder().encode(portable),"meeting.json")
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
