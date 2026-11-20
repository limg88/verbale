import Foundation
import Darwin
import os

private struct ExportDestination: Encodable {
    let schemaVersion = 1
    let destination: String
}

private struct MeetingExportSummary: Codable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let started: Date
    let timezone: String
    let duration: Double
    let state: SessionState
    let exportedAt: Date?
    let exportRevision: Int?
    let calendarEventUID: String?
    let onlineMeetingURL: URL?
    let participants: [MeetingParticipant]?

    init(_ meeting: Meeting) {
        schemaVersion = meeting.schemaVersion
        id = meeting.id
        title = meeting.title
        started = meeting.started
        timezone = meeting.timezone
        duration = meeting.duration
        state = meeting.state
        exportedAt = meeting.exportedAt
        exportRevision = meeting.exportRevision
        calendarEventUID = meeting.calendarEventUID
        onlineMeetingURL = meeting.onlineMeetingURL
        participants = meeting.participants
    }
}

/// One store per process. All mutations are serialized by the UI/processor coordinator.
public final class SessionStore {
    private static let log = Logger(subsystem: "io.verbale.app", category: "export")
    public let root: URL
    private let artifactVerification = ArtifactVerification()
    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Verbale/Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing folder's mode untouched; recordings must stay private.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }
    public func workspace(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func publishExportDestination(_ destination: URL?) throws {
        let file = root.deletingLastPathComponent().appendingPathComponent("export.json")
        if let destination {
            let publication = ExportDestination(destination: destination.standardizedFileURL.path)
            try JSONCoding.encoder().encode(publication).write(to: file, options: .atomic)
        } else {
            try removeFileIfPresent(file)
        }
    }
    private func removeFileIfPresent(_ file: URL) throws {
        try file.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            if unlink(path) != 0, errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
            }
        }
    }
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
        let manifest = target.appendingPathComponent("meeting.json")
        let summary = target.appendingPathComponent("summary.json")
        let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONCoding.decoder().decode(Meeting.self, from: $0) }
        if let previous,previous.id != meeting.id {
            throw VerbaleError.message("La cartella appartiene a un'altra riunione. Scegli una nuova destinazione.")
        }
        // The archive tracks exports across destinations. The previous summary can carry
        // the revision when a failed rewrite removed the target's manifest.
        let archived = try? read(meeting.id)
        let previousSummary = previous == nil ? (try? JSONCoding.decoder().decode(MeetingExportSummary.self, from: Data(contentsOf: summary))) : nil
        let summaryRevision = previousSummary?.id == meeting.id ? previousSummary?.exportRevision : nil
        let lastRevision = max(0, meeting.exportRevision ?? 0, archived?.exportRevision ?? 0,
                               previous?.exportRevision ?? 0, summaryRevision ?? 0)
        let (revision, overflow) = lastRevision.addingReportingOverflow(1)
        guard !overflow else { throw VerbaleError.message("Numero massimo di revisioni di esportazione raggiunto.") }
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
        let localManifest = workspace(meeting.id).appendingPathComponent("meeting.json")
        if archived == nil && !FileManager.default.fileExists(atPath: localManifest.path) { try save(meeting) }
        try removeFileIfPresent(manifest)
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
        // Once the recording is over, add a playable file per source. It is a convenience copy:
        // a failure here must not fail the export of the durable artifacts.
        if meeting.keepAudio && !reuseArtifacts && meeting.state != .recording {
            for source in meeting.sources {
                do { try PlayableAudio.write(meeting.chunks, source: source, folder: target) }
                catch { CoreLog.warning("Playable audio for \(source.rawValue) not written (\(type(of: error)))") }
            }
        }
        meeting.exportedAt = Date()
        meeting.exportRevision = revision
        var portable = meeting
        portable.exported = true
        portable.destination = ""
        if portable.participants == nil {
            let named = meeting.speakerGroups.filter { $0.name != $0.representativeID }
            if !named.isEmpty { portable.participants = named.map { MeetingParticipant(name: $0.name) } }
        }

        let encoder = JSONCoding.encoder()
        let manifestData = try encoder.encode(portable)
        // Reserve the revision in the archive before any reader can open the new manifest.
        // If publishing fails, the archive retains the revision and the meeting remains pending.
        meeting.exported = false
        try save(meeting)
        try encoder.encode(MeetingExportSummary(portable)).write(to: summary, options: .atomic)
        try manifestData.write(to: manifest, options: .atomic)

        meeting.exported = true
        do { try save(meeting) }
        catch {
            // The export is committed and the revision is durable. Keep the archived status
            // pending if this last update fails so a later retry can publish a newer revision.
            Self.log.error("Export committed but archive status update failed.")
        }
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
