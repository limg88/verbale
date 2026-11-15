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
    "notes.md", "markers.json", "corrections.json"
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
    for name in requiredFiles.subtracting([".verbale-id"]) {
        #expect(try mtime(name) == oldDate, "Riscritto senza modifiche: \(name)")
    }
    #expect(try mtime(".verbale-id") != oldDate)

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
    let wavNames = ["audio/microfono.wav", "audio/sistema.wav"]
    meeting = try store.export(meeting)
    for name in wavNames {
        #expect(!files.fileExists(atPath: output.appendingPathComponent(name).path))
    }
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
        screenshot.filename, microphone.filename, cleaned, system.filename,
        "audio/microfono.wav", "audio/sistema.wav"
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
    for name in wavNames {
        let wav = try Data(contentsOf: output.appendingPathComponent(name))
        #expect(wav.starts(with: Data("RIFF".utf8)))
        #expect(wav.count == 44 + samples.count * 2)
    }

    // A document-only export reuses an attachment even if its source has changed.
    try Data([4, 5, 6]).write(to: screenshotURL)
    _ = try store.export(meeting, documentsOnly: true)
    #expect(try Data(contentsOf: output.appendingPathComponent(screenshot.filename)) == Data([1, 2, 3]))
    try Data([1, 2, 3]).write(to: screenshotURL)

    // A failed update can change documents while the previous manifest is still visible.
    meeting.notes = "Revisione ancora da pubblicare"
    let missing = AudioChunk(source: .system, start: 1, sampleCount: 160, filename: "audio/missing.caf")
    meeting.chunks.append(missing)
    #expect(throws: (any Error).self) { try store.export(meeting, documentsOnly: true) }
    #expect(try Data(contentsOf: manifest) == published)
    #expect(try String(contentsOf: output.appendingPathComponent("notes.md"), encoding: .utf8) == meeting.notes)
    meeting.keepAudio = false
    meeting.report = nil
    _ = try store.export(meeting)
    #expect(try Data(contentsOf: manifest) != published)
    for name in optional {
        #expect(files.fileExists(atPath: output.appendingPathComponent(name).path))
    }
}
