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
    static func run() async -> Int {
        var failed = 0
        do { try await startDeadline();print("PASS capture start deadline, responsiveness and late cleanup") } catch { failed += 1;print("FAIL capture start deadline: \(error)") }
        do { try await stopDeadline();print("PASS capture stop deadline and serialized recovery") } catch { failed += 1;print("FAIL capture stop deadline: \(error)") }
        do { try idlePolicy();print("PASS capture waiting before meeting and missing microphone") } catch { failed += 1;print("FAIL capture idle policy: \(error)") }
        return failed
    }
}
