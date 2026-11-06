import Foundation
import AVFoundation
import VerbaleCore

enum VoiceChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw VerbaleError.message(message) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        var refused = false
        do { try body() } catch { refused = true }
        try require(refused, "invalid voice input accepted")
    }
    static let encoder = VoiceEncoderID(identity: "sha256:test", family: "fixture", dimension: 3)
    static func clips(_ meeting: Meeting) -> [VoiceClip] {
        [VoiceClip(meetingID: meeting.id, source: .system, start: 0, end: 4, text: "one"), VoiceClip(meetingID: meeting.id, source: .system, start: 5, end: 9, text: "two")]
    }
    static func storeAndRanking(_ root: URL) throws {
        let store = try VoiceProfileStore(directory: root.appendingPathComponent("profiles"))
        let meeting = Meeting(title: "fixture", sources: [.system], destination: root, keepAudio: true)
        let samples = clips(meeting).map { VoiceSample(clip: $0, embedding: [1,0,0]) }
        let profile = try store.enroll(name: "Ada", samples: samples, encoder: encoder)
        try require(try VoiceProfileStore(directory: store.directory).profiles.first?.id == profile.id, "profile persistence")
        try refuses { _ = try store.enroll(name: "", samples: samples, encoder: encoder, existing: profile.id) }
        let laterMeeting = Meeting(title: "Later", sources: [.system], destination: root, keepAudio: true)
        let later = clips(laterMeeting).map { VoiceSample(clip: $0, embedding: [1,0,0]) }
        _ = try store.enroll(name: "", samples: later, encoder: encoder, existing: profile.id)
        try require(store.profiles.first?.samples.count == 4 && store.profiles.first?.name == "Ada", "explicit append with existing name")
        let mode = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("profiles.json").path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "private profile permissions")
        try refuses { _ = try store.enroll(name: "ada", samples: samples, encoder: encoder) }
        try refuses { _ = try store.enroll(name: "Bad", samples: [samples[0]], encoder: encoder) }
        var different = samples; different[1].embedding = [0,1,0]
        let variable = try store.enroll(name: "Variable verified voice", samples: different, encoder: encoder)
        try require(variable.needsMatchConfirmation, "variable samples must be saved for explicit confirmation")
        let variableMatch = try VoiceVectors.rank([1,1,0], encoder: encoder, profiles: [variable])
        try require(variableMatch != nil && variableMatch?.strong == false, "variable profile must not trigger automatic naming even at high score")
        let opposing = samples.enumerated().map { i, s in VoiceSample(clip: s.clip, embedding: i == 0 ? [1,0,0] : [-1,0,0]) }
        let unstable = try store.enroll(name: "Opposing vectors", samples: opposing, encoder: encoder)
        try require(try VoiceVectors.rank([1,0,0], encoder: encoder, profiles: [unstable]) == nil, "zero centroid must stay unknown, not break ranking")
        let reloaded = try VoiceProfileStore(directory: store.directory)
        try require(reloaded.profiles.first(where: { $0.id == variable.id })?.needsMatchConfirmation == true, "variable profile mode must survive reload")
        try store.remove(variable.id); try store.remove(unstable.id)
        let appendStore = try VoiceProfileStore(directory: root.appendingPathComponent("append-profiles"))
        let original = try appendStore.enroll(name: "Verified", samples: samples, encoder: encoder)
        let variableLater = later.map { VoiceSample(clip: $0.clip, embedding: [0,1,0]) }
        let appended = try appendStore.enroll(name: "", samples: variableLater, encoder: encoder, existing: original.id)
        try require(appended.samples.count == 4 && appended.needsMatchConfirmation, "verified variable samples cannot be appended")
        try refuses { _ = try VoiceVectors.normalized([.nan,0,1], dimension: 3) }
        try refuses { _ = try VoiceVectors.normalized([0,0,0], dimension: 3) }
        let match = try VoiceVectors.rank([1,0,0], encoder: encoder, profiles: store.profiles)
        try require(match?.profileID == profile.id && match?.strong == true, "known profile ranking")
        let other = VoiceEncoderID(identity: "sha256:other", family: "fixture", dimension: 3)
        try require(try VoiceVectors.rank([1,0,0], encoder: other, profiles: store.profiles) == nil, "different model must not match")
        try require(try VoiceVectors.rank([0,1,0], encoder: encoder, profiles: store.profiles) == nil, "unknown voice forced to known profile")
        _ = try store.enroll(name: "Very similar", samples: samples, encoder: encoder)
        try require(try VoiceVectors.rank([1,0,0], encoder: encoder, profiles: store.profiles) == nil, "ambiguous profiles must not match")
        try store.setEnabled(profile.id, false)
        try require(store.profiles.first?.enabled == false, "profile disable")
        try store.rename(profile.id, name: "New name"); try store.remove(profile.id)
        try require(!store.profiles.contains(where: { $0.id == profile.id }), "profile delete")
        try require(FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["profiles.json"], "profile store copied raw audio")
    }
    static func consensusAndReview(_ root: URL) throws {
        let p = UUID(), q = UUID()
        let rank = VoiceRanking(profileID: p, name: "Ada", score: 0.9, margin: 0.3)
        let conflict = VoiceRanking(profileID: q, name: "Ben", score: 0.92, margin: 0.3)
        try require(VoiceConsensus.decision([rank,rank])?.1 == true, "concordant strong clips")
        try require(VoiceConsensus.decision([rank])?.1 == false, "single clip must be suggestion")
        try require(VoiceConsensus.decision([rank,nil])?.1 == false, "missing evidence must prevent automatic name")
        try require(VoiceConsensus.decision([rank,conflict]) == nil, "conflicting clips must remain unknown")
        var meeting = Meeting(title: "Review", sources: [.system], destination: root, keepAudio: false)
        let segment = Segment(source: .system, start: 0, end: 10, text: "Original", speakerID: "Interlocutore 1")
        meeting.segments = [segment]; meeting.report = "Old"; meeting.reportStatus = "Completato"
        meeting.applyVoiceGroup([segment.id], ranking: rank, automatic: true)
        try require(meeting.speakerName(for: meeting.segments[0]) == "Ada" && meeting.reportNeedsUpdate, "automatic naming and report invalidation")
        meeting.rejectVoice(p)
        try require(meeting.segments[0].speakerID == "Interlocutore 1" && meeting.voiceMatches?.first?.state == .rejected, "rejection restores slot")
        meeting.applyVoiceGroup([segment.id], ranking: rank, automatic: true)
        try require(meeting.segments[0].speakerID == "Interlocutore 1", "rejection must survive rerun")
        meeting.voiceMatches = nil
        meeting.applyVoiceGroup([segment.id], ranking: rank, automatic: false)
        try require(meeting.segments[0].speakerID == "Interlocutore 1", "suggestion must not assign name")
        meeting.confirmVoice(p)
        try require(meeting.voiceMatches?.first?.state == .confirmed && meeting.voiceProtectedSegments.contains(segment.id), "confirmation protected")
        try meeting.correctSegment(segment.id, text: "Edited", speakerID: "manual-fixture")
        try require(meeting.voiceMatches?.isEmpty == true, "manual correction leaves stale voice evidence")
        meeting.applyVoiceGroup([segment.id], ranking: conflict, automatic: true)
        try require(meeting.segments[0].speakerID == "manual-fixture", "manual correction overwritten")
        let json = String(data: try JSONCoding.encoder().encode(meeting), encoding: .utf8)!
        try require(!json.contains("embedding"), "embedding leaked into meeting export")
        var legacy = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(meeting)) as! [String: Any]
        legacy.removeValue(forKey: "voiceMatches")
        _ = try JSONCoding.decoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: legacy))
    }
    static func explicitNames(_ root: URL) throws {
        var meeting = Meeting(title: "Explicit profile name", sources: [.system, .microphone], destination: root, keepAudio: false)
        let a = Segment(source: .system, start: 0, end: 5, text: "One", speakerID: "Interlocutore 1")
        let b = Segment(source: .system, start: 6, end: 11, text: "Two", speakerID: "Interlocutore 1")
        let other = Segment(source: .system, start: 12, end: 17, text: "Other", speakerID: "Interlocutore 2")
        let mic = Segment(source: .microphone, start: 0, end: 5, text: "Mic", speakerID: "Interlocutore 1")
        let unknown = Segment(source: .system, start: 18, end: 23, text: "Unknown")
        let unknown2 = Segment(source: .system, start: 24, end: 29, text: "Another unknown")
        meeting.segments = [a,b,other,mic,unknown,unknown2]
        meeting.report = "Old report"; meeting.reportStatus = "Completato"
        let rank = VoiceRanking(profileID: UUID(), name: "Suggested", score: 0.7, margin: 0.1)
        meeting.applyVoiceGroup([a.id,b.id], ranking: rank, automatic: false)
        try meeting.assignVoiceName("Verified name", to: a.id)
        try require(meeting.speakerName(for: meeting.segments[0]) == "Verified name" && meeting.speakerName(for: meeting.segments[1]) == "Verified name", "profile name not assigned to whole speaker group")
        try require(meeting.speakerName(for: meeting.segments[2]) == "Interlocutore 2" && meeting.speakerName(for: meeting.segments[3]) == "Interlocutore 1", "assignment escaped selected source or group")
        try require(meeting.voiceMatches?.isEmpty == true && meeting.voiceProtectedSegments.contains(a.id) && meeting.reportNeedsUpdate, "explicit name does not override recognition or invalidate report")
        try meeting.assignVoiceName("Single passage", to: unknown.id)
        try require(meeting.speakerName(for: meeting.segments[4]) == "Single passage" && meeting.segments[5].speakerID == nil, "unnamed passages incorrectly grouped")
        let restored = try JSONCoding.decoder().decode(Meeting.self, from: JSONCoding.encoder().encode(meeting))
        try require(restored.speakerName(for: restored.segments[0]) == "Verified name", "assigned name not persisted")
    }
    static func audioAndClips(_ root: URL) throws {
        var meeting = Meeting(title: "Audio", sources: [.system, .microphone], destination: root, keepAudio: true)
        let selected = Segment(source: .system, start: 7200, end: 7218, text: "speaker A", speakerID: "A")
        let overlap = Segment(source: .system, start: 7205, end: 7210, text: "speaker B", speakerID: "B")
        meeting.segments = [selected, overlap]
        let candidates = VoiceClips.candidates(meeting: meeting, speakerID: "A", source: .system, selected: selected.id)
        try require(!candidates.isEmpty && candidates.allSatisfy { min($0.end, overlap.end) <= max($0.start, overlap.start) }, "overlap in enrollment clips")
        let audio = VoiceAudio(workspace: root, exported: root.appendingPathComponent("export"))
        let wave = (0..<80000).map { Float(sin(Double($0) * 0.08) * 0.2) }
        try AudioFiles.write(wave, to: root.appendingPathComponent("raw.caf"))
        try AudioFiles.write(wave.map { $0 * 0.5 }, to: root.appendingPathComponent("clean.caf"))
        var chunk = AudioChunk(source: .microphone, start: 7200, sampleCount: wave.count, filename: "raw.caf")
        chunk.cleanedFilename = "clean.caf"; meeting.chunks = [chunk]; meeting.listeningMode = .speakers
        let clip = VoiceClip(meetingID: meeting.id, source: .microphone, start: 7200.5, end: 7204.5, text: "test")
        let samples = try audio.samples(clip, meeting: meeting)
        try require(samples.count == 64000 && abs(samples[0] - wave[8000] * 0.5) < 0.00001, "cleaned microphone or late timeline read")
        let player = try AVAudioPlayer(data: VoiceAudio.wave(samples))
        try require(abs(player.duration - 4) < 0.001, "in-memory audition WAV")
        meeting.chunks[0].cleanedFilename = nil
        try refuses { _ = try audio.samples(clip, meeting: meeting) }
        meeting.listeningMode = .headphones
        meeting.chunks[0].start = 7201
        try refuses { _ = try audio.samples(clip, meeting: meeting) }
        try refuses { _ = try audio.url("../escape.caf") }
        // Overlap and manual anchors cannot become voice identity evidence.
        let words = [Word(w: "one", start: 0, end: 1), Word(w: "two", start: 1, end: 2)]
        let segment = Segment(source: .system, start: 0, end: 2, text: "one two", words: words)
        let regions = [SpeakerRegion(start: 0, end: 2, speaker: 0), SpeakerRegion(start: 1, end: 2, speaker: 1)]
        let split = SpeakerDiarization.split([segment], regions: regions)
        try require(split.segments.count == 2 && split.segments.last?.speakerID == nil, "overlapping voices assigned single speaker")
        let unchanged = SpeakerDiarization.split([segment], regions: regions, protected: [segment.id])
        try require(unchanged.segments.count == 1 && unchanged.segments[0].id == segment.id, "manual segment split")
    }
    static func signalQuality(_ root: URL) throws {
        let clean = (0..<80000).map { Float(sin(Double($0) * 0.08) * 0.2) }
        try require(VoiceClipQuality.measure(clean).grade == .recommended, "regular signal should be recommended")
        try require(VoiceClipQuality.measure(clean.map { $0 * 0.02 }).grade == .review, "low but usable signal should be described, not rejected")
        try require(!VoiceClipQuality.measure([Float](repeating: 0, count: 80000)).usable, "silence must not be usable")
        try require(!VoiceClipQuality.measure([Float](repeating: 1, count: 80000)).usable, "saturated signal must not be usable")
        try require(!VoiceClipQuality.measure([Float](repeating: .nan, count: 80000)).usable, "invalid signal must not be usable")
        let paused = Array(clean.prefix(32000)) + [Float](repeating: 0, count: 48000)
        let quality = VoiceClipQuality.measure(paused)
        try require(quality.grade == .review && quality.quietFraction > 0.5, "long pauses should be exposed as signal warning")
        try require(VoiceClipQuality.measure(Array(clean.prefix(48000))).grade == .review, "short usable samples should carry an advisory")
        let engine = VoiceClipQuality.measure(clean)
        try require(engine.levelDB > -20 && engine.clippedFraction == 0, "signal statistics inconsistent")
    }
    static func native(_ root: URL, model: URL) async throws {
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("native/parakeet.cpp/tests/fixtures/two_speakers.wav")
        let pcm = try AudioFiles.samples(fixture)
        try AudioFiles.write(pcm, to: root.appendingPathComponent("fixture.caf"))
        var meeting = Meeting(title: "Public LibriSpeech fixture", sources: [.system], destination: root, keepAudio: true)
        meeting.duration = Double(pcm.count) / 16000
        meeting.chunks = [AudioChunk(source: .system, start: 0, sampleCount: pcm.count, filename: "fixture.caf")]
        let spans = [(0.6,4.6),(14.9,18.7),(6.9,10.9),(20.2,23.5)]
        let clips = spans.map { VoiceClip(meetingID: meeting.id, source: .system, start: $0.0, end: $0.1, text: "public fixture") }
        let engine = VoiceAnalysisEngine(), audio = VoiceAudio(workspace: root, exported: root)
        let hash = try ModelManager.digest(model)
        let (id, samples) = try await engine.enroll(clips: clips, meeting: meeting, audio: audio, model: model, hash: hash)
        try require(id.dimension == 256 && id.identity == "sha256:" + hash, "native fingerprint or embedding dimension")
        func cosine(_ a: [Float], _ b: [Float]) -> Double { zip(a,b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } }
        let same = cosine(samples[0].embedding, samples[1].embedding), different = cosine(samples[0].embedding, samples[2].embedding)
        print("VOICE fixture same=\(same), different=\(different), dimension=\(id.dimension)")
        try require(same > different + 0.2, "native encoder does not discriminate public fixture voices")
        let store = try VoiceProfileStore(directory: root.appendingPathComponent("native-profiles"))
        let a = try store.enroll(name: "Public A", samples: Array(samples[0...1]), encoder: id)
        let b = try store.enroll(name: "Public B", samples: Array(samples[2...3]), encoder: id)
        try require(try VoiceVectors.rank(samples[0].embedding, encoder: id, profiles: store.profiles)?.profileID == a.id, "native A profile ranking")
        try require(try VoiceVectors.rank(samples[2].embedding, encoder: id, profiles: store.profiles)?.profileID == b.id, "native B profile ranking")
        meeting.segments = spans.enumerated().map { i, span in Segment(source: .system, start: span.0, end: span.1, text: "public \(i)", speakerID: i < 2 ? "A" : "B") }
        let recognized = try await engine.recognize(meeting: meeting, audio: audio, model: model, hash: hash, profiles: store.profiles)
        try require(recognized.voiceMatches?.count == 4, "native recognition pipeline evidence")
        if let diar = ProcessInfo.processInfo.environment["VERBALE_TEST_DIAR_MODEL"] {
            var diarMeeting = meeting
            diarMeeting.segments = (0..<Int(meeting.duration * 2)).map { i in
                let t = Double(i) / 2
                return Segment(source: .system, start: t, end: t + 0.4, text: "word", words: [Word(w: "word", start: t, end: t + 0.4)])
            }
            let separated = try await engine.diarize(meeting: diarMeeting, audio: audio, model: URL(fileURLWithPath: diar))
            try require(Set(separated.segments.compactMap(\.speakerID)).count >= 2, "streaming diarization lost distinct speakers")
            print("VOICE stream fixture \(separated.segments.count) segments / \(Set(separated.segments.compactMap(\.speakerID)).count) speakers")
        }
    }
    static func largeBatchDecisions(_ root:URL) throws {
        var meeting=Meeting(title:"Large voice batch",sources:[.system],destination:root,keepAudio:false)
        let a=UUID(),b=UUID()
        meeting.segments=(0..<2000).map { i in Segment(source:.system,start:Double(i),end:Double(i)+0.5,text:"Passaggio \(i)",speakerID:"voice-"+(i.isMultiple(of:2) ? a:b).uuidString) }
        let raw:[[String:Any]]=meeting.segments.enumerated().map { i,s in
            ["id":UUID().uuidString,"segmentID":s.id.uuidString,"profileID":(i.isMultiple(of:2) ? a:b).uuidString,"name":i.isMultiple(of:2) ? "Ada":"Bruno","state":"automatic","score":0.95,"margin":0.3,"originalSpeakerID":"Diar \(i%4)"]
        }
        meeting.voiceMatches=try JSONCoding.decoder().decode([VoiceMatch].self,from:JSONSerialization.data(withJSONObject:raw))
        var rejected=meeting
        let began=ProcessInfo.processInfo.systemUptime
        meeting.confirmVoice(a)
        let seconds=ProcessInfo.processInfo.systemUptime-began
        try require(meeting.voiceMatches?.filter{$0.state == .confirmed}.count==1000,"large batch confirmation missed matches")
        try require(meeting.voiceMatches?.filter{$0.profileID==b && $0.state == .automatic}.count==1000,"confirmation changed another profile")
        meeting.rejectVoice(a)
        try require(meeting.voiceMatches?.filter{$0.state == .confirmed}.count==1000,"rejection changed confirmed matches")
        rejected.rejectVoice(a)
        try require(rejected.voiceMatches?.filter{$0.state == .rejected}.count==1000,"large batch rejection missed matches")
        try require(rejected.segments.enumerated().allSatisfy{ i,s in !i.isMultiple(of:2) || s.speakerID=="Diar \(i%4)"},"rejection lost original speakers")
        print("VOICE batch confirmation: 2000 records, \(seconds) seconds")
    }
    static func run() async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbale-voice-checks-" + UUID().uuidString)
        var failures = 0
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for (name, test) in [("private store and guarded ranking", storeAndRanking), ("consensus and manual corrections", consensusAndReview), ("bounded audio, AEC and clean clips", audioAndClips), ("explicit profile name and group boundaries", explicitNames), ("signal quality and advisory boundaries", signalQuality), ("large profile decisions preserve other voices",largeBatchDecisions)] {
                do { try test(root); print("PASS voice \(name)") } catch { failures += 1; print("FAIL voice \(name): \(error)") }
            }
            if let model = ProcessInfo.processInfo.environment["VERBALE_TEST_VOICE_MODEL"] {
                do { try await native(root, model: URL(fileURLWithPath: model)); print("PASS voice native public fixture, enrollment and recognition") }
                catch { failures += 1; print("FAIL voice native: \(error)") }
            } else { print("SKIP voice native fixture (set VERBALE_TEST_VOICE_MODEL)") }
        } catch { failures += 1; print("FAIL voice setup: \(error)") }
        return failures
    }
}
