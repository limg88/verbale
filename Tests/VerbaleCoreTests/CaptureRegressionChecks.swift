import Foundation
import AVFoundation
import VerbaleCore

enum CaptureRegressionChecks {
    static func streaming(_ rate: Double, channels: AVAudioChannelCount, sizes: [Int], interleaved: Bool = false) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
        let converter = try StreamingAudioConverter(format: format)
        var inputPosition = 0, result: [Float] = []
        for size in sizes {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(size))!
            input.frameLength = UInt32(size)
            for i in 0..<size {
                let t = Double(inputPosition + i) / rate
                let value = Float(0.3 * sin(2 * .pi * 437 * t) + 0.2 * sin(2 * .pi * 993 * t))
                if interleaved {
                    for c in 0..<Int(channels) { input.floatChannelData![0][i * Int(channels) + c] = value }
                } else {
                    for c in 0..<Int(channels) { input.floatChannelData![c][i] = value }
                }
            }
            result += try converter.convert(input); inputPosition += size
        }
        result += try converter.finish()
        let expectedCount = Int((Double(inputPosition) * 16000 / rate).rounded())
        try EchoChecks.require(abs(result.count - expectedCount) <= 1, "Streaming converter lost samples: \(result.count) vs \(expectedCount)")
        try EchoChecks.require(try converter.finish().isEmpty, "Converter tail flushed twice")
        var dot = 0.0, x2 = 0.0, y2 = 0.0
        for i in 1000..<(result.count - 1000) {
            let t = Double(i) / 16000
            let expected = 0.3 * sin(2 * .pi * 437 * t) + 0.2 * sin(2 * .pi * 993 * t)
            let value = Double(result[i]); dot += value * expected; x2 += value * value; y2 += expected * expected
        }
        let correlation = dot / sqrt(x2 * y2)
        try EchoChecks.require(correlation > 0.999, "Stream waveform discontinuity: \(correlation)")
        // Chunk timestamps derive from saved samples, independent of converter buffering.
        var position = 0, previousEnd = 0.0, timeline = AudioSampleClock(start: 0)
        while position < result.count {
            let count = min(80000, result.count - position), start = timeline.nextStart
            try EchoChecks.require(abs(start - previousEnd) < 0.000001, "Artificial gap between saved chunks")
            previousEnd = start + Double(count) / 16000; position += count; timeline.advance(samples: count)
        }
        print("stream \(Int(rate))Hz \(channels)ch → \(result.count) samples; waveform correlation \(correlation)")
    }
    static func formatChange() throws {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let converter = try StreamingAudioConverter(format: mono)
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 100)!
        buffer.frameLength = 100
        do { _ = try converter.convert(buffer); throw VerbaleError.message("accepted changed device format") }
        catch { try EchoChecks.require(!error.localizedDescription.contains("accepted"), error.localizedDescription) }
    }
    static func diarizationReferences() throws {
        let system = EchoChecks.phrase("One two three four five six seven eight", start: 0, source: .system)
        let microphone = EchoChecks.phrase("Parlo anch’io", start: 1, source: .microphone)
        var meeting = Meeting(title: "Diarization references", sources: [.system, .microphone], destination: FileManager.default.temporaryDirectory, keepAudio: false)
        meeting.segments = [system, microphone]
        meeting.echoDuplicates = [EchoDuplicate(original: microphone, systemSegments: [system.id])]
        meeting.report = "Source [one](transcript.md#\(system.anchor))"; meeting.reportStatus = "Completato"
        let result = SpeakerDiarization.split(meeting.segments, regions: [SpeakerRegion(start: 0, end: 1.6, speaker: 0), SpeakerRegion(start: 1.6, end: 3.2, speaker: 1)])
        meeting.applyDiarization(result)
        let systems = meeting.segments.filter { $0.source == .system }
        try EchoChecks.require(systems.count == 2 && systems[0].id == system.id, "Diarization lost original anchor")
        let references = meeting.echoDuplicates![0].systemSegments
        try EchoChecks.require(Set(references) == Set(systems.map(\.id)), "Audit not remapped to split speakers")
        try EchoChecks.require(meeting.segments.last?.id == microphone.id, "Diarization changed local voice")
        try EchoChecks.require(meeting.reportNeedsUpdate, "Diarization left old report marked current")
        let repeated = SpeakerDiarization.split(meeting.segments, regions: [SpeakerRegion(start: 0, end: 3.2, speaker: 0)])
        meeting.applyDiarization(repeated)
        try EchoChecks.require(meeting.echoDuplicates![0].systemSegments.allSatisfy { ref in meeting.segments.contains { $0.id == ref } }, "Repeated diarization broke audit")
    }
    static func legacyReferences() throws {
        let remote = EchoChecks.phrase("Today we are reviewing the project schedule", start: 0, source: .system)
        let microphone = EchoChecks.phrase("Today we are reviewing the project schedule", start: 0.1, source: .microphone)
        let stale = UUID()
        var meeting = Meeting(title: "Legacy audit", sources: [.system, .microphone], destination: FileManager.default.temporaryDirectory, keepAudio: true)
        meeting.listeningMode = .speakers; meeting.segments = [remote]
        meeting.echoDuplicates = [EchoDuplicate(original: microphone, systemSegments: [stale])]
        meeting.repairEchoAuditReferences()
        try EchoChecks.require(meeting.echoDuplicates![0].systemSegments == [remote.id], "Legacy references not recovered from matching words")
        try EchoChecks.require(meeting.echoDuplicates![0].previousSystemSegments == [stale], "Legacy evidence was overwritten")
        try EchoChecks.require(meeting.echoDuplicates![0].referenceStatus == "reconstructed-from-words-and-timestamps", "Inferred links were not marked")
        meeting.repairEchoAuditReferences()
        try EchoChecks.require(meeting.echoDuplicates![0].previousSystemSegments == [stale], "Legacy repair not idempotent")
        meeting.segments = []
        meeting.repairEchoAuditReferences()
        try EchoChecks.require(meeting.echoDuplicates![0].referenceStatus == "unresolved", "Missing source guessed instead of reported")
    }
    static func realLegacyCopy(input: String, output: String) throws {
        var meeting = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        let valid = Set(meeting.segments.map(\.id))
        let before = (meeting.echoDuplicates ?? []).flatMap(\.systemSegments).filter { !valid.contains($0) }.count
        meeting.repairEchoAuditReferences()
        let after = (meeting.echoDuplicates ?? []).flatMap(\.systemSegments).filter { !valid.contains($0) }.count
        try EchoChecks.require(before > 0 && after == 0, "Real legacy references remain unresolved")
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        try JSONCoding.encoder().encode(meeting.echoDuplicates ?? []).write(to: folder.appendingPathComponent("echo-duplicates.json"), options: .atomic)
        print("Real legacy audit: \(before) dangling references → \(after); originals retained in previousSystemSegments")
    }
    static func reprocessedCopy(input: String, microphone: String, output: String) throws {
        let source = URL(fileURLWithPath: input)
        let folder = URL(fileURLWithPath: output)
        try EchoChecks.require(source.deletingLastPathComponent().resolvingSymlinksInPath() != folder.resolvingSymlinksInPath(), "Cannot overwrite original recording")
        var meeting = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: source))
        var mic = try JSONCoding.decoder().decode([Segment].self, from: Data(contentsOf: URL(fileURLWithPath: microphone)))
        for i in mic.indices { mic[i].source = .microphone }
        let system = meeting.segments.filter { $0.source == .system }, originalSystemIDs = Set(system.map(\.id))
        meeting.segments = system + mic; meeting.echoDuplicates = nil
        meeting.reconcileEchoTranscript(near: 0, end: meeting.duration + 1)
        try EchoChecks.require(Set(meeting.segments.filter { $0.source == .system }.map(\.id)) == originalSystemIDs, "Reprocessing changed system transcript")
        try EchoChecks.require((meeting.echoDuplicates ?? []).flatMap(\.systemSegments).allSatisfy { originalSystemIDs.contains($0) }, "Reprocessed audit has missing source")
        let ordered = meeting.segments.sorted { $0.start < $1.start }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(ordered).write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        try JSONCoding.encoder().encode(meeting.echoDuplicates ?? []).write(to: folder.appendingPathComponent("echo-duplicates.json"), options: .atomic)
        let text = ordered.map { "[\(timecode($0.start))] **\(meeting.speakerName(for: $0))**: \($0.text)" }.joined(separator: "\n\n")
        try ("# Copia diagnostica rielaborata\n\nMicrofono rielaborato dalla copia con timeline continua; trascrizione sistema originale conservata. L’archivio originale non è stato modificato.\n\n" + text + "\n").write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let kept = ordered.filter { $0.source == .microphone }.flatMap(\.words).count
        print("Reprocessed real copy: microphone words \(mic.flatMap(\.words).count) → \(kept); \(meeting.echoDuplicates?.count ?? 0) audited echo passages; all system IDs preserved")
    }
    static func run() async -> Int {
        var cases: [(String, () throws -> Void)] = [
            ("continuous 48k microphone", { try streaming(48000, channels: 1, sizes: [Int](repeating: 4800, count: 120)) }),
            ("irregular 44.1k stereo packets", { try streaming(44100, channels: 2, sizes: (0..<160).map { [4096, 4410, 997, 512][$0 % 4] }) }),
            ("interleaved stereo system buffers", { try streaming(48000, channels: 2, sizes: [Int](repeating: 1024, count: 200), interleaved: true) }),
            ("device format changes rejected", formatChange),
            ("diarization preserves anchors and echo audit", diarizationReferences),
            ("legacy echo audit repair preserves evidence", legacyReferences)
        ]
        if let index = CommandLine.arguments.firstIndex(of: "--repair-legacy-copy"), CommandLine.arguments.count > index + 2 {
            let input = CommandLine.arguments[index + 1], output = CommandLine.arguments[index + 2]
            cases.append(("real legacy recording audit (copy only)", { try realLegacyCopy(input: input, output: output) }))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--reconciled-copy"), CommandLine.arguments.count > index + 3 {
            let input = CommandLine.arguments[index + 1], mic = CommandLine.arguments[index + 2], output = CommandLine.arguments[index + 3]
            cases.append(("real reprocessed transcript (copy only)", { try reprocessedCopy(input: input, microphone: mic, output: output) }))
        }
        var failures = 0
        for (name, body) in cases {
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(cases.count) capture regressions, \(failures) failures")
        return failures
    }
}
