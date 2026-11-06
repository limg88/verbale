import Foundation
import VerbaleCore

enum EchoChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerbaleError.message(message) }
    }
    static func signal(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed, filtered: Float = 0
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Double(state >> 32) / Double(UInt32.max) * 2 - 1)
            filtered = 0.65 * filtered + 0.35 * noise
            return filtered * 0.6 * Float(0.65 + 0.35 * sin(Double(i) / 16000 * 12))
        }
    }
    static func power(_ samples: ArraySlice<Float>) -> Double {
        samples.reduce(0) { $0 + Double($1) * Double($1) }
    }
    static func cancellationAndDoubleTalk(localGain: Float = 1) async throws {
        let n = 15 * 16000, far = signal(n, seed: 47), near = signal(n, seed: 149).map { $0 * localGain }
        var microphone = [Float](repeating: 0, count: n)
        for i in 0..<n {
            microphone[i] = (i >= 1280 ? 0.55 * far[i - 1280] : 0) + (i >= 2000 ? 0.15 * far[i - 2000] : 0)
            if i > 7 * 16000 { microphone[i] += near[i] }
        }
        var reference = AudioReference(count: n); reference.place(far, start: 0, windowStart: 0)
        let started = Date(), cleaned = try await EchoCancellation().clean(microphone: microphone, reference: reference)
        try require(cleaned.count == n && cleaned.allSatisfy { $0.isFinite }, "AEC changed duration or produced nonfinite samples")
        let echoRange = 4 * 16000..<7 * 16000, range = 10 * 16000..<n
        let attenuation = 10 * log10(power(microphone[echoRange]) / max(1e-12, power(cleaned[echoRange])))
        let inputError = range.reduce(0.0) { $0 + pow(Double(microphone[$1] - near[$1]), 2) }
        let outputError = range.reduce(0.0) { $0 + pow(Double(cleaned[$1] - near[$1]), 2) }
        let improvement = 10 * log10(inputError / max(1e-12, outputError))
        let gain = range.reduce(0.0) { $0 + Double(cleaned[$1]) * Double(near[$1]) } / power(near[range])
        print(String(format: "AEC synthetic: echo %.1f dB; double-talk improvement %.1f dB; local gain %.3f; 15s in %.3fs", attenuation, improvement, gain, Date().timeIntervalSince(started)))
        try require(attenuation > 12, "Insufficient echo reduction")
        try require(improvement > 6 && gain > 0.85 && gain < 1.15, "Local voice damaged during double talk")
    }
    static func silentAndMissingReference() async throws {
        let microphone = signal(16037, seed: 8), engine = EchoCancellation()
        var reference = AudioReference(count: microphone.count)
        reference.place([Float](repeating: 0, count: microphone.count), start: 0, windowStart: 0)
        let output = try await engine.clean(microphone: microphone, reference: reference)
        try require(output.count == microphone.count, "Partial final frame changed duration")
        try require((zip(output, microphone).map { abs($0 - $1) }.max() ?? 1) < 0.0001, "Silent reference altered local speech or timing")
        reference.covered = [UInt8](repeating: 0, count: microphone.count)
        let passthrough = try await engine.clean(microphone: microphone, reference: reference)
        try require(passthrough == microphone, "Missing reference must preserve microphone exactly")
    }
    static func timestampAlignment() throws {
        var reference = AudioReference(count: 10)
        reference.place([1, 2, 3, 4], start: 1 - 2.0 / 16000, windowStart: 1)
        reference.place([5, 6, 7], start: 1 + 7.0 / 16000, windowStart: 1)
        try require(reference.samples == [3, 4, 0, 0, 0, 0, 0, 5, 6, 7], "Timestamp placement is wrong")
        try require(reference.covered == [1, 1, 0, 0, 0, 0, 0, 1, 1, 1], "Missing intervals were mistaken for silence")
    }
    static func invalidInput() async throws {
        let engine = EchoCancellation()
        do { _ = try await engine.clean(microphone: [0], reference: AudioReference(count: 2)); throw VerbaleError.message("accepted mismatched frames") }
        catch { try require(!error.localizedDescription.contains("accepted"), error.localizedDescription) }
        var reference = AudioReference(count: 160); reference.covered = [UInt8](repeating: 1, count: 160)
        var microphone = [Float](repeating: 0, count: 160); microphone[50] = .nan
        do { _ = try await engine.clean(microphone: microphone, reference: reference); throw VerbaleError.message("accepted NaN") }
        catch { try require(!error.localizedDescription.contains("accepted"), error.localizedDescription) }
        do { try await EchoCancellation(library: URL(fileURLWithPath: "/nonexistent/verbale-aec.dylib")).prepare(); throw VerbaleError.message("accepted missing runtime") }
        catch { try require(!error.localizedDescription.contains("accepted"), error.localizedDescription) }
    }
    static func originalsAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root.appendingPathComponent("store"))
        var meeting = Meeting(title: "AEC", sources: [.microphone, .system], destination: root, keepAudio: true)
        meeting.listeningMode = .speakers; meeting.state = .complete
        var chunk = AudioChunk(source: .microphone, start: 0, sampleCount: 160, filename: "audio/raw.caf")
        chunk.cleanedFilename = "audio/cleaned.caf"; chunk.processed = true
        meeting.chunks = [chunk]; try store.save(meeting)
        try AudioFiles.write([Float](repeating: 0.25, count: 160), to: store.workspace(meeting.id).appendingPathComponent(chunk.filename))
        try AudioFiles.write([Float](repeating: 0.125, count: 160), to: store.workspace(meeting.id).appendingPathComponent(chunk.cleanedFilename!))
        let saved = try store.export(meeting); try store.cleanupAudio(saved)
        let exported = root.appendingPathComponent(saved.folderName)
        let raw = try AudioFiles.samples(exported.appendingPathComponent(chunk.filename))
        let cleaned = try AudioFiles.samples(exported.appendingPathComponent(chunk.cleanedFilename!))
        try require(raw.first == 0.25 && cleaned.first == 0.125, "Original or cleaned track lost during export/cleanup")
        let decoded = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: exported.appendingPathComponent("meeting.json")))
        try require(decoded.usesEchoCancellation && decoded.chunks.first?.cleanedFilename != nil, "AEC provenance not saved")
        var old = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(meeting)) as! [String: Any]
        old.removeValue(forKey: "listeningMode")
        var chunks = old["chunks"] as! [[String: Any]]; chunks[0].removeValue(forKey: "cleanedFilename"); old["chunks"] = chunks
        let legacy = try JSONCoding.decoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: old))
        try require(!legacy.usesEchoCancellation && legacy.chunks[0].cleanedFilename == nil, "Legacy recordings no longer decode")
    }
    static func referenceFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = signal(16037, seed: 71), engine = EchoCancellation()
        let missing = try await engine.cleanWindow(microphone: microphone, start: 3, chunks: [], workspace: folder, exported: folder)
        try require(missing.samples == microphone && missing.covered.allSatisfy { $0 == 0 }, "Unknown reference was silently processed")
        var chunk = AudioChunk(source: .system, start: 3, sampleCount: microphone.count, filename: "reference.caf")
        do {
            _ = try await engine.cleanWindow(microphone: microphone, start: 3, chunks: [chunk], workspace: folder, exported: folder)
            throw VerbaleError.message("accepted missing reference file")
        } catch { try require(!error.localizedDescription.contains("accepted"), error.localizedDescription) }
        try AudioFiles.write([Float](repeating: 0, count: microphone.count), to: folder.appendingPathComponent(chunk.filename))
        let complete = try await engine.cleanWindow(microphone: microphone, start: 3, chunks: [chunk], workspace: folder, exported: folder)
        try require(complete.covered.allSatisfy { $0 == 1 }, "File timestamp/length did not cover microphone")
        try require((zip(complete.samples, microphone).map { abs($0 - $1) }.max() ?? 1) < 0.0001, "Aligned silent file changed local voice")
        chunk.sampleCount += 1
        do {
            _ = try await engine.cleanWindow(microphone: microphone, start: 3, chunks: [chunk], workspace: folder, exported: folder)
            throw VerbaleError.message("accepted truncated reference")
        } catch { try require(!error.localizedDescription.contains("accepted"), error.localizedDescription) }
    }
    static func phrase(_ text: String, start: Double, source: AudioSource) -> Segment {
        let words = text.split(separator: " ").enumerated().map { index, word in
            Word(w: String(word), start: start + Double(index) * 0.4, end: start + Double(index + 1) * 0.4)
        }
        return Segment(source: source, start: start, end: words.last!.end, text: text, words: words)
    }
    static func transcriptDuplicates() throws {
        let remote = phrase("Today we are reviewing the project schedule", start: 0, source: .system)
        var microphone = phrase("Today we are reviewing the project schedule", start: 0.1, source: .microphone)
        let local = phrase("Vorrei aggiungere una cosa importante", start: 2.5, source: .microphone)
        microphone.words += local.words; microphone.text += " " + local.text; microphone.end = local.end
        var meeting = Meeting(title: "Echo", sources: [.microphone, .system], destination: FileManager.default.temporaryDirectory, keepAudio: true)
        meeting.listeningMode = .speakers; meeting.segments = [microphone]
        meeting.reconcileEchoTranscript(near: 0, end: 5)
        try require(meeting.segments.count == 1 && meeting.echoDuplicates == nil, "Mic removed before system transcript arrived")
        meeting.segments.append(remote); meeting.reconcileEchoTranscript(near: 0, end: 5)
        try require(meeting.segments.contains(where: { $0.id == remote.id && $0.text == remote.text }), "System transcript changed")
        let retained = meeting.segments.first { $0.source == .microphone }
        try require(retained?.text == local.text && retained?.words.count == local.words.count, "Local overlapping voice removed")
        try require(meeting.echoDuplicates?.first?.original.text == microphone.text, "Original microphone text not audited")
        try require(meeting.echoDuplicates?.first?.systemSegments == [remote.id], "Duplicate lost system provenance")
        meeting.reconcileEchoTranscript(near: 0, end: 5)
        try require(meeting.echoDuplicates?.count == 1, "Reconciliation is not idempotent")
    }
    static func distinctSpeechIsKept() throws {
        var meeting = Meeting(title: "Distinct speech", sources: [.microphone, .system], destination: FileManager.default.temporaryDirectory, keepAudio: true)
        meeting.listeningMode = .speakers
        meeting.segments = [phrase("Sì sono d'accordo", start: 0, source: .system), phrase("Sì sono d'accordo", start: 0.1, source: .microphone)]
        meeting.reconcileEchoTranscript(near: 0, end: 5)
        try require(meeting.segments.count == 2 && meeting.echoDuplicates == nil, "Short agreement removed")
        let text = "Oggi esaminiamo insieme la proposta del progetto"
        meeting.segments = [phrase(text, start: 0, source: .system), phrase(text, start: 8, source: .microphone)]
        meeting.reconcileEchoTranscript(near: 0, end: 15)
        try require(meeting.segments.count == 2, "Later repetition removed")
        meeting.listeningMode = .headphones
        meeting.segments = [phrase(text, start: 0, source: .system), phrase(text, start: 0.1, source: .microphone)]
        meeting.reconcileEchoTranscript(near: 0, end: 5)
        try require(meeting.segments.count == 2, "Direct/headphone mode changed")
    }
    static func duplicateExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root.appendingPathComponent("store"))
        var meeting = Meeting(title: "Echo audit", sources: [.microphone, .system], destination: root, keepAudio: false)
        meeting.listeningMode = .speakers; meeting.state = .complete
        let text = "Today we are reviewing the project schedule"
        meeting.segments = [phrase(text, start: 0, source: .system), phrase(text, start: 0.1, source: .microphone)]
        meeting.reconcileEchoTranscript(near: 0, end: 5)
        try require(meeting.segments.count == 1, "Complete duplicate still present")
        try store.save(meeting); let saved = try store.export(meeting)
        let file = root.appendingPathComponent(saved.folderName).appendingPathComponent("echo-duplicates.json")
        let audit = try JSONCoding.decoder().decode([EchoDuplicate].self, from: Data(contentsOf: file))
        try require(audit.count == 1 && audit[0].original.text == text, "Echo audit not exported")
    }
    static func speechFixture(systemPath: String, microphonePath: String) throws {
        let system = try JSONCoding.decoder().decode([Segment].self, from: Data(contentsOf: URL(fileURLWithPath: systemPath)))
        var microphone = try JSONCoding.decoder().decode([Segment].self, from: Data(contentsOf: URL(fileURLWithPath: microphonePath)))
        for i in microphone.indices { microphone[i].source = .microphone }
        let originalWords = microphone.flatMap(\.words)
        guard let localStart = originalWords.firstIndex(where: { $0.w.lowercased() == "vorrei" }) else { throw VerbaleError.message("Local synthetic speech not recognized") }
        let localText = originalWords[localStart...].map(\.w)
        var meeting = Meeting(title: "Speech fixture", sources: [.microphone, .system], destination: FileManager.default.temporaryDirectory, keepAudio: true)
        meeting.listeningMode = .speakers; meeting.segments = system + microphone
        meeting.reconcileEchoTranscript(near: 0, end: 60)
        let retained = meeting.segments.filter { $0.source == .microphone }.flatMap(\.words).map(\.w)
        try require(!(meeting.echoDuplicates ?? []).isEmpty, "Real ASR echo not reconciled")
        try require(Array(retained.suffix(localText.count)) == localText, "Reconciliation changed the recognized local speech")
        try require(retained.count <= originalWords.count - 5, "No sufficiently long echo sequence removed")
        print("Speech fixture: microphone words \(originalWords.count) → \(retained.count); all \(localText.count) local words preserved; \(retained.count - localText.count) short residual words conservatively retained")
    }
    static func run() async -> Int {
        var cases: [(String, () async throws -> Void)] = [
            ("AEC echo reduction and double talk", { try await cancellationAndDoubleTalk() }),
            ("AEC quiet local voice during double talk", { try await cancellationAndDoubleTalk(localGain: 0.1) }),
            ("AEC silent/missing reference and exact timing", { try await silentAndMissingReference() }),
            ("AEC timestamp placement and gaps", { try timestampAlignment() }),
            ("AEC invalid input and missing runtime", { try await invalidInput() }),
            ("AEC reference file integrity and aligned window", { try await referenceFiles() }),
            ("AEC original/cleaned export and legacy migration", { try originalsAndExport() }),
            ("AEC transcript duplicates and overlapping voice", { try transcriptDuplicates() }),
            ("AEC short agreements and later repetitions", { try distinctSpeechIsKept() }),
            ("AEC duplicate audit export", { try duplicateExport() })
        ]
        if let index = CommandLine.arguments.firstIndex(of: "--echo-speech-json"), CommandLine.arguments.count > index + 2 {
            let system = CommandLine.arguments[index + 1], microphone = CommandLine.arguments[index + 2]
            cases.append(("AEC generated speech + actual ASR", { try speechFixture(systemPath: system, microphonePath: microphone) }))
        }
        var failures = 0
        for (name, body) in cases {
            do { try await body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(cases.count) AEC checks, \(failures) failures")
        return failures
    }
}
