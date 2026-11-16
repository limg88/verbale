import Foundation
import Testing
import VerbaleCore

// Decode the public fields as an external reader would, including the raw date string.
private struct ExportManifest: Decodable, Equatable {
    let schemaVersion: Int
    let id: String
    let title: String
    let started: String
    let timezone: String
    let duration: Double
    let state: String
    let sources: [String]
    let exported: Bool
}

private struct ExportFixture {
    let root: URL
    let destination: URL
    let store: SessionStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("verbale-export-" + UUID().uuidString)
        destination = root.appendingPathComponent("exports")
        store = try SessionStore(root: root.appendingPathComponent("private"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let requiredFiles: Set<String> = [
    ".verbale-id", "meeting.json", "transcript.md", "transcript.json",
    "notes.md", "markers.json", "corrections.json", "summary.json"
]

@Test func exportContractAndDocumentOnlyUpdates() throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let files = FileManager.default
    let store = fixture.store
    var meeting = Meeting(title: "Riunione sintetica", sources: [.system, .microphone],
                          destination: fixture.destination, keepAudio: false)
    meeting.started = Date(timeIntervalSince1970: 1_704_112_496.75)
    meeting.timezone = "Europe/Rome"
    meeting.duration = 12.5
    let output = fixture.destination.appendingPathComponent(meeting.folderName)

    func data(_ filename: String) throws -> Data {
        try Data(contentsOf: output.appendingPathComponent(filename))
    }

    meeting = try store.export(meeting)
    #expect(Set(try files.contentsOfDirectory(atPath: output.path)) == requiredFiles)
    #expect(try data(".verbale-id") == Data(meeting.id.uuidString.utf8))
    #expect(try data("notes.md").isEmpty)
    for name in ["transcript.json", "markers.json", "corrections.json"] {
        #expect(try JSONDecoder().decode([String].self, from: data(name)).isEmpty)
    }
    let initialManifest = try JSONDecoder().decode(ExportManifest.self, from: data("meeting.json"))
    #expect(initialManifest == ExportManifest(
        schemaVersion: 1, id: meeting.id.uuidString, title: "Riunione sintetica",
        started: "2024-01-01T12:34:56Z", timezone: "Europe/Rome", duration: 12.5,
        state: "recording", sources: ["system", "microphone"], exported: true
    ))

    let system = Segment(source: .system, start: 2, end: 3, text: "Sistema")
    let microphone = Segment(source: .microphone, start: 2, end: 3, text: "Microfono")
    let first = Segment(source: .system, start: 1, end: 2, text: "Prima")
    meeting.segments = [system, microphone, first]
    try meeting.addMarker(.important, at: 3)
    try meeting.correctSegment(first.id, text: "Corretta", speakerID: nil, at: meeting.started)
    meeting.state = .complete
    meeting = try store.export(meeting, documentsOnly: true)

    struct Entry: Decodable { let id: String }
    struct Correction: Decodable { let segmentID: String; let date: String }
    let segments = try JSONDecoder().decode([Entry].self, from: data("transcript.json"))
    #expect(segments.map(\.id) == [first.id, microphone.id, system.id].map(\.uuidString))
    let markers = try JSONDecoder().decode([Entry].self, from: data("markers.json"))
    #expect(markers.map(\.id) == meeting.markers.map { $0.id.uuidString })
    let corrections = try JSONDecoder().decode([Correction].self, from: data("corrections.json"))
    let correction = try #require(corrections.first)
    #expect(corrections.count == 1)
    #expect(correction.segmentID == first.id.uuidString)
    #expect(correction.date == initialManifest.started)

    let anchors = segments.map { "<a id=\"segment-\($0.id.lowercased())\"></a>" }
        + markers.map { "<a id=\"marker-\($0.id.lowercased())\"></a>" }
    let firstAnchor = "<a id=\"segment-\(first.id.uuidString.lowercased())\"></a>"
    let markerID = try #require(meeting.markers.first?.id)
    let markerAnchor = "<a id=\"marker-\(markerID.uuidString.lowercased())\"></a>"
    func expectAnchors(in markdown: String) {
        #expect(markdown.split(separator: "\n").filter { $0.hasPrefix("<a id=") }.map(String.init) == anchors)
        #expect(markdown.contains(firstAnchor + "\n\n[00:00:01] **Audio di sistema**: Corretta"))
        #expect(markdown.contains(markerAnchor + "\n\n- [00:00:03] Punto importante"))
    }
    expectAnchors(in: try String(decoding: data("transcript.md"), as: UTF8.self))

    // A fixed mtime distinguishes skipped writes from atomic replacements without sleeps.
    let oldDate = Date(timeIntervalSince1970: 1_000_000_000)
    func markFiles() throws {
        for name in requiredFiles {
            try files.setAttributes([.modificationDate: oldDate], ofItemAtPath: output.appendingPathComponent(name).path)
        }
    }
    func mtime(_ name: String) throws -> Date? {
        try files.attributesOfItem(atPath: output.appendingPathComponent(name).path)[.modificationDate] as? Date
    }
    try markFiles()
    meeting = try store.export(meeting, documentsOnly: true)
    let publicationFiles: Set<String> = [".verbale-id", "meeting.json", "summary.json"]
    for name in requiredFiles.subtracting(publicationFiles) {
        #expect(try mtime(name) == oldDate, "Riscritto senza modifiche: \(name)")
    }
    for name in publicationFiles { #expect(try mtime(name) != oldDate) }

    try meeting.changeTitle("Riunione rinominata")
    meeting.notes = "Appunto di prova"
    meeting = try store.export(meeting, documentsOnly: true)
    #expect(try files.contentsOfDirectory(atPath: fixture.destination.path) == [output.lastPathComponent])
    #expect(try data(".verbale-id") == Data(initialManifest.id.utf8))
    for name in ["transcript.json", "markers.json", "corrections.json"] {
        #expect(try mtime(name) == oldDate)
    }
    for name in ["transcript.md", "notes.md", "meeting.json"] {
        #expect(try mtime(name) != oldDate)
    }
    #expect(try data("notes.md") == Data("Appunto di prova".utf8))
    let markdown = try String(decoding: data("transcript.md"), as: UTF8.self)
    #expect(markdown.hasPrefix("# Riunione rinominata\n"))
    expectAnchors(in: markdown)
    let updated = try JSONDecoder().decode(ExportManifest.self, from: data("meeting.json"))
    #expect(updated == ExportManifest(
        schemaVersion: 1, id: initialManifest.id, title: "Riunione rinominata",
        started: initialManifest.started, timezone: "Europe/Rome", duration: 12.5,
        state: "complete", sources: ["system", "microphone"], exported: true
    ))

    try markFiles()
    _ = try store.export(meeting)
    for name in requiredFiles {
        #expect(try mtime(name) != oldDate, "L’export completo deve riscrivere \(name)")
    }

    let owner = output.appendingPathComponent(".verbale-id")
    let otherID = UUID()
    try Data(otherID.uuidString.utf8).write(to: owner)
    #expect(throws: VerbaleError.self) { try store.export(meeting) }
    // Even a matching owner marker does not override a different readable manifest.
    try Data(meeting.id.uuidString.utf8).write(to: owner)
    let otherManifest = try String(decoding: data("meeting.json"), as: UTF8.self)
        .replacingOccurrences(of: meeting.id.uuidString, with: otherID.uuidString)
    try Data(otherManifest.utf8).write(to: output.appendingPathComponent("meeting.json"))
    #expect(throws: VerbaleError.self) { try store.export(meeting) }
}

@Test func exportContractAttachmentsAndCommitMarker() throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let files = FileManager.default
    var meeting = Meeting(title: "Riunione con allegati", sources: [.microphone, .system],
                          destination: fixture.destination, keepAudio: true)
    meeting.report = "Report sintetico"
    meeting.reportStatus = "Completato"
    let segment = Segment(source: .microphone, start: 0, end: 1, text: "Prova")
    meeting.echoDuplicates = [EchoDuplicate(original: segment, systemSegments: [])]
    let boundary = """
        [{"chunkID":"\(UUID())","original":{"id":"\(segment.id)","source":"microphone",
        "start":0,"end":1,"text":"Prova","words":[]},"duplicates":[]}]
        """
    meeting.transcriptBoundaryEdits = try JSONDecoder().decode([TranscriptBoundaryEdit].self, from: Data(boundary.utf8))
    let screenshot = Screenshot(timestamp: 0, filename: "screenshots/prova.png")
    meeting.screenshots = [screenshot]
    var microphone = AudioChunk(source: .microphone, start: 0, sampleCount: 160, filename: "audio/microfono.caf")
    microphone.cleanedFilename = "audio/cleaned.caf"
    let system = AudioChunk(source: .system, start: 0, sampleCount: 160, filename: "audio/sistema.caf")
    meeting.chunks = [microphone, system]
    try store.save(meeting)
    let workspace = store.workspace(meeting.id)
    let output = fixture.destination.appendingPathComponent(meeting.folderName)
    let manifest = output.appendingPathComponent("meeting.json")
    let samples = [Float](repeating: 0.1, count: 160)
    let screenshotURL = workspace.appendingPathComponent(screenshot.filename)
    try files.createDirectory(at: screenshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: screenshotURL)
    let refinement = Data("{}".utf8)
    try refinement.write(to: workspace.appendingPathComponent("transcription-refinement.json"))
    let cleaned = try #require(microphone.cleanedFilename)
    for name in [microphone.filename, cleaned] {
        try AudioFiles.write(samples, to: workspace.appendingPathComponent(name))
    }

    // The last required audio chunk is missing, after the documents and other attachments.
    #expect(throws: (any Error).self) { try store.export(meeting) }
    #expect(files.fileExists(atPath: output.appendingPathComponent(cleaned).path))
    #expect(!files.fileExists(atPath: manifest.path))
    try AudioFiles.write(samples, to: workspace.appendingPathComponent(system.filename))
    meeting.state = .complete
    meeting = try store.export(meeting)
    let published = try Data(contentsOf: manifest)
    #expect(try JSONDecoder().decode(ExportManifest.self, from: published).exported)
    struct AttachmentPaths: Decodable {
        struct Chunk: Decodable { let filename: String; let cleanedFilename: String? }
        struct Shot: Decodable { let filename: String }
        let chunks: [Chunk]
        let screenshots: [Shot]
    }
    let attachments = try JSONDecoder().decode(AttachmentPaths.self, from: published)
    #expect(attachments.chunks.map(\.filename) == [microphone.filename, system.filename])
    #expect(attachments.chunks.compactMap(\.cleanedFilename) == [cleaned])
    #expect(attachments.screenshots.map(\.filename) == [screenshot.filename])

    let optional: Set<String> = [
        "report.md", "echo-duplicates.json", "transcript-boundaries.json", "transcription-refinement.json",
        screenshot.filename, microphone.filename, cleaned, system.filename
    ]
    let paths = try files.subpathsOfDirectory(atPath: output.path)
    let exportedFiles = Set(paths).subtracting(["audio", "screenshots"])
    #expect(exportedFiles == requiredFiles.union(optional))
    func mtime(_ path: URL) throws -> Date {
        let attributes = try files.attributesOfItem(atPath: path.path)
        let date = attributes[.modificationDate] as? Date
        return try #require(date)
    }
    let manifestDate = try mtime(manifest)
    for name in exportedFiles.subtracting(["meeting.json"]) {
        #expect(try mtime(output.appendingPathComponent(name)) <= manifestDate, "Scritto dopo il manifest: \(name)")
    }
    for name in [screenshot.filename, microphone.filename, cleaned, system.filename, "transcription-refinement.json"] {
        #expect(try Data(contentsOf: output.appendingPathComponent(name)) == Data(contentsOf: workspace.appendingPathComponent(name)))
    }
    let transcript = try String(contentsOf: output.appendingPathComponent("transcript.md"), encoding: .utf8)
    #expect(transcript.contains("[00:00:00](screenshots/prova.png)"))

    // A document-only export reuses an attachment even if its source has changed.
    try Data([4, 5, 6]).write(to: screenshotURL)
    _ = try store.export(meeting, documentsOnly: true)
    #expect(try Data(contentsOf: output.appendingPathComponent(screenshot.filename)) == Data([1, 2, 3]))
    try Data([1, 2, 3]).write(to: screenshotURL)
    try store.cleanupAudio(meeting)

    // A failed update may change documents, but it must withdraw the old manifest.
    meeting.notes = "Revisione ancora da pubblicare"
    let missing = AudioChunk(source: .system, start: 1, sampleCount: 160, filename: "audio/missing.caf")
    meeting.chunks.append(missing)
    meeting.exported = false
    let lastRevision = try #require(store.read(meeting.id).exportRevision)
    try store.save(meeting)
    #expect(throws: (any Error).self) { try store.export(meeting, documentsOnly: true) }
    #expect(!files.fileExists(atPath: manifest.path))
    #expect(try String(contentsOf: output.appendingPathComponent("notes.md"), encoding: .utf8) == meeting.notes)
    let reopened = try SessionStore(root: store.root)
    meeting = try reopened.read(meeting.id)
    #expect(meeting.notes == "Revisione ancora da pubblicare")
    #expect(meeting.chunks.last?.id == missing.id)
    #expect(!meeting.exported)
    try AudioFiles.write(samples, to: workspace.appendingPathComponent(missing.filename))
    meeting.report = nil
    meeting = try reopened.export(meeting, documentsOnly: true)
    #expect(meeting.exportRevision == lastRevision + 1)
    #expect(try Data(contentsOf: manifest) != published)
    #expect(files.fileExists(atPath: output.appendingPathComponent(missing.filename).path))
    for name in optional {
        #expect(files.fileExists(atPath: output.appendingPathComponent(name).path))
    }
}

@Test func exportDestinationPublication() throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let publication = fixture.root.appendingPathComponent("export.json")
    let files = FileManager.default
    struct Destination: Decodable, Equatable { let schemaVersion: Int; let destination: String }
    func readDestination() throws -> Destination {
        try JSONDecoder().decode(Destination.self, from: Data(contentsOf: publication))
    }

    try fixture.store.publishExportDestination(nil)
    #expect(!files.fileExists(atPath: publication.path))
    try fixture.store.publishExportDestination(fixture.destination)
    #expect(try readDestination() == Destination(schemaVersion: 1, destination: fixture.destination.path))
    let next = fixture.root.appendingPathComponent("Cartella nuova")
    try files.createDirectory(at: next, withIntermediateDirectories: true)
    try fixture.store.publishExportDestination(next)
    #expect(try readDestination() == Destination(schemaVersion: 1, destination: next.path))
    let reopened = try SessionStore(root: fixture.store.root)
    try files.removeItem(at: publication)
    try reopened.publishExportDestination(next)
    #expect(try readDestination() == Destination(schemaVersion: 1, destination: next.path))
    try reopened.publishExportDestination(nil)
    #expect(!files.fileExists(atPath: publication.path))
}

@Test func exportMetadataSummaryAndLegacyManifests() throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    var meeting = Meeting(title: "Riunione Octo", sources: [.microphone, .system],
                          destination: fixture.destination, keepAudio: false)
    meeting.state = .complete
    meeting.duration = 4
    let output = fixture.destination.appendingPathComponent(meeting.folderName)
    let manifest = output.appendingPathComponent("meeting.json")
    let summary = output.appendingPathComponent("summary.json")
    let optionalFields = ["calendarEventUID", "onlineMeetingURL", "participants", "exportedAt", "exportRevision"]
    func json(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    func checkSummary(_ fields: Set<String>) throws {
        let full = try json(manifest)
        let compact = try json(summary)
        #expect(Set(compact.keys) == fields)
        #expect(NSDictionary(dictionary: compact) == NSDictionary(dictionary: full.filter { fields.contains($0.key) }))
    }
    let basicFields: Set<String> = ["schemaVersion", "id", "title", "started", "timezone", "duration", "state", "exportedAt", "exportRevision"]

    let first = try store.export(meeting)
    #expect(first.exportRevision == 1)
    #expect(first.exportedAt != nil)
    try checkSummary(basicFields)
    let localManifest = store.workspace(meeting.id).appendingPathComponent("meeting.json")
    for file in [manifest, localManifest] {
        let legacy = try json(file).filter { !optionalFields.contains($0.key) }
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        try bytes.write(to: file)
        let decoded = try JSONCoding.decoder().decode(Meeting.self, from: bytes)
        #expect(decoded.schemaVersion == 1 && decoded.id == meeting.id)
        #expect(decoded.calendarEventUID == nil && decoded.onlineMeetingURL == nil && decoded.participants == nil)
        #expect(decoded.exportedAt == nil && decoded.exportRevision == nil)
    }
    try FileManager.default.removeItem(at: summary)
    meeting = try store.read(meeting.id)
    #expect(meeting.exportRevision == nil)

    let manual = Segment(source: .system, start: 0, end: 1, text: "Ciao", speakerID: "slot-1")
    let recognized = Segment(source: .system, start: 1, end: 2, text: "Buongiorno", speakerID: "slot-2")
    let uncertain = Segment(source: .system, start: 2, end: 3, text: "Come va?", speakerID: "slot-3")
    let secondManual = Segment(source: .microphone, start: 3, end: 4, text: "Bene")
    let unnamed = Segment(source: .microphone, start: 4, end: 5, text: "Grazie")
    meeting.segments = [manual, recognized, uncertain, secondManual, unnamed]
    try meeting.assignVoiceName("anna", to: manual.id)
    try meeting.assignVoiceName(" Anna ", to: secondManual.id)
    meeting.applyVoiceGroup([recognized.id], ranking: VoiceRanking(profileID: UUID(), name: "Bruno", score: 0.9, margin: 0.2), automatic: true)
    meeting.applyVoiceGroup([uncertain.id], ranking: VoiceRanking(profileID: UUID(), name: "Carla", score: 0.6, margin: 0.1), automatic: false)
    meeting.speakers["unused-slot"] = "Nome non più assegnato"
    meeting.calendarEventUID = "event@example.test"
    meeting.onlineMeetingURL = URL(string: "https://teams.microsoft.com/example")
    let upgraded = try store.export(meeting)
    #expect(upgraded.schemaVersion == 1 && upgraded.exportRevision == 1)
    let publicMeeting = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: manifest))
    #expect(publicMeeting.destination.isEmpty)
    #expect(try store.read(meeting.id).destination == fixture.destination.path)
    #expect(publicMeeting.calendarEventUID == meeting.calendarEventUID)
    #expect(publicMeeting.onlineMeetingURL == meeting.onlineMeetingURL)
    #expect(publicMeeting.participants == [MeetingParticipant(name: "Anna"), MeetingParticipant(name: "Bruno")])
    #expect(publicMeeting.speakers == meeting.speakers)
    try checkSummary(basicFields.union(["calendarEventUID", "onlineMeetingURL", "participants"]))

    let next = fixture.root.appendingPathComponent("second-export")
    try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
    meeting.destination = next.path
    meeting.participants = [MeetingParticipant(name: "Anna", email: "anna@example.test")]
    let moved = try store.export(meeting)
    #expect(moved.exportRevision == 2)
    let nextManifest = next.appendingPathComponent(meeting.folderName).appendingPathComponent("meeting.json")
    let decoded = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: nextManifest))
    #expect(decoded.participants == meeting.participants)
}

@Test func archiveSaveFailureDoesNotPublishAnExport() throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let files = FileManager.default
    let store = fixture.store
    var meeting = Meeting(title: "Riunione da riesportare", sources: [.system],
                          destination: fixture.destination, keepAudio: false)
    meeting.state = .complete
    meeting = try store.export(meeting)
    #expect(meeting.exportRevision == 1)

    // A file in place of the directory forces save() to fail while the old archive is still readable.
    let audio = store.workspace(meeting.id).appendingPathComponent("audio")
    try files.removeItem(at: audio)
    try Data().write(to: audio)
    let output = fixture.destination.appendingPathComponent(meeting.folderName)
    let manifest = output.appendingPathComponent("meeting.json")
    meeting.notes = "Modifica da pubblicare"
    #expect(throws: (any Error).self) { try store.export(meeting, documentsOnly: true) }
    #expect(!files.fileExists(atPath: manifest.path))
    #expect(try store.read(meeting.id).exportRevision == 1)

    try files.removeItem(at: audio)
    let newDestination = fixture.root.appendingPathComponent("new-export")
    try files.createDirectory(at: newDestination, withIntermediateDirectories: true)
    meeting.destination = newDestination.path
    let published = try store.export(meeting)
    let archived = try store.read(meeting.id)
    #expect(published.exportRevision == 2)
    #expect(archived.exportRevision == published.exportRevision)
    #expect(archived.exported)
    #expect(!files.fileExists(atPath: manifest.path))

    // A stale snapshot at the first destination must still advance past the archived revision.
    meeting.destination = fixture.destination.path
    let resumed = try store.export(meeting)
    let publicMeeting = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: manifest))
    #expect(resumed.exportRevision == 3)
    #expect(publicMeeting.exportRevision == resumed.exportRevision)
    #expect(publicMeeting.exported)
}

@Test func failedSummaryPublicationKeepsReservedRevisionPending() throws {
    let fixture = try ExportFixture()
    defer { fixture.cleanUp() }
    let files = FileManager.default
    let store = fixture.store
    var meeting = Meeting(title: "Riepilogo bloccato", sources: [.system],
                          destination: fixture.destination, keepAudio: false)
    meeting.state = .complete
    meeting = try store.export(meeting)
    let output = fixture.destination.appendingPathComponent(meeting.folderName)
    let summary = output.appendingPathComponent("summary.json")
    try files.removeItem(at: summary)
    try files.createDirectory(at: summary, withIntermediateDirectories: false)

    #expect(throws: (any Error).self) { try store.export(meeting) }
    #expect(!files.fileExists(atPath: output.appendingPathComponent("meeting.json").path))
    let pending = try store.read(meeting.id)
    #expect(pending.exportRevision == 2)
    #expect(!pending.exported)

    try files.removeItem(at: summary)
    let next = try store.export(meeting)
    #expect(next.exported)
    #expect(next.exportRevision == 3)
}
