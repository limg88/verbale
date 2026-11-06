import Foundation
import AVFoundation
import VerbaleCore

private var failures = 0
private func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { if !value { failures += 1; print("FAIL \(file):\(line)") } }
private func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(!value, file: file, line: line) }
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(a == b, file: file, line: line) }
private func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { XCTAssertTrue(a < b, file: file, line: line) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) { do { _ = try expression(); XCTAssertTrue(false, file: file, line: line) } catch {} }

final class SessionStoreTests {
    var temporary: URL!
    func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    func testRecoveryReplaysOnlyDurableChunksAndIsIdempotent() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        let meeting = Meeting(title: "Crash", sources: [.system], destination: temporary, keepAudio: true)
        try store.save(meeting)
        let chunk = AudioChunk(source: .system, start: 2, sampleCount: 16000, filename: "audio/block.caf")
        try Data([1]).write(to: store.workspace(meeting.id).appendingPathComponent(chunk.filename))
        try store.append(chunk, id: meeting.id)
        let f = try FileHandle(forWritingTo: store.workspace(meeting.id).appendingPathComponent("journal.jsonl"))
        try f.seekToEnd(); try f.write(contentsOf: Data("{\"torn\"".utf8)); try f.close()
        let first = try store.recover(meeting), second = try store.recover(first)
        XCTAssertEqual(first.chunks.count, 1); XCTAssertEqual(second.chunks.count, 1)
        XCTAssertEqual(first.duration, 3); XCTAssertEqual(first.state, .interrupted)
    }
    func testExportCommitsReadableFilesAndPreservesNotes() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        var meeting = Meeting(title: "Riunione / di èsempio", sources: [.microphone], destination: temporary, keepAudio: false)
        meeting.notes = "Appunto personale"; meeting.segments = [Segment(source: .microphone, start: 5, end: 7, text: "Ciao mondo")]
        meeting.state = .complete; try store.save(meeting)
        let saved = try store.export(meeting), root = temporary.appendingPathComponent(saved.folderName)
        XCTAssertTrue(saved.exported); XCTAssertFalse(saved.folderName.contains("/"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("transcript.md")).contains("Ciao mondo"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes.md")), "Appunto personale")
        let manifest = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: root.appendingPathComponent("meeting.json")))
        XCTAssertEqual(manifest.id, meeting.id)
    }
    func testMissingVolumeDoesNotDeleteRecoveryCopy() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        let meeting = Meeting(title: "Disco assente", sources: [.system], destination: temporary.appendingPathComponent("unmounted"), keepAudio: false)
        try store.save(meeting)
        XCTAssertThrowsError(try store.export(meeting))
        XCTAssertEqual(try store.read(meeting.id).id, meeting.id)
        XCTAssertFalse(try store.read(meeting.id).exported)
    }
    func testMissingAudioCannotCommitExportWhenAudioRequested() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        var meeting = Meeting(title: "Audio mancante", sources: [.system], destination: temporary, keepAudio: true)
        meeting.chunks = [AudioChunk(source: .system, start: 0, sampleCount: 16000, filename: "audio/missing.caf")]
        try store.save(meeting)
        XCTAssertThrowsError(try store.export(meeting))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(meeting.folderName).appendingPathComponent("meeting.json").path))
    }
    func testVerifiedAudioIsRecheckedAfterExternalChanges() throws {
        let store = try SessionStore(root:temporary.appendingPathComponent("store"))
        var meeting = Meeting(title:"Cache integrity",sources:[.system],destination:temporary,keepAudio:true)
        let chunk = AudioChunk(source:.system,start:0,sampleCount:4,filename:"audio/cache.caf")
        meeting.chunks = [chunk]; try store.save(meeting)
        let source = store.workspace(meeting.id).appendingPathComponent(chunk.filename)
        let output = temporary.appendingPathComponent(meeting.folderName).appendingPathComponent(chunk.filename)
        let original = Data([1,2,3,4]); try original.write(to:source)
        _ = try store.export(meeting); _ = try store.export(meeting); _ = try store.export(meeting)
        let oldDate = try FileManager.default.attributesOfItem(atPath:output.path)[.modificationDate]!
        // Same path, size and restored mtime: ctime must still invalidate the cache.
        let file = try FileHandle(forWritingTo:output); try file.write(contentsOf:Data([4,3,2,1])); try file.close()
        try FileManager.default.setAttributes([.modificationDate:oldDate],ofItemAtPath:output.path)
        XCTAssertThrowsError(try store.export(meeting))
        try original.write(to:output,options:.atomic); _ = try store.export(meeting)
        // Changes on either side, not just the exported copy, invalidate verification.
        try Data([9,9,9,9]).write(to:source,options:.atomic)
        XCTAssertThrowsError(try store.export(meeting))
        try original.write(to:source,options:.atomic); _ = try store.export(meeting)
        try FileManager.default.removeItem(at:output); _ = try store.export(meeting)
        XCTAssertEqual(try Data(contentsOf:output),original)
    }
    func testAudioRoundTripMaintainsDurationAndSamples() throws {
        let samples = (0..<16000).map { Float(sin(Double($0) * 0.05) * 0.25) }
        let path = temporary.appendingPathComponent("audio.caf")
        try AudioFiles.write(samples, to: path)
        let result = try AudioFiles.samples(path)
        XCTAssertEqual(result.count, samples.count)
        XCTAssertLessThan(zip(samples,result).map { abs($0 - $1) }.max() ?? 1, 0.0001)
    }
    func testExistingUnownedFolderIsNeverOverwritten() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        let meeting = Meeting(title: "Collisione", sources: [.system], destination: temporary, keepAudio: false)
        let folder = temporary.appendingPathComponent(meeting.folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "originale".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try store.save(meeting)
        XCTAssertThrowsError(try store.export(meeting))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.md")), "originale")
    }
    func testResampling48kStereoHasExpectedDuration() throws {
        let path = temporary.appendingPathComponent("stereo.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for c in 0..<2 { for i in 0..<48000 { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.05)) * 0.1 } }
        do { let file = try AVAudioFile(forWriting: path, settings: format.settings); try file.write(from: buffer) }
        let audio = try AudioFiles.samples(path)
        XCTAssertLessThan(abs(audio.count - 16000), 300)
        XCTAssertTrue(audio.allSatisfy { $0.isFinite })
    }
    func testSavedAudioSurvivesTemporaryCleanup() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        var meeting = Meeting(title: "Con audio", sources: [.system], destination: temporary, keepAudio: true)
        meeting.state = .complete
        let chunk = AudioChunk(source: .system, start: 0, sampleCount: 16000, filename: "audio/test.caf")
        meeting.chunks = [chunk]; try store.save(meeting)
        try AudioFiles.write([Float](repeating: 0.1, count: 16000), to: store.workspace(meeting.id).appendingPathComponent(chunk.filename))
        let saved = try store.export(meeting)
        try store.cleanupAudio(saved)
        let exportedAudio = temporary.appendingPathComponent(saved.folderName).appendingPathComponent(chunk.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedAudio.path))
        XCTAssertEqual(try AudioFiles.samples(exportedAudio).count, 16000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.workspace(meeting.id).appendingPathComponent(chunk.filename).path))
    }
    func testAudioCanBeExplicitlyExcluded() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        var meeting = Meeting(title: "Solo testo", sources: [.system], destination: temporary, keepAudio: false)
        meeting.state = .complete
        let chunk = AudioChunk(source: .system, start: 0, sampleCount: 16000, filename: "audio/test.caf")
        meeting.chunks = [chunk]; try store.save(meeting)
        try AudioFiles.write([Float](repeating: 0.1, count: 16000), to: store.workspace(meeting.id).appendingPathComponent(chunk.filename))
        let saved = try store.export(meeting)
        try store.cleanupAudio(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(saved.folderName).appendingPathComponent("audio").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.appendingPathComponent(saved.folderName).appendingPathComponent("transcript.md").path))
    }
    func testTeamsRequiresConfirmedCallAndRejectsTransientSignals() {
        let t = Date(timeIntervalSince1970: 0)
        var tracker = TeamsCallTracker()
        XCTAssertEqual(tracker.update(.active, at: t), nil)
        XCTAssertEqual(tracker.update(.inactive, at: t.addingTimeInterval(1)), nil)
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(2)), nil)
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(3)), nil)
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(4)), .callBegan)
        XCTAssertTrue(tracker.isInCall)
    }
    func testTeamsReconnectionCancelsStopAndAllowsNextCall() {
        let t = Date(timeIntervalSince1970: 0)
        var tracker = TeamsCallTracker()
        _ = tracker.update(.active, at: t)
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(2)), .callBegan)
        _ = tracker.update(.inactive, at: t.addingTimeInterval(4))
        XCTAssertEqual(tracker.update(.inactive, at: t.addingTimeInterval(22)), nil)
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(23)), nil)
        _ = tracker.update(.inactive, at: t.addingTimeInterval(24))
        XCTAssertEqual(tracker.update(.inactive, at: t.addingTimeInterval(44)), .callEnded)
        XCTAssertFalse(tracker.isInCall)
        XCTAssertEqual(tracker.update(.inactive, at: t.addingTimeInterval(46)), nil)
        _ = tracker.update(.active, at: t.addingTimeInterval(48))
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(50)), .callBegan)
    }
    func testTeamsUnknownStateCannotEndCall() {
        let t = Date(timeIntervalSince1970: 0)
        var tracker = TeamsCallTracker()
        _ = tracker.update(.active, at: t)
        _ = tracker.update(.active, at: t.addingTimeInterval(2))
        _ = tracker.update(.inactive, at: t.addingTimeInterval(4))
        XCTAssertEqual(tracker.update(.unavailable, at: t.addingTimeInterval(24)), nil)
        XCTAssertTrue(tracker.isInCall)
        XCTAssertEqual(tracker.update(.inactive, at: t.addingTimeInterval(26)), nil)
        XCTAssertEqual(tracker.update(.inactive, at: t.addingTimeInterval(46)), .callEnded)
    }
    func testTeamsDoesNotEmitRepeatedStartsDuringSameCall() {
        let t = Date(timeIntervalSince1970: 0)
        var tracker = TeamsCallTracker()
        _ = tracker.update(.active, at: t)
        XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(2)), .callBegan)
        // After manual stop, continued Teams activity must not request another start.
        for seconds in stride(from: 4, through: 100, by: 2) {
            XCTAssertEqual(tracker.update(.active, at: t.addingTimeInterval(Double(seconds))), nil)
        }
    }
    func testTeamsAssertionBelongsToTeamsAndMustBeEnabled() {
        XCTAssertTrue(TeamsCallProbe.isCallAssertion(name: "Microsoft Teams Call in progress", level: 1, bundleIdentifier: "com.microsoft.teams2"))
        XCTAssertTrue(TeamsCallProbe.isCallAssertion(name: "Microsoft Teams Call in progress", level: 255, bundleIdentifier: "com.microsoft.teams2.helper"))
        XCTAssertFalse(TeamsCallProbe.isCallAssertion(name: "Microsoft Teams Call in progress", level: 0, bundleIdentifier: "com.microsoft.teams2"))
        XCTAssertFalse(TeamsCallProbe.isCallAssertion(name: "Microsoft Teams Call in progress", level: 1, bundleIdentifier: "io.verbale.app"))
        XCTAssertFalse(TeamsCallProbe.isCallAssertion(name: "Microsoft Teams Call in progress", level: 1, bundleIdentifier: "com.microsoft.teams2other"))
        XCTAssertFalse(TeamsCallProbe.isCallAssertion(name: "Playing audio", level: 1, bundleIdentifier: "com.microsoft.teams2"))
    }
    func testLegacySessionWithoutReviewStillOpens() throws {
        var meeting = Meeting(title: "Archivio precedente", sources: [.system], destination: temporary, keepAudio: false)
        meeting.segments = [Segment(source: .system, start: 2, end: 4, text: "Testo precedente")]
        var legacy = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(meeting)) as! [String: Any]
        legacy.removeValue(forKey: "review")
        let read = try JSONCoding.decoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(read.segments.first?.text, "Testo precedente")
        XCTAssertEqual(read.markers.count, 0); XCTAssertEqual(read.corrections.count, 0)
    }
    func testCorrectionsPreserveOriginalAndInvalidateReport() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        var meeting = Meeting(title: "Revisione", sources: [.system], destination: temporary, keepAudio: false)
        let words = try JSONDecoder().decode([Word].self, from: Data("[{\"w\":\"lunedì\",\"start\":4,\"end\":5}]".utf8))
        let segment = Segment(source: .system, start: 4, end: 5, text: "lunedì", speakerID: "1", words: words)
        meeting.segments = [segment]; meeting.report = "Vecchio report"; meeting.reportStatus = "Completato"
        try meeting.correctSegment(segment.id, text: "martedì", speakerID: "2")
        try meeting.correctSegment(segment.id, text: "martedì", speakerID: nil)
        try meeting.correctSegment(segment.id, text: "martedì", speakerID: nil) // no-op
        XCTAssertEqual(meeting.corrections.count, 2)
        XCTAssertEqual(meeting.corrections.first?.previousText, "lunedì")
        XCTAssertEqual(meeting.corrections.first?.previousWords.first?.w, "lunedì")
        XCTAssertEqual(meeting.segments[0].words.count, 0)
        XCTAssertEqual(meeting.segments[0].id, segment.id); XCTAssertEqual(meeting.segments[0].start, 4)
        XCTAssertTrue(meeting.reportNeedsUpdate)
        XCTAssertThrowsError(try meeting.correctSegment(segment.id, text: "  ", speakerID: nil))
        try store.save(meeting)
        let read = try store.read(meeting.id)
        XCTAssertEqual(read.corrections.count, 2); XCTAssertEqual(read.segments[0].text, "martedì")
    }
    func testMarkerAndReportLinksSurviveExport() throws {
        let store = try SessionStore(root: temporary.appendingPathComponent("store"))
        var meeting = Meeting(title: "Fonti", sources: [.system], destination: temporary, keepAudio: false)
        let segment = Segment(source: .system, start: 6, end: 8, text: "Rivediamo la proposta")
        meeting.segments = [segment]; meeting.notes = "Una mia osservazione"
        try meeting.addMarker(.decision, at: 7)
        XCTAssertThrowsError(try meeting.addMarker(.action, at: .nan))
        XCTAssertThrowsError(try meeting.addMarker(.important, at: -1))
        meeting.report = ReportService.resolveReferences("Rivedere [[S1]]. Nota [[N]]. Momento [[M1]]. Inventato [[S999]].", meeting: meeting)
        meeting.reportStatus = "Completato"
        let saved = try store.export(meeting), folder = temporary.appendingPathComponent(saved.folderName)
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.md"))
        let report = try String(contentsOf: folder.appendingPathComponent("report.md"))
        XCTAssertTrue(transcript.contains("id=\"\(segment.anchor)\""))
        XCTAssertTrue(transcript.contains("id=\"\(meeting.markers[0].anchor)\""))
        XCTAssertTrue(report.contains("transcript.md#\(segment.anchor)"))
        XCTAssertTrue(report.contains("transcript.md#\(meeting.markers[0].anchor)"))
        XCTAssertTrue(report.contains("notes.md")); XCTAssertTrue(report.contains("fonte non verificata"))
        XCTAssertFalse(report.contains("S999"))
        let markers = try JSONCoding.decoder().decode([MeetingMarker].self, from: Data(contentsOf: folder.appendingPathComponent("markers.json")))
        XCTAssertEqual(markers.first?.id, meeting.markers.first?.id)
        var updated = saved; updated.removeMarker(meeting.markers[0].id)
        let exported = try store.export(updated)
        XCTAssertTrue(exported.reportNeedsUpdate)
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("report.md")).hasPrefix("> Da rigenerare"))
    }
    func testLongPersonalNotesRemainBoundedAndDistinct() throws {
        var meeting = Meeting(title: "Note lunghe", sources: [.system], destination: temporary, keepAudio: false)
        meeting.segments = [Segment(source: .system, start: 0, end: 1, text: "Parole pronunciate")]
        meeting.notes = String(repeating: "è🙂", count: 2000) + "FINE_APPUNTI"
        try meeting.addMarker(.action, at: 0)
        let batches = ReportService.inputBatches(meeting: meeting, limit: 512)
        XCTAssertTrue(batches.count > 2); XCTAssertTrue(batches.allSatisfy { $0.count <= 512 })
        let all = batches.joined()
        XCTAssertTrue(all.contains("FINE_APPUNTI")); XCTAssertTrue(all.contains("NOTE PERSONALI"))
        XCTAssertTrue(all.contains("non parole pronunciate")); XCTAssertTrue(all.contains("[[M1]]"))
        let linked = ReportService.resolveReferences("🙂 [[S1]] e [[N]] e [[M1]]", meeting: meeting)
        XCTAssertTrue(linked.contains("🙂")); XCTAssertFalse(linked.contains("[["))
    }
    func testReportRequestIncludesNotesAndResolvesSources() async throws {
        var meeting = Meeting(title: "Report integrato", sources: [.system], destination: temporary, keepAudio: false)
        meeting.segments = [Segment(source: .system, start: 1, end: 2, text: "Proposta da valutare")]
        meeting.notes = "APPUNTO_PERSONALE_DI_PROVA"
        try meeting.addMarker(.action, at: 1)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReportProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let report = try await ReportService.generateExtended(meeting: meeting, endpoint: LocalGateway.defaultEndpoint, model: "test", key: "test-gateway-token-for-verbale", session: session)
        XCTAssertTrue(report.contains("transcript.md#\(meeting.segments[0].anchor)"))
        XCTAssertTrue(report.contains("notes.md")); XCTAssertFalse(report.contains("[["))
    }
}

/// No network is contacted. Fail unless the actual generation request carries the new source types.
private final class ReportProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/health" || request.url?.path == "/v1/models" {
            let body = request.url?.path == "/health" ? "{\"status\":\"ok\"}" : "{\"data\":[{\"id\":\"test\"}]}"
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        guard let body, let text = String(data: body, encoding: .utf8),
              text.contains("APPUNTO_PERSONALE_DI_PROVA"), text.contains("[[S1]]"), text.contains("[[M1]]"),
              request.url?.path == "/v1/chat/completions" else {
            client?.urlProtocol(self, didFailWithError: VerbaleError.message("Fonti mancanti nella richiesta report")); return
        }
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "Proposta [[S1]]. Appunto personale [[N]]. Da esaminare [[M1]]."], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum Checks {
    static func main() async {
        if CommandLine.arguments.count == 5,CommandLine.arguments[1] == "--benchmark-engine" {
            do { try await PerformanceChecks.benchmarkEngine(asr:URL(fileURLWithPath:CommandLine.arguments[2]),vad:URL(fileURLWithPath:CommandLine.arguments[3]),audio:URL(fileURLWithPath:CommandLine.arguments[4])) }
            catch { print("FAIL engine benchmark: \(error)"); exit(1) }; return
        }
        if CommandLine.arguments.contains("--benchmark-exports") {
            do { try PerformanceChecks.benchmarkExports() } catch { print("FAIL benchmark: \(error)"); exit(1) }; return
        }
        failures += ReviewExportChecks.run()
        failures += RecordingPolicyChecks.run()
        failures += await MeetingWorkChecks.run()
        let tests = SessionStoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("recovery and torn journal", tests.testRecoveryReplaysOnlyDurableChunksAndIsIdempotent),
            ("export commit and notes", tests.testExportCommitsReadableFilesAndPreservesNotes),
            ("unavailable destination", tests.testMissingVolumeDoesNotDeleteRecoveryCopy),
            ("failed artifact export", tests.testMissingAudioCannotCommitExportWhenAudioRequested),
            ("audio verification cache detects external edits", tests.testVerifiedAudioIsRecheckedAfterExternalChanges),
            ("audio round trip", tests.testAudioRoundTripMaintainsDurationAndSamples),
            ("existing folder collision", tests.testExistingUnownedFolderIsNeverOverwritten),
            ("48k stereo resampling", tests.testResampling48kStereoHasExpectedDuration),
            ("saved audio survives cleanup", tests.testSavedAudioSurvivesTemporaryCleanup),
            ("explicit audio opt-out", tests.testAudioCanBeExplicitlyExcluded),
            ("Teams start debounce", tests.testTeamsRequiresConfirmedCallAndRejectsTransientSignals),
            ("Teams reconnect and next call", tests.testTeamsReconnectionCancelsStopAndAllowsNextCall),
            ("Teams unavailable signal", tests.testTeamsUnknownStateCannotEndCall),
            ("Teams no duplicate starts", tests.testTeamsDoesNotEmitRepeatedStartsDuringSameCall),
            ("Teams assertion identity", tests.testTeamsAssertionBelongsToTeamsAndMustBeEnabled),
            ("legacy session migration", tests.testLegacySessionWithoutReviewStillOpens),
            ("correction audit and stale report", tests.testCorrectionsPreserveOriginalAndInvalidateReport),
            ("exported markers and source links", tests.testMarkerAndReportLinksSurviveExport),
            ("long personal notes and Unicode links", tests.testLongPersonalNotesRemainBoundedAndDistinct)
        ]
        for (name, body) in cases {
            let before = failures
            do { try tests.setUpWithError(); defer { try? tests.tearDownWithError() }; try body() }
            catch { failures += 1; print("FAIL \(name): \(error)") }
            if before == failures { print("PASS \(name)") }
        }
        do {
            try tests.setUpWithError(); defer { try? tests.tearDownWithError() }
            try await tests.testReportRequestIncludesNotesAndResolvesSources(); print("PASS report generation with notes and source links (mock transport)")
        } catch { failures += 1; print("FAIL report generation: \(error)") }
        print("\(cases.count + 1) checks, \(failures) failures")
        failures += await ReportChecks.run()
        failures += await OperationalReportChecks.run()
        failures += await GatewayChecks.run()
        failures += await EchoChecks.run()
        failures += await CaptureRegressionChecks.run()
        failures += await VoiceChecks.run()
        failures += await SpeakerAuditChecks.run()
        failures += await SpeakerLearningChecks.run()
        failures += await CaptureLifecycleChecks.run()
        failures += await MeetingManagementChecks.run()
        failures += SpeakerIdentityChecks.run()
        failures += SpeakerGroupChecks.run()
        failures += TranscriptBoundaryChecks.run()
        failures += TranscriptRefinementChecks.run()
        failures += await TranscriptRefinementChecks.lifecycle()
        failures += AudioRoutingChecks.run()
        if failures > 0 { exit(1) }
    }
}
