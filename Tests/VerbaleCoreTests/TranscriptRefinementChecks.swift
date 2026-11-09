import Foundation
import VerbaleCore

enum TranscriptRefinementChecks {
    static func fixture() -> Meeting {
        var meeting = Meeting(title:"Refinement",sources:[.system],destination:FileManager.default.temporaryDirectory,keepAudio:false)
        meeting.segments = [Segment(source:.system,start:0,end:4,text:"Non approvare il cambio.",speakerID:"A",words:[Word(w:"Non",start:0,end:0.4,conf:0.5)]),Segment(source:.system,start:5,end:8,text:"La riunione è venerdì.",speakerID:"B",words:[Word(w:"La",start:5,end:5.3,conf:0.99)])]
        meeting.speakers = ["A":"Anna","B":"Luca"];return meeting
    }
    static func lifecycle() async -> Int {
        let meeting = fixture(),engine = TranscriptionEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = VoiceAudio(workspace:root,exported:root)
        do {
            _ = try await engine.refine(meeting:meeting,audio:audio,scope:.all)
            print("FAIL refinement missing audio silently accepted");return 1
        } catch is CancellationError { return 1 } catch {}
        var outside = meeting;outside.chunks = [AudioChunk(source:.system,start:20,sampleCount:32000,filename:"outside.caf")]
        do {
            let skipped = try await engine.refine(meeting:outside,audio:audio,scope:.all)
            try VoiceChecks.require(skipped.proposals.isEmpty && skipped.warnings.contains(where: { $0.contains("2 passaggi esclusi") }),"out-of-range passages were offered or silently ignored")
        } catch { print("FAIL refinement unavailable interval: \(error)");return 1 }
        var withAudio = meeting;withAudio.chunks = [AudioChunk(source:.system,start:0,sampleCount:160000,filename:"unavailable.caf")]
        let input = withAudio
        let job = Task { withUnsafeCurrentTask { $0?.cancel() };return try await engine.refine(meeting:input,audio:audio,scope:.all) }
        job.cancel()
        do { _ = try await job.value;print("FAIL refinement cancelled job completed");return 1 }
        catch is CancellationError { print("PASS refinement missing audio and cancellation preserve original");return 0 }
        catch { print("FAIL refinement cancellation: \(error)");return 1 }
    }
    static func run() -> Int {
        var failures = 0
        let cases:[(String,() throws -> Void)] = [
            ("merge brief pauses and bound padded spans", {
                let regions = [SpeechSpan(start:0.5,end:2),SpeechSpan(start:2.4,end:4),SpeechSpan(start:6,end:8)]
                let live = ASRSegmentation.spans(regions,duration:10,pass:.live),quality = ASRSegmentation.spans(regions,duration:10,pass:.refinement)
                try VoiceChecks.require(live.count == 3 && quality.count == 2 && quality[0].end < quality[1].start,"brief and long pauses treated identically")
                let bounded = ASRSegmentation.spans([SpeechSpan(start:1,end:16),SpeechSpan(start:16.4,end:30.6)],duration:40,pass:.refinement)
                try VoiceChecks.require(bounded.allSatisfy { $0.end-$0.start <= 30.0001 },"merged spans create tiny trailing ASR calls after padding")
                let adjacent = ASRSegmentation.spans([SpeechSpan(start:0,end:20),SpeechSpan(start:20,end:40)],duration:40,pass:.refinement)
                try VoiceChecks.require(adjacent.count == 2 && adjacent[0].end <= adjacent[1].start,"padding duplicated audio between bounded spans")
            }),
            ("uncertain scope and manual protection", {
                var m = fixture();try VoiceChecks.require(TranscriptRefinementPlanner.targets(m,scope:.uncertain).map(\.id) == [m.segments[0].id],"confidence selection incorrect")
                let id = m.segments[0].id;try m.correctSegment(id,text:"Non approvare la modifica.",speakerID:"A")
                try VoiceChecks.require(!TranscriptRefinementPlanner.targets(m,scope:.all).contains(where:{$0.id == id}),"manual correction included")
                var draft = try TranscriptRefinement(meeting:m,proposals:[TranscriptProposal(segment:m.segments[0],candidate:"Approva.")])
                try VoiceChecks.refuses { try draft.apply([id],to:&m) }
            }),
            ("allocate words once across overlapping passages", {
                var m = fixture();m.segments[0].text = "Prima";m.segments[1].text = "Seconda";m.segments[0].end = 5.5;m.segments[1].start = 5
                let recognized = Segment(source:.system,start:5.1,end:5.4,text:"Nuovo",words:[Word(w:"Nuovo",start:5.1,end:5.4)])
                let p = TranscriptRefinementPlanner.proposals(targets:m.segments,recognized:[recognized],context:m.segments)
                try VoiceChecks.require(p.count == 1,"overlap offered the same word twice")
                let subset = TranscriptRefinementPlanner.proposals(targets:[m.segments[1]],recognized:[recognized],context:m.segments)
                try VoiceChecks.require(subset.isEmpty,"selected passage borrowed another passage’s words")
            }),
            ("ignore cosmetic differences and boundary truncations", {
                let old = Segment(source:.system,start:0,end:3,text:"Cioè sono qui.")
                let cropped = Segment(source:.system,start:0,end:3,text:"sono qui",words:[Word(w:"sono",start:1,end:1.5),Word(w:"qui",start:2,end:2.5)])
                try VoiceChecks.require(TranscriptRefinementPlanner.proposals(targets:[old],recognized:[cropped]).isEmpty,"crop offered as quality improvement")
                let cosmetic = Segment(source:.system,start:0,end:3,text:"cioè sono qui",words:[Word(w:"cioè",start:0,end:0.5),Word(w:"sono",start:1,end:1.5),Word(w:"qui",start:2,end:2.5)])
                try VoiceChecks.require(TranscriptRefinementPlanner.proposals(targets:[old],recognized:[cosmetic]).isEmpty,"cosmetic change created review work")
                let negative = Segment(source:.system,start:0,end:3,text:"Non approvare")
                let omission = Segment(source:.system,start:0,end:3,text:"approvare",words:[Word(w:"approvare",start:1,end:2)])
                try VoiceChecks.require(TranscriptRefinementPlanner.proposals(targets:[negative],recognized:[omission]).isEmpty,"dropped negation offered as improvement")
            }),
            ("selective adoption preserves identity timestamps anchors", {
                var m = fixture();m.speakers = [:]
                let rank = VoiceRanking(profileID:UUID(),name:"Anna",score:0.95,margin:0.4)
                m.applyVoiceGroup([m.segments[0].id],ranking:rank,automatic:true)
                let before = m.segments[0],matches = try JSONCoding.encoder().encode(m.voiceMatches)
                var draft = try TranscriptRefinement(meeting:m,proposals:[TranscriptProposal(segment:before,candidate:"Non approvare la modifica.")])
                try draft.apply([before.id],to:&m)
                try VoiceChecks.require(m.segments[0].id == before.id && m.segments[0].start == before.start && m.segments[0].end == before.end && m.segments[0].speakerID == before.speakerID,"adoption changed anchors or speaker")
                try VoiceChecks.require(try JSONCoding.encoder().encode(m.voiceMatches) == matches,"word acceptance confirmed speaker identity")
                try VoiceChecks.require(m.segments[1].text == "La riunione è venerdì." && m.corrections.count == 1,"unselected passage changed")
            }),
            ("undo survives notes and keeps existing history", {
                var m = fixture();try m.correctSegment(m.segments[1].id,text:"La riunione è giovedì.",speakerID:"B")
                m.notes = "Nota privata";m.report = "Report precedente";m.reportStatus = "Completato"
                let before = try JSONCoding.encoder().encode(m.segments)
                var draft = try TranscriptRefinement(meeting:m,proposals:[TranscriptProposal(segment:m.segments[0],candidate:"Non approvare la modifica.")])
                try VoiceChecks.require(draft.original.notes.isEmpty && draft.original.report == nil,"revision copied unrelated personal notes/report")
                try draft.apply([m.segments[0].id],to:&m);m.notes = "Nota aggiunta dopo"
                try m.addMarker(.decision,at:6)
                try draft.undo(in:&m)
                try VoiceChecks.require(try JSONCoding.encoder().encode(m.segments) == before,"undo did not restore original words/timings")
                try VoiceChecks.require(m.notes == "Nota aggiunta dopo" && m.markers.count == 1 && m.corrections.count == 1 && m.reportNeedsUpdate,"undo lost notes/markers or restored stale report")
            }),
            ("stale changes reject adoption and undo", {
                var m = fixture();var draft = try TranscriptRefinement(meeting:m,proposals:[TranscriptProposal(segment:m.segments[0],candidate:"Nuova proposta.")])
                m.speakers["A"] = "Altra persona";try VoiceChecks.refuses { try draft.apply([m.segments[0].id],to:&m) }
                m = fixture();m.speakers = [:];let rank = VoiceRanking(profileID:UUID(),name:"Anna",score:0.9,margin:0.3);m.applyVoiceGroup([m.segments[0].id],ranking:rank,automatic:true)
                draft = try TranscriptRefinement(meeting:m,proposals:[TranscriptProposal(segment:m.segments[0],candidate:"Nuova proposta.")]);try draft.apply([m.segments[0].id],to:&m)
                m.confirmVoice(rank.profileID);try VoiceChecks.refuses { try draft.undo(in:&m) }
            }),
            ("batch text review retains automatic voice provenance", {
                var m = fixture();m.speakers = [:]
                let group = SpeakerAuditGroup(label:"Voce",clips:[])
                let pieces = m.segments.map { SpeakerAuditPiece(originalID:$0.id,segment:$0,groupID:group.id) }
                var audit = try SpeakerAudit(meeting:m,groups:[group],pieces:pieces,modelDigests:[:],warnings:[])
                let matches = Dictionary(uniqueKeysWithValues:pieces.map { ($0.id,SpeakerLearningMatch(name:"Anna",score:0.95,margin:0.4)) })
                try audit.apply(groupID:group.id,selected:Set(pieces.map(\.id)),name:"Anna",to:&m,automatic:matches)
                let before = m
                var draft = try TranscriptRefinement(meeting:m,proposals:m.segments.map { TranscriptProposal(segment:$0,candidate:$0.text+" Verificato.") })
                draft.originalSpeakerAnalysis = audit
                try draft.apply(Set(draft.pending.map(\.id)),to:&m)
                try audit.rebaseTranscriptChanges(previous:before,updated:m)
                try VoiceChecks.require(audit.isCurrent(for:m) && audit.manualEvidence.isEmpty && audit.automaticAssignments?.count == 2,"text approval became identity evidence or discarded recognition provenance")
                try draft.undo(in:&m)
                try VoiceChecks.require(draft.originalSpeakerAnalysis?.isCurrent(for:m) == true,"voice analysis cannot be restored with transcript")
            }),
            ("revision reopens with pending proposals and undo", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
                var m = fixture();var draft = try TranscriptRefinement(meeting:m,proposals:m.segments.map { TranscriptProposal(segment:$0,candidate:$0.text+" Verificato.") })
                try draft.apply([m.segments[0].id],to:&m);let url = root.appendingPathComponent("revision.json");try draft.save(to:url)
                var reopened = try TranscriptRefinement.load(from:url)
                try VoiceChecks.require(reopened.pending.count == 1 && reopened.isCurrent(for:m),"partial revision did not reopen")
                try reopened.undo(in:&m);try VoiceChecks.require(m.segments[0].text == draft.original.segments[0].text,"reopened undo unavailable")
            })
        ]
        for (name,body) in cases { do { try body();print("PASS refinement \(name)") } catch { failures += 1;print("FAIL refinement \(name): \(error)") } }
        return failures
    }
}
