import Foundation
import VerbaleCore

enum SpeakerLearningChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw VerbaleError.message(message) } }
    static func matcher() throws {
        let manual = SpeakerLearningReference(name:"A",vector:[1,0,0],evidenceID:"manual",explicitlyConfirmed:true)
        let predicted = SpeakerLearningReference(name:"B",vector:[0,1,0],evidenceID:"automatic",explicitlyConfirmed:false)
        try require(try SpeakerLearningMatcher.match([1,0,0],references:[manual])?.name == "A","confirmed evidence not used")
        try require(try SpeakerLearningMatcher.match([0,1,0],references:[manual,predicted]) == nil,"automatic prediction used as training evidence")
        let conflict = SpeakerLearningReference(name:"Other",vector:[1,0,0],evidenceID:"other-manual",explicitlyConfirmed:true)
        try require(try SpeakerLearningMatcher.match([1,0,0],references:[manual,conflict]) == nil,"conflicting identities forced to a name")
        try require(try SpeakerLearningMatcher.match([0,0,1],references:[manual]) == nil,"unknown voice forced to known name")
    }
    static func units() throws {
        let id = UUID(), group = UUID()
        func piece(_ start:Double,_ end:Double) -> SpeakerAuditPiece { SpeakerAuditPiece(originalID:id,segment:Segment(source:.system,start:start,end:end,text:"test"),groupID:group) }
        let small = [piece(0,1.8),piece(20,21.8)]
        try require(SpeakerLearningUnits.references(small).count == 1,"confirmed short utterances cannot be combined")
        try require(SpeakerLearningUnits.candidates(small).isEmpty,"unverified context bridged between candidate turns")
        let continuous = [piece(0,1.8),piece(1.9,3.7)]
        try require(SpeakerLearningUnits.candidates(continuous).count == 1,"adjacent same-group candidate speech not covered")
        let long = piece(0,24)
        let split = SpeakerLearningUnits.candidates([long])
        try require(split.count == 4 && split.allSatisfy { $0.duration >= 3 && $0.duration <= 7.5 },"long passages not bounded")
        try require(abs(split.reduce(0) { $0+$1.duration }-24) < 0.001,"long passage audio lost")
    }
    static func provenance(_ root:URL) throws {
        var meeting = Meeting(title:"Provenance",sources:[.system],destination:root,keepAudio:false)
        let original = Segment(source:.system,start:0,end:4,text:"speech")
        meeting.segments = [original]; let group = SpeakerAuditGroup(label:"candidate",clips:[])
        let piece = SpeakerAuditPiece(originalID:original.id,segment:original,groupID:group.id)
        var audit = try SpeakerAudit(meeting:meeting,groups:[group],pieces:[piece],modelDigests:[:],warnings:[])
        let match = SpeakerLearningMatch(name:"A",score:0.95,margin:0.4)
        try audit.apply(groupID:group.id,selected:[piece.id],name:"A",to:&meeting,automatic:[piece.id:match])
        try require(audit.manualEvidence.isEmpty && meeting.corrections.isEmpty,"automatic prediction recorded as manual confirmation")
        try require(audit.pending(group.id).isEmpty && audit.automaticAssignments?.count == 1,"automatic assignment leaves stale review task")
        let fresh = try meeting.preparingVoiceAnalysis(learning:audit)
        try require(fresh.segments[0].speakerID == nil && meeting.segments[0].speakerID?.hasPrefix("auto-learn-") == true,"fresh analysis froze learned predictions as manual names or changed its input")
        var manuallyRenamed = meeting; manuallyRenamed.speakers[manuallyRenamed.segments[0].speakerID!] = "Manual rename"
        let renamedFresh = try manuallyRenamed.preparingVoiceAnalysis(learning:audit)
        try require(renamedFresh.speakerName(for:renamedFresh.segments[0]) == "Manual rename","fresh analysis retracted a later manual rename")
        try audit.retractAutomatic(in:&meeting)
        try require(meeting.segments[0].speakerID == nil && audit.pending(group.id).count == 1,"uncertain prediction cannot be retracted")
        try audit.apply(groupID:group.id,selected:[piece.id],name:"A",to:&meeting,automatic:[piece.id:match])
        try audit.apply(groupID:group.id,selected:[piece.id],name:"Human correction",to:&meeting)
        try require(audit.manualEvidence[piece.id.uuidString] == "Human correction" && audit.automaticAssignments?.isEmpty == true,"manual override did not replace prediction provenance")
        try audit.retractAutomatic(in:&meeting)
        try require(meeting.speakerName(for:meeting.segments[0]) == "Human correction","manual correction retracted")
        let saved = root.appendingPathComponent("learning-analysis.json");try audit.save(to:saved)
        let loaded = try SpeakerAudit.load(from:saved)
        try require(loaded.manualEvidence == audit.manualEvidence && loaded.isCurrent(for:meeting),"confirmation provenance lost after reload")
    }
    static func splitCorrections(_ root:URL) throws {
        var meeting = Meeting(title:"Split corrections",sources:[.system],destination:root,keepAudio:false)
        let parent = Segment(source:.system,start:0,end:8,text:"original full text",words:[Word(w:"left",start:0,end:4),Word(w:"right",start:4,end:8)])
        meeting.segments = [parent]
        let a = SpeakerAuditGroup(label:"A",clips:[]), b = SpeakerAuditGroup(label:"B",clips:[])
        var left = Segment(source:.system,start:0,end:4,text:"left",words:[Word(w:"left",start:0,end:4)]);left.id = parent.id
        let right = Segment(source:.system,start:4,end:8,text:"right",words:[Word(w:"right",start:4,end:8)])
        var audit = try SpeakerAudit(meeting:meeting,groups:[a,b],pieces:[SpeakerAuditPiece(originalID:parent.id,segment:left,groupID:a.id),SpeakerAuditPiece(originalID:parent.id,segment:right,groupID:b.id)],modelDigests:[:],warnings:[])
        try audit.apply(groupID:a.id,selected:[left.id],name:"A",to:&meeting)
        try meeting.correctSegment(left.id,text:"manually corrected text",speakerID:meeting.segments[0].speakerID)
        try audit.noteManualAssignment(segmentID:left.id,name:"A",meeting:meeting)
        try audit.apply(groupID:b.id,selected:[right.id],name:"B",to:&meeting,automatic:[right.id:SpeakerLearningMatch(name:"B",score:0.99,margin:0.4)])
        try require(meeting.segments[0].text == "manually corrected text","automatic sibling update overwrote manual text")
        meeting.speakers["manual-C"] = "C"
        try meeting.correctSegment(right.id,text:meeting.segments[1].text,speakerID:"manual-C")
        try audit.noteManualAssignment(segmentID:right.id,name:"C",meeting:meeting)
        try require(audit.manualEvidence[right.id.uuidString] == "C" && audit.automaticAssignments?[right.id.uuidString] == nil,"correction of a split child did not become trusted evidence")
    }
    static func textIsNotVoiceEvidence(_ root:URL) throws {
        var meeting = Meeting(title:"Text only",sources:[.system],destination:root,keepAudio:false)
        let segment = Segment(source:.system,start:0,end:4,text:"old text")
        meeting.segments = [segment];let group = SpeakerAuditGroup(label:"candidate",clips:[])
        var audit = try SpeakerAudit(meeting:meeting,groups:[group],pieces:[SpeakerAuditPiece(originalID:segment.id,segment:segment,groupID:group.id)],modelDigests:[:],warnings:[])
        try audit.apply(groupID:group.id,selected:[segment.id],name:"Automatic name",to:&meeting,automatic:[segment.id:SpeakerLearningMatch(name:"Automatic name",score:0.99,margin:0.3)])
        let previous = meeting
        try meeting.correctSegment(segment.id,text:"corrected transcript",speakerID:meeting.segments[0].speakerID)
        try audit.rebaseTextCorrection(segmentID:segment.id,previous:previous,updated:meeting)
        try require(audit.manualEvidence.isEmpty && audit.isCurrent(for:meeting),"text edit became identity confirmation or invalidated all proposals")
        try audit.retractAutomatic(in:&meeting)
        try require(meeting.segments[0].text == "corrected transcript" && meeting.segments[0].speakerID == nil,"prediction rollback lost manual text")
        let p = Segment(source:.system,start:10,end:18,text:"old full",words:[Word(w:"one",start:10,end:14),Word(w:"two",start:14,end:18)])
        var base = Meeting(title:"Unsplit edit",sources:[.system],destination:root,keepAudio:false);base.segments = [p]
        var first = Segment(source:.system,start:10,end:14,text:"one");first.id = p.id
        let second = Segment(source:.system,start:14,end:18,text:"two")
        var split = try SpeakerAudit(meeting:base,groups:[group],pieces:[SpeakerAuditPiece(originalID:p.id,segment:first,groupID:group.id),SpeakerAuditPiece(originalID:p.id,segment:second,groupID:group.id)],modelDigests:[:],warnings:[])
        let before = base
        try base.correctSegment(p.id,text:"edited whole paragraph",speakerID:nil)
        try split.rebaseTextCorrection(segmentID:p.id,previous:before,updated:base)
        try require(split.pieces.count == 1 && split.pieces[0].segment.text == "edited whole paragraph" && split.manualEvidence.isEmpty,"obsolete word partitions survive a whole-paragraph edit")
    }
    static func native(_ root:URL, voice:URL) async throws {
        let fixture = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("native/parakeet.cpp/tests/fixtures/two_speakers.wav")
        let pcm = try AudioFiles.samples(fixture)
        func slice(_ a:Double,_ b:Double) -> [Float] { Array(pcm[Int(a*16000)..<Int(b*16000)]) }
        let a = slice(0.6,4.6), b = slice(6.9,10.9), a2 = slice(14.9,18.7)
        let clips = [a,a,b,b,a2,a2]
        var signal: [Float] = []
        for clip in clips { signal += clip; signal += [Float](repeating:0,count:96000-clip.count) }
        try AudioFiles.write(signal,to:root.appendingPathComponent("public-learning.caf"))
        var meeting = Meeting(title:"Verified public speakers",sources:[.system],destination:root,keepAudio:true)
        meeting.duration = Double(signal.count)/16000
        meeting.chunks = [AudioChunk(source:.system,start:0,sampleCount:signal.count,filename:"public-learning.caf")]
        meeting.segments = clips.enumerated().map { i,clip in Segment(source:.system,start:Double(i*6),end:Double(i*6)+Double(clip.count)/16000,text:"public \(i)",speakerID:"old") }
        meeting.speakers = ["old":"Unverified old cluster"]
        let group = SpeakerAuditGroup(label:"Mixed original group",clips:[])
        var pieces = meeting.segments.map { SpeakerAuditPiece(originalID:$0.id,segment:$0,groupID:group.id) }
        pieces[5].groupID = nil
        var audit = try SpeakerAudit(meeting:meeting,groups:[group],pieces:pieces,modelDigests:[:],warnings:[])
        let engine = VoiceAnalysisEngine(), audio = VoiceAudio(workspace:root,exported:root), hash = try ModelManager.digest(voice)
        let cache = root.appendingPathComponent("private-speaker-cache.json")
        try audit.apply(groupID:group.id,selected:[pieces[0].id],name:"Public A",to:&meeting)
        let first = try await engine.reevaluateSpeakers(meeting:meeting,audit:audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache)
        try require(first.automaticCount >= 1 && first.audit.automaticAssignments?[pieces[1].id.uuidString]?.name == "Public A","confirmation did not propagate to matching public audio")
        try require(first.audit.automaticAssignments?[pieces[2].id.uuidString] == nil && first.audit.automaticAssignments?[pieces[3].id.uuidString] == nil,"different public voice inherited label from whole cluster")
        try require(first.referenceCount == 1 && first.audit.manualEvidence.count == 1,"first automatic outputs became training samples")
        meeting = first.meeting; audit = first.audit
        try audit.apply(groupID:group.id,selected:[pieces[2].id],name:"Public B",to:&meeting)
        let second = try await engine.reevaluateSpeakers(meeting:meeting,audit:audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache)
        try require(second.audit.automaticAssignments?[pieces[3].id.uuidString]?.name == "Public B" && second.referenceCount == 2,"new person does not reduce unresolved passages")
        try require(second.computedEmbeddings == 0 && second.cacheHits > 0,"unchanged audio re-encoded on each confirmation")
        meeting = second.meeting; audit = second.audit
        try audit.apply(groupID:group.id,selected:[pieces[4].id],name:"Public A",to:&meeting)
        let third = try await engine.reevaluateSpeakers(meeting:meeting,audit:audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache)
        try require(third.audit.automaticAssignments?[pieces[5].id.uuidString]?.name == "Public A" && third.referenceCount == 3,"additional confirmed utterance does not improve voice coverage")
        try require(third.unresolvedCount < first.unresolvedCount,"reviews did not decrease after further confirmations")
        meeting = third.meeting; audit = third.audit; meeting.speakers["manual-C"] = "Corrected B"
        try meeting.correctSegment(pieces[2].id,text:meeting.segments[2].text,speakerID:"manual-C")
        try audit.noteManualAssignment(segmentID:pieces[2].id,name:"Corrected B",meeting:meeting)
        let corrected = try await engine.reevaluateSpeakers(meeting:meeting,audit:audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache)
        try require(corrected.meeting.speakerName(for:corrected.meeting.segments[2]) == "Corrected B" && corrected.audit.automaticAssignments?[pieces[3].id.uuidString]?.name == "Corrected B","correction does not revise earlier automatic assignments")
        let beforeCancellation = try JSONCoding.encoder().encode(corrected.meeting)
        let beforeCache = try Data(contentsOf:cache)
        let task = Task { try await engine.reevaluateSpeakers(meeting:corrected.meeting,audit:corrected.audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache) }
        task.cancel()
        do { _ = try await task.value; throw VerbaleError.message("cancelled reevaluation completed") }
        catch is CancellationError {} catch { throw error }
        try require(try JSONCoding.encoder().encode(corrected.meeting) == beforeCancellation && Data(contentsOf:cache) == beforeCache,"cancel changed confirmed state or cache")
        let manifest = String(data:try JSONCoding.encoder().encode(corrected.audit),encoding:.utf8)!
        try require(!manifest.contains("vectors") && !manifest.contains("embedding"),"embeddings leaked into proposals")
        let permissions = try FileManager.default.attributesOfItem(atPath:cache.path)[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600,"cache not private")
        print("LEARNING public fixture: unresolved \(first.unresolvedCount) → \(second.unresolvedCount) → \(third.unresolvedCount), references \(first.referenceCount) → \(second.referenceCount) → \(third.referenceCount), warm cache computations \(second.computedEmbeddings)")
    }
    static func run() async -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbale-learning-"+UUID().uuidString)
        var failures = 0
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
            for (name,test) in [("trusted-only matching and unknown rejection",{ try matcher() }),("confirmed concatenation and bounded candidate windows",{ try units() }),("retraction and manual precedence",{ try provenance(root) }),("split-child feedback and manual text protection",{ try splitCorrections(root) }),("text correction is not identity confirmation",{ try textIsNotVoiceEvidence(root) })] {
                do { try test();print("PASS progressive learning \(name)") } catch { failures += 1;print("FAIL progressive learning \(name): \(error)") }
            }
            if let model = ProcessInfo.processInfo.environment["VERBALE_TEST_VOICE_MODEL"] {
                do { try await native(root,voice:URL(fileURLWithPath:model));print("PASS progressive learning native confirmations, shrinking queue and cached reevaluation") }
                catch { failures += 1;print("FAIL progressive learning native: \(error)") }
            } else { print("SKIP progressive learning native (set VERBALE_TEST_VOICE_MODEL)") }
        } catch { failures += 1;print("FAIL progressive learning setup: \(error)") }
        return failures
    }
}
