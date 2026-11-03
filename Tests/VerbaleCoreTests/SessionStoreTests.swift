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
}

@main enum Checks {
    static func main() {
        let tests = SessionStoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("recovery and torn journal", tests.testRecoveryReplaysOnlyDurableChunksAndIsIdempotent),
            ("export commit and notes", tests.testExportCommitsReadableFilesAndPreservesNotes),
            ("unavailable destination", tests.testMissingVolumeDoesNotDeleteRecoveryCopy),
            ("failed artifact export", tests.testMissingAudioCannotCommitExportWhenAudioRequested),
            ("audio round trip", tests.testAudioRoundTripMaintainsDurationAndSamples),
            ("existing folder collision", tests.testExistingUnownedFolderIsNeverOverwritten),
            ("48k stereo resampling", tests.testResampling48kStereoHasExpectedDuration),
            ("saved audio survives cleanup", tests.testSavedAudioSurvivesTemporaryCleanup),
            ("explicit audio opt-out", tests.testAudioCanBeExplicitlyExcluded),
            ("Teams start debounce", tests.testTeamsRequiresConfirmedCallAndRejectsTransientSignals),
            ("Teams reconnect and next call", tests.testTeamsReconnectionCancelsStopAndAllowsNextCall),
            ("Teams unavailable signal", tests.testTeamsUnknownStateCannotEndCall),
            ("Teams no duplicate starts", tests.testTeamsDoesNotEmitRepeatedStartsDuringSameCall),
            ("Teams assertion identity", tests.testTeamsAssertionBelongsToTeamsAndMustBeEnabled)
        ]
        for (name, body) in cases {
            let before = failures
            do { try tests.setUpWithError(); defer { try? tests.tearDownWithError() }; try body() }
            catch { failures += 1; print("FAIL \(name): \(error)") }
            if before == failures { print("PASS \(name)") }
        }
        print("\(cases.count) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
