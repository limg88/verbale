import Foundation
import VerbaleCore

/// Explicit local diagnostics on a disposable SessionStore, never an archive migration.
enum MeetingVoiceCheck {
    static func run(input:URL,diar:URL,voice:URL,profilesURL:URL,output:URL,includeAudit:Bool = false) async throws {
        guard !FileManager.default.fileExists(atPath:output.path) else { throw VerbaleError.message("La cartella del test esiste già.") }
        let original = try Data(contentsOf:input)
        let profiles = try JSONCoding.decoder().decode([VoiceProfile].self,from:Data(contentsOf:profilesURL))
        var meeting = try JSONCoding.decoder().decode(Meeting.self,from:original)
        let sourceAudio = VoiceAudio(workspace:input.deletingLastPathComponent(),exported:URL(fileURLWithPath:meeting.destination).appendingPathComponent(meeting.folderName))
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let store = try SessionStore(root:output.appendingPathComponent("sessions"))
        let exported = output.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at:exported,withIntermediateDirectories:true)
        meeting.destination = exported.path
        try store.save(meeting)
        var missing = 0
        for name in Set(meeting.chunks.flatMap { [$0.filename]+($0.cleanedFilename.map { [$0] } ?? []) }+meeting.screenshots.map(\.filename)) {
            guard let source = try? sourceAudio.url(name) else { missing += 1; continue }
            let target = store.workspace(meeting.id).appendingPathComponent(name)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:source,to:target)
        }
        let audio = VoiceAudio(workspace:store.workspace(meeting.id),exported:exported.appendingPathComponent(meeting.folderName))
        let engine = VoiceAnalysisEngine(), hash = try ModelManager.digest(voice)
        var checks:[String:Bool] = [:], notes:[String:String] = [:]
        let started = Date()
        let log: @Sendable (String)->Void = { message in FileHandle.standardError.write(Data((message+"\n").utf8)) }
        func tokens(_ m:Meeting) -> [String] { AudioSource.allCases.map { source in m.segments.filter { $0.source == source }.flatMap { $0.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }.joined(separator:" ") } }
        func counts(_ m:Meeting) -> String { "segments=\(m.segments.count), named=\(m.segments.filter { m.speakers[$0.speakerID ?? ""] != nil }.count), automatic=\((m.voiceMatches ?? []).filter { $0.state == .automatic }.count), suggested=\((m.voiceMatches ?? []).filter { $0.state == .suggested }.count)" }
        do {
            func analyze(_ value:Meeting) async throws -> Meeting {
                let value = try value.preparingVoiceAnalysis(learning:try? SpeakerAudit.load(from:input.deletingLastPathComponent().appendingPathComponent("speaker-analysis.json")))
                let separated = try await engine.diarize(meeting:value,audio:audio,model:diar,progress:log)
                return try await engine.recognize(meeting:separated,audio:audio,model:voice,hash:hash,profiles:profiles,progress:log)
            }
            let result = try await analyze(meeting)
            notes["first"] = counts(result)
            try JSONCoding.encoder().encode(result).write(to:output.appendingPathComponent("first-pass.json"),options:.atomic)
            checks["all transcript words retained"] = tokens(result) == tokens(meeting)
            checks["segment identifiers unique"] = Set(result.segments.map(\.id)).count == result.segments.count
            checks["matches reference existing segments"] = (result.voiceMatches ?? []).allSatisfy { match in result.segments.contains {$0.id == match.segmentID} }
            checks["manual identities retained"] = meeting.segments.filter { meeting.voiceProtectedSegments.contains($0.id) }.allSatisfy { old in result.segments.contains { $0.id == old.id && $0.speakerID == old.speakerID && $0.text == old.text } }
            checks["no implicit named assignments"] = result.segments.allSatisfy { segment in
                let old = meeting.segments.first { $0.id == segment.id }
                return result.speakers[segment.speakerID ?? ""] == nil || (old?.speakerID == segment.speakerID && meeting.voiceProtectedSegments.contains(segment.id)) || (result.voiceMatches ?? []).contains { $0.segmentID == segment.id && ($0.state == .automatic || $0.state == .confirmed) }
            }
            checks["uncertain identities carry icon state"] = (result.voiceMatches ?? []).filter {$0.state == .suggested}.allSatisfy { match in result.segments.first(where:{$0.id == match.segmentID}).map { result.attribution(for:$0).state == .uncertain } ?? false }
            var saved = try store.export(result)
            checks["save reopen roundtrip"] = try JSONCoding.encoder().encode(store.read(saved.id)) == JSONCoding.encoder().encode(saved)
            let rerun = try await analyze(saved)
            notes["rerun"] = counts(rerun)
            checks["rerun retains transcript words"] = tokens(rerun) == tokens(saved)
            checks["rerun retains manual corrections"] = saved.corrections.allSatisfy { correction in rerun.segments.contains {$0.id == correction.segmentID && $0.text == correction.text && $0.speakerID == correction.speakerID} }
            try JSONCoding.encoder().encode(rerun).write(to:output.appendingPathComponent("rerun.json"),options:.atomic)
            if let proposal = (saved.voiceMatches ?? []).first(where:{$0.state == .suggested}), let segment = saved.segments.first(where:{$0.id == proposal.segmentID}) {
                let other = saved.segments.filter {$0.id != segment.id}.map { "\($0.id):\($0.speakerID ?? "")" }
                let key = "manual-test-"+UUID().uuidString; saved.speakers[key] = proposal.name
                try saved.correctSegment(segment.id,text:segment.text,speakerID:key)
                checks["confirmation affects only selected passage"] = other == saved.segments.filter {$0.id != segment.id}.map { "\($0.id):\($0.speakerID ?? "")" }
                checks["confirmed proposal loses uncertainty"] = saved.attribution(for:saved.segments.first {$0.id == segment.id}!).state == .assigned
                let afterConfirmation = try await analyze(saved)
                checks["confirmation survives reanalysis"] = afterConfirmation.segments.contains {$0.id == segment.id && $0.speakerID == key}
            } else { notes["confirmation"] = "No native suggestions; covered by regression fixtures" }
            if includeAudit {
                // Cross-check local profiles on user-labelled speech, excluding enrollment audio.
                var holdout = meeting
                holdout.segments = []; holdout.speakers = [:]; holdout.voiceMatches = nil; holdout.review = nil
                var expected:[UUID:String] = [:], person = 0
                for name in Set(meeting.speakers.values).sorted() where profiles.contains(where: { $0.enabled && $0.name == name }) {
                    let training = profiles.flatMap(\.samples).map(\.clip).filter { $0.meetingID == meeting.id }
                    let pool = meeting.segments.filter { segment in
                        meeting.speakerName(for:segment) == name && segment.end-segment.start >= 3.2 && !training.contains { $0.source == segment.source && min($0.end,segment.end) > max($0.start,segment.start) }
                    }
                    guard !pool.isEmpty else { continue }; person += 1
                    for segment in pool.prefix(3) {
                        var candidate = segment; candidate.speakerID = "holdout-\(person)"
                        holdout.segments.append(candidate); expected[candidate.id] = name
                    }
                }
                if !holdout.segments.isEmpty {
                    let classified = try await engine.recognize(meeting:holdout,audio:audio,model:voice,hash:hash,profiles:profiles,progress:log)
                    let matches = classified.voiceMatches ?? []
                    let wrongAutomatic = matches.filter { $0.state == .automatic && expected[$0.segmentID] != $0.name }
                    checks["held-out labelled speech has no wrong automatic identity"] = wrongAutomatic.isEmpty
                    notes["holdout"] = "people=\(person), passages=\(holdout.segments.count), automatic=\(matches.filter { $0.state == .automatic }.count), correctProposals=\(matches.filter { $0.state == .suggested && expected[$0.segmentID] == $0.name }.count), conflictingProposals=\(matches.filter { $0.state == .suggested && expected[$0.segmentID] != $0.name }.count)"
                }
                log("TEST ricerca altre voci e apprendimento progressivo")
                let before = try JSONCoding.encoder().encode(saved)
                var audit = try await engine.auditSpeakers(meeting:saved,audio:audio,diarization:diar,voice:voice,voiceHash:hash,progress:log)
                checks["audit leaves transcript unchanged"] = try JSONCoding.encoder().encode(saved) == before && audit.isCurrent(for:saved)
                notes["auditGroups"] = String(audit.groups.count)
                if let group = audit.groups.first(where: { !audit.pending($0.id).isEmpty }), let piece = audit.pending(group.id).first(where: { $0.segment.end-$0.segment.start >= 3 }) ?? audit.pending(group.id).first {
                    // A simulated identity on the disposable copy; never a real enrollment.
                    try audit.apply(groupID:group.id,selected:[piece.id],name:"Persona di test locale",to:&saved)
                    let cache = output.appendingPathComponent("learning-cache.json")
                    let learned = try await engine.reevaluateSpeakers(meeting:saved,audit:audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache,profiles:[],progress:log)
                    checks["learning preserves explicit confirmation"] = learned.audit.manualEvidence[piece.id.uuidString] == "Persona di test locale"
                    let confirmedParents = Set((saved.voiceMatches ?? []).filter { $0.state == .confirmed }.map(\.segmentID))
                        .union(saved.corrections.filter { $0.previousSpeakerID != $0.speakerID }.map(\.segmentID))
                    let trusted = Set(audit.manualEvidence.keys).union(audit.pieces.filter { confirmedParents.contains($0.originalID) || confirmedParents.contains($0.id) }.map { $0.id.uuidString })
                    checks["learning does not turn predictions into references"] = Set(learned.audit.manualEvidence.keys).isSubset(of:trusted)
                    let repeated = try await engine.reevaluateSpeakers(meeting:learned.meeting,audit:learned.audit,audio:audio,voice:voice,voiceHash:hash,cacheURL:cache,profiles:[],progress:log)
                    checks["repeated learning reuses all cached embeddings"] = repeated.computedEmbeddings == 0
                    checks["repeated learning does not grow verification queue"] = repeated.unresolvedCount <= learned.unresolvedCount
                    notes["learning"] = "references=\(learned.referenceCount), auto=\(learned.automaticCount), unresolved=\(learned.unresolvedCount), cacheHits=\(repeated.cacheHits)"
                    try repeated.audit.save(to:output.appendingPathComponent("audit-after-learning.json"))
                    try JSONCoding.encoder().encode(repeated.meeting).write(to:output.appendingPathComponent("meeting-after-learning.json"),options:.atomic)
                } else { notes["learning"] = "No usable audit groups" }
            }
            try saved.changeTitle(saved.title+" · test")
            saved = try store.export(saved)
            checks["renamed title survives reopen"] = try store.read(saved.id).title == saved.title
        } catch {
            notes["analysisError"] = error.localizedDescription
            checks["missing audio fails explicitly without changing stored transcript"] = missing > 0 && (try? JSONCoding.encoder().encode(store.read(meeting.id))) == (try? JSONCoding.encoder().encode(meeting))
            if missing == 0 { checks["native analysis completed"] = false }
        }
        checks["original manifest unchanged"] = try Data(contentsOf:input) == original
        notes["missingFiles"] = String(missing); notes["elapsedSeconds"] = String(Int(Date().timeIntervalSince(started)))
        let report:[String:Any] = ["checks":checks,"notes":notes,"input":input.path]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("checks.json"),options:.atomic)
        print("TEST \(meeting.id): \(checks.count) checks; \(checks.values.filter { !$0 }.count) failures. \(notes)")
        if checks.values.contains(false) { throw VerbaleError.message("Il test ha rilevato problemi: consulta checks.json.") }
    }
}
