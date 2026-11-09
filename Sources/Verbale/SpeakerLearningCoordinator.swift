import Foundation
import VerbaleCore

extension AppModel {
    func startSpeakerLearning() {
        guard !isRecording, !busy, !working, !reportBusy, let meeting = current, let audit = speakerAudit, audit.isCurrent(for:meeting) else { return }
        if Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil && CommandLine.arguments.contains("--check-background-ui") { return }
        guard installed.contains("voice") else { learningSummary = "Nome salvato · prepara il modello Profili vocali per rivalutare gli altri passaggi."; return }
        busy = true; voiceBusy = true; learningBusy = true; voiceProgress = "Rivalutazione con i passaggi confermati…"; stopVoicePlayback()
        let profiles = voiceProfiles
        voiceTask = Task {
            defer { busy = false; voiceBusy = false; learningBusy = false; voiceProgress = ""; voiceTask = nil }
            do {
                await engine.unload()
                let model = try await models.verified("voice"), hash = models.catalog.first { $0.id == "voice" }!.sha256
                let result = try await voiceEngine.reevaluateSpeakers(meeting:meeting,audit:audit,audio:voiceAudio(meeting),voice:model,voiceHash:hash,cacheURL:store.workspace(meeting.id).appendingPathComponent("speaker-learning-cache.json"),profiles:profiles,progress: { [weak self] message in
                    Task { @MainActor in if self?.learningBusy == true { self?.voiceProgress = message } }
                })
                try Task.checkCancellation()
                guard let latest = current, try SpeakerAudit.fingerprint(latest) == SpeakerAudit.fingerprint(meeting) else { throw VerbaleError.message("I contenuti sono cambiati: ripeti la rivalutazione.") }
                guard saveReview(result.meeting) else { return }
                speakerAudit = result.audit
                try result.audit.save(to:speakerAuditURL(result.meeting))
                learningSummary = result.referenceCount == 0 ? "Conferme salvate. Servono almeno 3 secondi complessivi di audio utilizzabile per la stessa persona per riconoscere altri interventi." : "\(result.automaticCount) passaggi assegnati automaticamente · \(result.unresolvedCount) ancora incerti · \(result.referenceCount) campioni confermati"
                status = learningSummary
            } catch {
                if error is CancellationError { learningSummary = "Rivalutazione annullata · le tue conferme sono salvate." }
                else { self.error = "Le tue conferme sono salvate. Rivalutazione non completata: " + error.localizedDescription }
            }
        }
    }
    func confirmLearningAssignment(_ segmentID: UUID) {
        guard !sessionLocked, current != nil, let audit = speakerAudit, let assignment = audit.automaticAssignments?[segmentID.uuidString], let group = audit.pieces.first(where: { $0.id == segmentID })?.groupID else { return }
        _ = applySpeakerAudit(groupID:group,selected:[segmentID],name:assignment.name)
    }
    /// A direct per-passage speaker correction is explicit evidence too; a global cluster rename is not.
    func learnFromSegmentCorrection(_ segmentID: UUID, previous: Meeting, updated: Meeting, speakerConfirmed: Bool) {
        guard var audit = speakerAudit, audit.isCurrent(for:previous), let segment = updated.segments.first(where: { $0.id == segmentID }) else { return }
        do {
            try audit.rebaseTextCorrection(segmentID:segmentID,previous:previous,updated:updated)
            if !speakerConfirmed { try audit.save(to:speakerAuditURL(updated)); speakerAudit = audit; return }
            if segment.speakerID != nil { try audit.noteManualAssignment(segmentID:segmentID,name:updated.speakerName(for:segment),meeting:updated) }
            else {
                let children = audit.pieces.filter { $0.originalID == segmentID }.map(\.id)
                let ids = !audit.materializedParents.contains(segmentID) && !children.isEmpty ? children : [segmentID]
                for id in ids { audit.confirmedAssignments?.removeValue(forKey:id.uuidString); audit.automaticAssignments?.removeValue(forKey:id.uuidString); audit.applied.remove(id) }
                audit.inputFingerprint = try SpeakerAudit.fingerprint(updated)
            }
            try audit.save(to:speakerAuditURL(updated)); speakerAudit = audit
            startSpeakerLearning()
        } catch { self.error = "Correzione salvata, riferimento vocale non aggiornato: " + error.localizedDescription }
    }
}
