import Foundation
import VerbaleCore

private actor BlockedAudioFixture {
    var cleaned = 0
    func start() -> Date { Thread.sleep(forTimeInterval:0.22); return Date() }
    func cleanup() { cleaned += 1 }
    func blockedStop() { Thread.sleep(forTimeInterval:0.22); cleaned += 1 }
}
enum CaptureLifecycleChecks {
    static func require(_ value: Bool,_ message:String) throws { if !value { throw VerbaleError.message(message) } }
    static func startDeadline() async throws {
        let fixture = BlockedAudioFixture(), gate = CaptureOperationGuard(startTimeout:0.025,stopTimeout:0.025)
        let started = Date()
        do { _ = try await gate.start(operation:{ await fixture.start() },cleanup:{ await fixture.cleanup() }); throw VerbaleError.message("blocked start did not time out") }
        catch CaptureOperationError.timeout {} catch { throw error }
        try require(Date().timeIntervalSince(started) < 0.18,"deadline waited for blocked hardware")
        let available = await gate.available; try require(!available,"hardware can start twice before cleanup")
        // The caller/main actor remains responsive even while the hardware actor is still blocked.
        let pulse = await MainActor.run { true };try require(pulse,"main actor was blocked")
        await gate.stop { await fixture.cleanup() }
        try await Task.sleep(for:.milliseconds(280))
        let ready = await gate.available, cleaned = await fixture.cleaned
        try require(ready && cleaned == 1,"late start was not cleaned exactly once")
    }
    static func stopDeadline() async throws {
        let fixture = BlockedAudioFixture(), gate = CaptureOperationGuard(startTimeout:0.03,stopTimeout:0.025)
        _ = try await gate.start(operation:{ Date() },cleanup:{ await fixture.cleanup() })
        let started = Date(); await gate.stop { await fixture.blockedStop() }
        try require(Date().timeIntervalSince(started) < 0.18,"stop blocks the caller indefinitely")
        let available = await gate.available;try require(!available,"new start races blocked teardown")
        try await Task.sleep(for:.milliseconds(280))
        let ready = await gate.available;try require(ready,"late teardown does not release capture")
    }
    static func idlePolicy() throws {
        try require(RecordingReadiness.waitingForSystem([.system],chunks:[]),"quiet system audio is not treated as waiting")
        try require(!RecordingReadiness.missingMicrophone([.system],chunks:[],elapsed:300),"system silence incorrectly aborts recording")
        let mic = AudioChunk(source:.microphone,start:0,sampleCount:80000,filename:"mic.caf")
        try require(!RecordingReadiness.missingMicrophone([.microphone,.system],chunks:[mic],elapsed:300),"silent meeting stops valid microphone capture")
        try require(RecordingReadiness.missingMicrophone([.microphone],chunks:[],elapsed:15),"genuine microphone failure not detected")
        try require(RecordingReadiness.systemWarning([.microphone,.system],chunks:[mic],elapsed:29) == nil,"system warning shown before grace period")
        try require(RecordingReadiness.systemWarning([.microphone,.system],chunks:[mic],elapsed:30) != nil,"missing system source not surfaced")
        let system = AudioChunk(source:.system,start:0,sampleCount:80000,filename:"system.caf")
        try require(RecordingReadiness.systemWarning([.microphone,.system],chunks:[mic,system],elapsed:300) == nil,"received source reported missing")
        try require(RecordingReadiness.missingSourceWarnings([.microphone,.system],chunks:[mic]).count == 1,"incomplete recording has no durable warning")
        try require(RecordingReadiness.missingSourceWarnings([.microphone],chunks:[mic]).isEmpty,"disabled system source reported missing")
        try require(RecordingReadiness.missingSourceWarnings([.system],chunks:[],segments:[Segment(source:.system,start:0,end:1,text:"Importato")]).isEmpty,"legacy transcript without chunks reported as capture failure")
    }
    static func trackHealth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root.appendingPathComponent("sessions"))
        var meeting = Meeting(title: "Track health", sources: [.microphone, .system], destination: root, keepAudio: true)
        meeting.captureTimelineVersion = 2
        meeting.duration = 45
        meeting.chunks = (0..<9).map {
            AudioChunk(source: .microphone, start: Double($0 * 5), sampleCount: 80000, filename: "mic-\($0).caf")
        }
        let system = (0..<7).map {
            AudioChunk(source: .system, start: Double($0 * 5), sampleCount: 80000, filename: "system-\($0).caf", audibleSampleCount: $0 == 1 ? 16000 : 0)
        }
        meeting.chunks += system
        try require(RecordingReadiness.liveWarning(meeting.sources, chunks: meeting.chunks, elapsed: 36)?.contains("molto debole") == true,
                    "received quiet buffers looked like healthy system audio")
        try require(RecordingReadiness.liveWarning(meeting.sources, chunks: meeting.chunks, elapsed: 47)?.contains("nessun nuovo blocco") == true,
                    "missing subsequent buffers did not take priority over weak audio")
        let warnings = RecordingReadiness.archiveWarnings(meeting)
        try require(warnings.count == 2 && warnings.contains { $0.contains("interruzione") },
                    "final warning failed to report the missing tail and the weak trace")
        meeting.warnings = warnings
        try store.save(meeting)
        let restored = try store.read(meeting.id)
        try require(RecordingReadiness.archiveWarnings(restored) == warnings && restored.chunks.last?.audibleSampleCount == 0,
                    "diagnostics duplicated or disappeared on reopening")
        meeting.warnings = []
        for index in meeting.chunks.indices { meeting.chunks[index].audibleSampleCount = nil }
        try require(RecordingReadiness.archiveWarnings(meeting).count == 1,
                    "legacy capture levels were treated as silence or its timeline gap was missed")
        var recovered = system.last!
        recovered.start = 200
        let spans = system + [recovered]
        try require(TranscriptBoundaries.audioContext(spans, at: 6, warmupBlocks: 1) == 5...6 &&
                    TranscriptBoundaries.audioContext(spans, at: 7, warmupBlocks: 2) == 7...7,
                    "ASR context carried the capture outage into the recovered audio")
    }

    /// Opt-in on a Mac with system-audio recording permission and an audible output.
    static func systemCaptureHardware() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbale-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root.appendingPathComponent("sessions"))
        let meeting = Meeting(title: "Synthetic capture", sources: [.system], destination: root, keepAudio: true)
        try store.save(meeting)
        let folder = store.workspace(meeting.id)
        let tone = root.appendingPathComponent("tone.caf")
        try AudioFiles.write((0..<20000).map { Float(0.18 * sin(2 * .pi * 440 * Double($0) / 16000)) }, to: tone)
        let output = try AudioRouteSelection.resolve(AudioRouteSelection.macDefault, input: false,
                                                     snapshot: AudioRouteProbe.snapshot(includeTeams: false))
        let capture = CaptureService()
        func playTone() async throws {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.15", tone.path]
            try player.run()
            for _ in 0..<40 where player.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            if player.isRunning {
                player.terminate()
                throw VerbaleError.message("Synthetic playback timed out")
            }
            try require(player.terminationStatus == 0, "synthetic playback failed")
            try await Task.sleep(for: .milliseconds(300))
        }
        _ = try await capture.start(sources: [.system], input: 0, output: output.device.runtimeID, folder: folder,
                                    onChunk: { _ in }, onLevel: { _, _ in }, onError: { print("Capture: \($0)") })
        do {
            try await playTone()
            let failures = try await capture.changeDevices(input: nil, output: output.device.runtimeID)
            try require(failures.isEmpty, "system tap failed to reopen")
            try await playTone()
            let stopped = await capture.stop()
            try require(stopped, "system tap did not stop")
            let captured = try store.recover(meeting).chunks.sorted { $0.start < $1.start }
            let audible = captured.filter { ($0.audibleSampleCount ?? 0) > 0 }
            try require(audible.count >= 2 && audible[1].start >= audible[0].start + audible[0].duration - 0.02,
                        "system audio was quiet or rebind reset the recording clock")
        } catch {
            await capture.stop()
            throw error
        }
    }
    static func run() async -> Int {
        var failed = 0
        do { try await startDeadline();print("PASS capture start deadline, responsiveness and late cleanup") } catch { failed += 1;print("FAIL capture start deadline: \(error)") }
        do { try await stopDeadline();print("PASS capture stop deadline and serialized recovery") } catch { failed += 1;print("FAIL capture stop deadline: \(error)") }
        do { try idlePolicy();print("PASS capture waiting before meeting and missing microphone") } catch { failed += 1;print("FAIL capture idle policy: \(error)") }
        do { try trackHealth();print("PASS capture weak signal, missing tail, durable warnings and post-gap ASR context") } catch { failed += 1;print("FAIL capture track health: \(error)") }
        return failed
    }
}
