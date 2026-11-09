import Foundation
import VerbaleCore

extension AppModel {
    func refinementURL(_ meeting:Meeting) -> URL { store.workspace(meeting.id).appendingPathComponent("transcription-refinement.json") }
    func loadRefinement(_ meeting:Meeting) -> TranscriptRefinement? {
        guard let draft = try? TranscriptRefinement.load(from:refinementURL(meeting)),draft.isCurrent(for:meeting) else { return nil };return draft
    }
    func showRefinement(_ segmentID:UUID? = nil) {
        guard !sessionLocked,let meeting = current else { return }
        error = nil; refinementSelection = segmentID.map { [$0] };refinementDraft = segmentID == nil ? loadRefinement(meeting):nil;refinementVisible = true
    }
    func prepareRefinement(scope:RefinementScope) {
        guard !isRecording,!busy,!working,!reportBusy,let meeting = current else { return }
        let selected = refinementSelection
        busy = true;refinementBusy = true;refinementProgress = "Preparazione del riascolto…";error = nil;stopVoicePlayback()
        refinementTask = Task {
            defer { busy = false;refinementBusy = false;refinementProgress = "";refinementTask = nil }
            do {
                await engine.unload()
                let asr = try await models.verified("asr"),vad = try await models.verified("vad")
                try Task.checkCancellation()
                try await engine.load(asr:asr,vad:vad)
                var draft = try await engine.refine(meeting:meeting,audio:voiceAudio(meeting),scope:scope,selected:selected,progress: { [weak self] message in
                    Task { @MainActor in if self?.refinementBusy == true { self?.refinementProgress = message } }
                })
                await engine.unload();try Task.checkCancellation()
                guard let current, draft.isCurrent(for:current) else { throw VerbaleError.message("La trascrizione è cambiata: ripeti il riascolto.") }
                if let audit = speakerAudit,audit.isCurrent(for:current) { draft.originalSpeakerAnalysis = audit }
                if let previous = try? TranscriptRefinement.load(from:refinementURL(current)),previous.original.id == current.id,!previous.applied.isEmpty {
                    let archive = store.workspace(current.id).appendingPathComponent("transcription-revisions")
                    try FileManager.default.createDirectory(at:archive,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    try previous.save(to:archive.appendingPathComponent(previous.id.uuidString+".json"))
                }
                try draft.save(to:refinementURL(current));refinementDraft = draft
            } catch {
                await engine.unload()
                if error is CancellationError { status = "Riascolto annullato · trascrizione conservata" }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func cancelRefinement() { refinementTask?.cancel() }
    func applyRefinement(_ selected:Set<UUID>,undo:Bool = false) async -> Bool {
        guard !busy,!isRecording,!working,!reportBusy,var meeting = current,var draft = refinementDraft else { return false }
        do {
            error = nil;stopVoicePlayback()
            let before = meeting
            if undo { try draft.undo(in:&meeting) } else { try draft.apply(selected,to:&meeting) }
            var analysis:SpeakerAudit?
            if undo {
                if let original = draft.originalSpeakerAnalysis,original.isCurrent(for:meeting) { analysis = original }
            } else if var currentAudit = speakerAudit,currentAudit.isCurrent(for:before) {
                try currentAudit.rebaseTranscriptChanges(previous:before,updated:meeting);analysis = currentAudit
            }
            busy = true;defer { busy = false }
            let root = store.root,updated = meeting,updatedDraft = draft,url = refinementURL(meeting),updatedAnalysis = analysis
            let saved = try await Task.detached {
                let disk = try SessionStore(root:root)
                // Persist the original and the intended revision before changing the transcript.
                try updatedDraft.save(to:url)
                if let updatedAnalysis { try updatedAnalysis.save(to:disk.workspace(updated.id).appendingPathComponent("speaker-analysis.json")) }
                try disk.save(updated)
                var result = updated,issue:String?
                do { result = try disk.export(updated) } catch { issue = error.localizedDescription }
                return (result,try disk.list(),issue)
            }.value
            current = saved.0;meetings = saved.1;exportError = saved.2;refinementDraft = draft
            speakerAudit = updatedAnalysis
            status = undo ? "Trascrizione precedente ripristinata":"Proposte applicate · nomi e collegamenti conservati"
            return true
        } catch { self.error = error.localizedDescription;return false }
    }
}
