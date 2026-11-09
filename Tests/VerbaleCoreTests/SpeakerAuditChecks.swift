import Foundation
import VerbaleCore

enum SpeakerAuditChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw VerbaleError.message(message) } }
    static func refuses(_ body: () throws -> Void) throws { var rejected = false; do { try body() } catch { rejected = true }; try require(rejected,"invalid proposal accepted") }
    static func linking() throws {
        var linker = SpeakerWindowLinker()
        let meetingID = UUID()
        func clip(_ t: Double) -> VoiceClip { VoiceClip(meetingID: meetingID, source: .system, start: t, end: t+4, text: "test") }
        for i in 0..<12 {
            var vector = [Float](repeating: 0,count: 16); vector[i] = 1
            let index = try linker.link(vectors: [vector,vector], clips: [clip(Double(i)*5)], usedInWindow: [])
            try require(index == i,"distinct voices merged")
        }
        try require(linker.tracks.count == 12,"global identities retain an eight-speaker ceiling")
        var first = [Float](repeating: 0,count: 16); first[0] = 1
        let same = try linker.link(vectors: [first], clips: [clip(100)], usedInWindow: [])
        try require(same == 0 && linker.tracks.count == 12,"same voice not linked across windows")
        let anchored = try linker.link(vectors: [first], clips: [clip(105)], usedInWindow: [], temporalAnchor: 0)
        try require(anchored == 0,"clean overlap anchor not respected")
        var conflicting = [Float](repeating:0,count:16); conflicting[1] = 1
        let contradiction = try linker.link(vectors:[conflicting],clips:[clip(106)],usedInWindow:[],temporalAnchor:0)
        try require(contradiction != 0,"overlap anchor ignored a strong voice contradiction")
        let occupied = try linker.link(vectors: [first], clips: [clip(110)], usedInWindow: [0])
        try require(occupied != 0,"two simultaneous local slots merged into one identity")
        let ambiguous = try linker.link(vectors: [first], clips: [clip(120)], usedInWindow: [])
        try require(ambiguous != 0 && ambiguous != occupied,"ambiguous identity forced into an existing track")
    }
    static func application(_ root: URL) throws {
        var meeting = Meeting(title: "Original names", sources: [.system], destination: root, keepAudio: false)
        let words = [Word(w: "One", start: 0,end: 1),Word(w: "two",start: 1,end: 2),Word(w: "three",start: 2,end: 3),Word(w: "four",start: 3,end: 4)]
        let original = Segment(source: .system,start: 0,end: 4,text: "One two three four",speakerID: "old",words: words)
        let untouched = Segment(source: .system,start: 10,end: 11,text: "Leave this exact text!",speakerID: "other",words: [Word(w: "Leave",start: 10,end: 11)])
        meeting.segments = [original,untouched]; meeting.speakers = ["old":"Existing person","other":"Untouched person"]
        meeting.report = "Existing report"; meeting.reportStatus = "Completato"
        let a = SpeakerAuditGroup(label: "A",clips: []), b = SpeakerAuditGroup(label: "B",clips: [])
        var left = Segment(source: .system,start: 0,end: 2,text: "One two",words:Array(words.prefix(2))); left.id = original.id
        let right = Segment(source: .system,start: 2,end: 4,text: "three four",words:Array(words.suffix(2)))
        // Include an unmaterialized split for an unrelated parent: it must never be applied accidentally.
        var untouchedPiece = untouched; untouchedPiece.text = "Leave"
        let pieces = [SpeakerAuditPiece(originalID:original.id,segment:left,groupID:a.id),SpeakerAuditPiece(originalID:original.id,segment:right,groupID:b.id),SpeakerAuditPiece(originalID:untouched.id,segment:untouchedPiece,groupID:a.id)]
        let before = try JSONCoding.encoder().encode(meeting)
        var audit = try SpeakerAudit(meeting: meeting,groups:[a,b],pieces:pieces,modelDigests:[:],warnings:[])
        try require(try JSONCoding.encoder().encode(meeting) == before,"creating analysis modifies meeting")
        let file = root.appendingPathComponent("speaker-audit.json")
        try audit.save(to: file); audit = try SpeakerAudit.load(from:file)
        try require(audit.isCurrent(for:meeting),"persisted analysis fingerprint mismatch")
        var stale = meeting; stale.speakers["old"] = "Renamed after analysis"
        try refuses { try audit.apply(groupID:a.id,selected:[left.id],name:"New person",to:&stale) }
        try refuses { try audit.apply(groupID:a.id,selected:[right.id],name:"Wrong group",to:&meeting) }
        try require(try JSONCoding.encoder().encode(meeting) == before,"failed apply changed original")
        try audit.apply(groupID:b.id,selected:[right.id],name:"New person",to:&meeting)
        try require(meeting.segments.count == 3,"selected parent was not partitioned")
        try require(meeting.segments[0].id == original.id && meeting.speakerName(for:meeting.segments[0]) == "Existing person","unselected sibling lost anchor or name")
        try require(meeting.speakerName(for:meeting.segments[1]) == "New person","selected proposal not assigned")
        try require(meeting.segments[2].text == untouched.text && meeting.speakerName(for:meeting.segments[2]) == "Untouched person","unrelated parent changed")
        try require(meeting.corrections.first?.previousText == original.text && meeting.reportNeedsUpdate,"original history or report invalidation missing")
        try require(audit.isCurrent(for:meeting) && audit.applied == [right.id],"incremental review state lost")
        try audit.apply(groupID:a.id,selected:[left.id],name:"Another person",to:&meeting)
        try require(meeting.segments.count == 3 && meeting.speakerName(for:meeting.segments[1]) == "New person","second confirmation overwrote earlier selection")
        try require(meeting.speakerName(for:meeting.segments[0]) == "Another person" && meeting.segments[2].text == untouched.text,"second partial apply failed")
        let json = String(data:try JSONCoding.encoder().encode(audit),encoding:.utf8)!
        try require(!json.contains("embedding"),"biometric vectors leaked into analysis artifact")
    }
    static func triage(_ root: URL) throws {
        var meeting = Meeting(title:"Quick review",sources:[.system],destination:root,keepAudio:false)
        var groups: [SpeakerAuditGroup] = [], pieces: [SpeakerAuditPiece] = []
        for person in 0..<8 {
            let key = "old-\(person)"; meeting.speakers[key] = "Person \(person)"
            for variant in 0..<4 {
                let clips = [VoiceClip(meetingID:meeting.id,source:.system,start:0,end:4,text:"fixture"),VoiceClip(meetingID:meeting.id,source:.system,start:5,end:9,text:"fixture")]
                let group = SpeakerAuditGroup(label:"Fragment",clips:clips); groups.append(group)
                for line in 0..<3 {
                    let start = Double(person*200+variant*40+line*10)
                    let segment = Segment(source:.system,start:start,end:start+(variant == 0 ? 10:8),text:"sample",speakerID:key)
                    meeting.segments.append(segment); pieces.append(SpeakerAuditPiece(originalID:segment.id,segment:segment,groupID:group.id))
                }
            }
        }
        // Many tiny unsupported fragments must not create a long quick-review queue.
        for i in 0..<80 {
            let segment = Segment(source:.system,start:Double(2000+i),end:Double(2000+i)+0.3,text:"short",speakerID:"old-0")
            meeting.segments.append(segment)
            let group = SpeakerAuditGroup(label:"Short",clips:[]);groups.append(group)
            pieces.append(SpeakerAuditPiece(originalID:segment.id,segment:segment,groupID:group.id))
        }
        let before = try JSONCoding.encoder().encode(meeting)
        var audit = try SpeakerAudit(meeting:meeting,groups:groups,pieces:pieces,modelDigests:[:],warnings:[])
        let initial = SpeakerAuditTriage(audit:audit,meeting:meeting)
        try require(initial.cases.count == 5 && initial.remainingPeopleCount == 8,"quick review does not bound the queue per person")
        try require(initial.cases.allSatisfy { $0.examples.count <= 3 && !$0.referenceIDs.isEmpty },"reference/contrast excerpts missing or unbounded")
        try require(Set(initial.cases.map(\.bucket)).count == initial.cases.count,"same person repeated in batch")
        var steps = 0
        while let next = SpeakerAuditTriage(audit:audit,meeting:meeting).cases.first {
            var seen = audit.reviewedBuckets ?? [];seen.insert(next.bucket);audit.reviewedBuckets = seen;steps += 1
            try require(steps <= 8,"quick review still asks to inspect every fragment")
        }
        try require(steps == 8 && audit.groups.count == 112 && audit.applied.isEmpty,"triage silently discarded or applied proposals")
        try require(try JSONCoding.encoder().encode(meeting) == before,"triage or deferral modified transcript")
        let file = root.appendingPathComponent("triage.json");try audit.save(to:file)
        let loaded = try SpeakerAudit.load(from:file)
        try require(SpeakerAuditTriage(audit:loaded,meeting:meeting).cases.isEmpty && loaded.groups.count == 112,"deferred review state lost on reload")
    }
    static func native(_ root: URL, voice: URL, diar: URL) async throws {
        let fixture = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("native/parakeet.cpp/tests/fixtures/two_speakers.wav")
        let pcm = try AudioFiles.samples(fixture)
        try AudioFiles.write(pcm,to:root.appendingPathComponent("public.caf"))
        var meeting = Meeting(title:"Public fixture",sources:[.system],destination:root,keepAudio:true)
        meeting.duration = Double(pcm.count)/16000
        meeting.chunks = [AudioChunk(source:.system,start:0,sampleCount:pcm.count,filename:"public.caf")]
        let words = (0..<Int(meeting.duration*2)).map { i in Word(w:"word",start:Double(i)/2,end:Double(i)/2+0.35) }
        meeting.segments = [Segment(source:.system,start:0,end:meeting.duration,text:words.map(\.w).joined(separator:" "),speakerID:"original",words:words)]
        meeting.speakers = ["original":"Original name"]
        let before = try JSONCoding.encoder().encode(meeting)
        let engine = VoiceAnalysisEngine()
        let audit = try await engine.auditSpeakers(meeting:meeting,audio:VoiceAudio(workspace:root,exported:root),diarization:diar,voice:voice,voiceHash:ModelManager.digest(voice),settings:SpeakerWindowSettings(coreDuration:8,context:15))
        try require(try JSONCoding.encoder().encode(meeting) == before,"native analysis changed source")
        try require(audit.isCurrent(for:meeting) && audit.groups.count >= 2 && !audit.pieces.isEmpty,"windowed native analysis missing distinct groups")
        try require(audit.pieces.map(\.segment.words.count).reduce(0,+) == words.count,"window analysis dropped words")
        print("AUDIT public fixture: \(audit.groups.count) proposed groups, \(audit.pieces.count) pieces across three overlapping windows")
        let repeatedPCM = Array(repeating:pcm,count:6).flatMap { $0 }
        try AudioFiles.write(repeatedPCM,to:root.appendingPathComponent("repeated.caf"))
        var repeated = meeting; repeated.duration = Double(repeatedPCM.count)/16000
        repeated.chunks = [AudioChunk(source:.system,start:0,sampleCount:repeatedPCM.count,filename:"repeated.caf")]
        repeated.segments = (0..<Int(repeated.duration*2)).map { i in
            let t = Double(i)/2
            return Segment(source:.system,start:t,end:t+0.35,text:"word",words:[Word(w:"word",start:t,end:t+0.35)])
        }
        let linked = try await engine.auditSpeakers(meeting:repeated,audio:VoiceAudio(workspace:root,exported:root),diarization:diar,voice:voice,voiceHash:ModelManager.digest(voice))
        print("AUDIT repeated public two-voice fixture: \(linked.groups.count) groups across default windows")
        try require(linked.groups.count == 2,"default windows duplicate the two known public voices")
        let task = Task { try await engine.auditSpeakers(meeting:meeting,audio:VoiceAudio(workspace:root,exported:root),diarization:diar,voice:voice,voiceHash:ModelManager.digest(voice)) }
        task.cancel()
        do { _ = try await task.value; throw VerbaleError.message("cancelled analysis completed") }
        catch is CancellationError {} catch { throw error }
    }
    static func run() async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbale-speaker-audit-"+UUID().uuidString)
        var failures = 0
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
            for (name,test) in [("unbounded global identities and ambiguity",{ try linking() }),("isolated proposals, partial apply and stale inputs",{ try application(root) }),("bounded review per person and persistent deferral",{ try triage(root) })] {
                do { try test(); print("PASS speaker audit \(name)") } catch { failures += 1; print("FAIL speaker audit \(name): \(error)") }
            }
            if let v = ProcessInfo.processInfo.environment["VERBALE_TEST_VOICE_MODEL"],let d = ProcessInfo.processInfo.environment["VERBALE_TEST_DIAR_MODEL"] {
                do { try await native(root,voice:URL(fileURLWithPath:v),diar:URL(fileURLWithPath:d)); print("PASS speaker audit native overlapping windows and cancellation") }
                catch { failures += 1; print("FAIL speaker audit native: \(error)") }
            } else { print("SKIP speaker audit native (set voice and diarization model paths)") }
        } catch { failures += 1; print("FAIL speaker audit setup: \(error)") }
        return failures
    }
}
