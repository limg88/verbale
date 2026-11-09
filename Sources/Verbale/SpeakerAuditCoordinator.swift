import Foundation
import VerbaleCore

extension AppModel {
    func speakerAuditURL(_ meeting: Meeting) -> URL { store.workspace(meeting.id).appendingPathComponent("speaker-analysis.json") }
    func loadSpeakerAudit(_ meeting: Meeting) -> SpeakerAudit? {
        guard let audit = try? SpeakerAudit.load(from: speakerAuditURL(meeting)), audit.isCurrent(for:meeting) else { return nil }
        return audit
    }
    func discardStaleSpeakerAudit(for meeting:Meeting) {
        if let audit = speakerAudit, !audit.isCurrent(for:meeting) {
            speakerAudit = nil; learningSummary = ""; auditReviewVisible = false
        }
    }
    func startSpeakerAudit() {
        guard !sessionLocked, let meeting = current else { return }
        busy = true; voiceBusy = true; voiceProgress = "Preparazione della ricerca di altre voci…"; error = nil
        voiceTask = Task {
            defer { busy = false; voiceBusy = false; voiceProgress = ""; voiceTask = nil }
            do {
                stopVoicePlayback(); await engine.unload()
                let diar = try await models.verified("diarization"), voice = try await models.verified("voice")
                let hash = models.catalog.first { $0.id == "voice" }!.sha256
                let result = try await voiceEngine.auditSpeakers(meeting: meeting, audio: voiceAudio(meeting), diarization: diar, voice: voice, voiceHash: hash, progress: { [weak self] message in
                    Task { @MainActor in if self?.voiceBusy == true { self?.voiceProgress = message } }
                })
                try Task.checkCancellation()
                guard let latest = current, result.isCurrent(for: latest) else { throw VerbaleError.message("I contenuti sono cambiati durante l’analisi: ripeti la ricerca.") }
                try result.save(to: speakerAuditURL(meeting))
                speakerAudit = result
                status = "Revisione rapida pronta · \(SpeakerAuditTriage(audit: result, meeting: latest).remainingPeopleCount) controlli mirati · trascrizione invariata"
                // Release the operation lock before presenting the review sheet.
                busy = false; voiceBusy = false; auditReviewVisible = true
            } catch {
                if error is CancellationError { status = "Ricerca annullata · trascrizione e nomi conservati" }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func showSpeakerAudit() {
        guard !sessionLocked, let meeting = current else { return }
        if speakerAudit?.isCurrent(for:meeting) != true { speakerAudit = loadSpeakerAudit(meeting) }
        guard speakerAudit != nil else { return }
        auditReviewVisible = true
    }
    func dismissSpeakerAuditCase(_ groupID: UUID) {
        guard let meeting = current, var audit = speakerAudit, audit.isCurrent(for: meeting), audit.groups.contains(where: { $0.id == groupID }) else { return }
        if let item = SpeakerAuditTriage(audit: audit, meeting: meeting).cases.first(where: { $0.groupID == groupID }) {
            var buckets = audit.reviewedBuckets ?? []; buckets.insert(item.bucket); audit.reviewedBuckets = buckets
        }
        var reviewed = audit.reviewedGroups ?? []; reviewed.insert(groupID); audit.reviewedGroups = reviewed
        do { try audit.save(to: speakerAuditURL(meeting)); speakerAudit = audit; stopVoicePlayback() }
        catch { self.error = error.localizedDescription }
    }
    func resetSpeakerAuditDeferrals() {
        guard let meeting = current, var audit = speakerAudit, audit.isCurrent(for: meeting) else { return }
        audit.reviewedBuckets = []; audit.reviewedGroups = []
        do { try audit.save(to: speakerAuditURL(meeting)); speakerAudit = audit }
        catch { self.error = error.localizedDescription }
    }
    func applySpeakerAudit(groupID: UUID, selected: Set<UUID>, name: String) -> Bool {
        guard !isRecording, !busy, !working, !reportBusy, var meeting = current, var audit = speakerAudit else { return false }
        do {
            try audit.apply(groupID: groupID, selected: selected, name: name, to: &meeting)
            guard saveReview(meeting) else { return false }
            speakerAudit = audit
            do { try audit.save(to: speakerAuditURL(meeting)) }
            catch { self.error = "I nomi sono salvati, ma non è stato possibile aggiornare le proposte: " + error.localizedDescription }
            status = "\(selected.count) passaggi assegnati a \(name) · rivalutazione degli altri interventi"
            startSpeakerLearning()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
