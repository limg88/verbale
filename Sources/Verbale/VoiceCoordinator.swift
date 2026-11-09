import Foundation
import AppKit
import AVFoundation
import VerbaleCore

struct VoiceEnrollmentRequest: Identifiable {
    let id = UUID()
    let meeting: Meeting
    let segment: Segment
    let clips: [VoiceClip]
    let initialName: String
    var speakerGroupID: String? = nil
}

extension AppModel {
    func voiceAudio(_ meeting: Meeting) -> VoiceAudio {
        VoiceAudio(workspace: store.workspace(meeting.id), exported: URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName))
    }
    var voiceModelsReady: Bool { installed.isSuperset(of: ["voice", "diarization"]) }
    func beginVoiceEnrollment(_ segment: Segment, speakerGroupID: String? = nil) {
        guard !sessionLocked, let meeting = current else { return }
        guard voiceStore != nil else { error = "L’archivio dei profili vocali non è disponibile."; return }
        guard installed.contains("voice") else { tab = "models"; error = "Scarica il modello opzionale Profili vocali, poi torna al passaggio da ricordare."; return }
        let group = speakerGroupID.flatMap { key in meeting.speakerGroups.first { $0.speakerIDs.contains(key) } }
        let clips: [VoiceClip]
        if let group {
            let ids = Set(meeting.segments.filter { $0.speakerID.map(group.speakerIDs.contains) == true }.map(\.id))
            clips = Array(meeting.sources.flatMap { source in
                VoiceClips.candidates(meeting:meeting,speakerID:nil,source:source,selected:segment.id,segmentIDs:ids)
            }.prefix(16))
        } else { clips = VoiceClips.candidates(meeting: meeting, speakerID: segment.speakerID, source: segment.source, selected: segment.id) }
        guard clips.count >= 2 else { error = "Servono almeno due campioni distinti di almeno 3 secondi. Separa prima gli interlocutori o scegli un passaggio più lungo."; return }
        voiceEnrollment = VoiceEnrollmentRequest(meeting: meeting, segment: segment, clips: clips, initialName: segment.speakerID.flatMap { meeting.speakers[$0] } ?? "", speakerGroupID:speakerGroupID)
        error = nil
        voiceClipQualities = [:]; voiceQualityTask?.cancel()
        guard let request = voiceEnrollment else { return }
        let audio = voiceAudio(meeting)
        voiceQualityTask = Task {
            do {
                let qualities = try await voiceEngine.quality(clips: clips, meeting: meeting, audio: audio)
                guard !Task.isCancelled, voiceEnrollment?.id == request.id else { return }
                voiceClipQualities = qualities
            } catch { /* Closing the sheet cancels only this optional signal assessment. */ }
        }
    }
    func cancelVoiceQuality() { voiceQualityTask?.cancel(); voiceQualityTask = nil }
    func listenVoice(_ clip: VoiceClip, meeting: Meeting) async -> Bool {
        guard let requestID = voiceEnrollment?.id else { return false }
        return await playVoiceClip(clip, meeting: meeting) { self.voiceEnrollment?.id == requestID }
    }
    func listenRefinement(_ clip:VoiceClip) async -> Bool {
        guard let meeting = current,refinementVisible else { return false }
        return await playVoiceClip(clip,meeting:meeting,minimumDuration:0.1) { self.refinementVisible && self.current?.id == meeting.id }
    }
    func listenAudit(_ clip: VoiceClip) async -> Bool {
        guard let meeting = current, let audit = speakerAudit, auditReviewVisible else { return false }
        return await playVoiceClip(clip, meeting: meeting) { self.auditReviewVisible && self.speakerAudit?.id == audit.id }
    }
    private func playVoiceClip(_ clip: VoiceClip, meeting: Meeting, minimumDuration:Double = 3, stillValid: () -> Bool) async -> Bool {
        guard !isRecording, !busy, stillValid() else { return false }
        let playbackID = UUID(); voicePlaybackID = playbackID
        do {
            voicePlayer?.stop()
            let audio = voiceAudio(meeting)
            let data = try await Task.detached { VoiceAudio.wave(try audio.samples(clip, meeting: meeting,minimumDuration:minimumDuration)) }.value
            guard !isRecording, !busy, stillValid(), voicePlaybackID == playbackID else { return false }
            voicePlayer = try AVAudioPlayer(data: data)
            voicePlayer?.prepareToPlay()
            guard voicePlayer?.play() == true else { throw VerbaleError.message("Impossibile ascoltare il campione.") }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func stopVoicePlayback() { voicePlaybackID = UUID(); voicePlayer?.stop(); voicePlayer = nil }
    func saveVoiceEnrollment(_ request: VoiceEnrollmentRequest, name: String, existing: UUID?, selected: Set<UUID>, enableAutomatic: Bool) {
        guard !isRecording, !busy, !reportBusy, !working, current?.id == request.meeting.id else { return }
        let clips = request.clips.filter { selected.contains($0.id) }
        guard (2...6).contains(clips.count) else { error = "Seleziona da due a sei campioni."; return }
        error = nil; stopVoicePlayback(); busy = true; voiceBusy = true; voiceProgress = "Creazione del profilo vocale…"
        voiceTask = Task {
            defer { busy = false; voiceBusy = false; voiceProgress = ""; voiceTask = nil }
            do {
                guard let voiceStore else { throw VerbaleError.message("Archivio profili non disponibile.") }
                await engine.unload()
                let model = try await models.verified("voice"), hash = models.catalog.first { $0.id == "voice" }!.sha256
                let (encoder, samples) = try await voiceEngine.enroll(clips: clips, meeting: request.meeting, audio: voiceAudio(request.meeting), model: model, hash: hash)
                try Task.checkCancellation()
                let profile = try voiceStore.enroll(name: name, samples: samples, encoder: encoder, existing: existing)
                voiceProfiles = voiceStore.profiles
                automaticVoices = enableAutomatic
                voiceEnrollment = nil
                let assigned = applyVoiceProfileName(profile, meetingID: request.meeting.id, segmentID: request.segment.id,speakerGroupID:request.speakerGroupID)
                status = "Profilo di \(profile.name) salvato · \(profile.samples.count) campioni" + (assigned ? " · nome assegnato nella trascrizione" : " · assegnazione del nome da riprovare")
                if profile.needsMatchConfirmation { status += " · campioni variabili: riconoscimenti da confermare" }
                if enableAutomatic && !voiceModelsReady { status += " · prepara anche il modello Interlocutori" }
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
    @discardableResult func applyVoiceProfileName(_ profile: VoiceProfile, meetingID: UUID, segmentID: UUID, speakerGroupID: String? = nil) -> Bool {
        guard var meeting = current, meeting.id == meetingID else { return false }
        do {
            if let speakerGroupID { try meeting.renameSpeakerPerson(speakerGroupID,to:profile.name) }
            else { try meeting.assignVoiceName(profile.name, to: segmentID) }
            guard saveReview(meeting) else { return false }
            discardStaleSpeakerAudit(for:meeting)
            return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    func assignSavedVoice(_ profileID: UUID, segmentID: UUID, speakerGroupID: String? = nil) {
        guard !sessionLocked, let meeting = current, let profile = voiceProfiles.first(where: { $0.id == profileID }) else { return }
        if applyVoiceProfileName(profile, meetingID: meeting.id, segmentID: segmentID,speakerGroupID:speakerGroupID) { status = "Nome di \(profile.name) assegnato nella trascrizione" }
    }
    func cancelVoiceAnalysis() { voiceTask?.cancel() }
    func startSpeakerSeparation() {
        guard !sessionLocked else { return }
        busy = true
        voiceTask = Task { await analyzeVoices(recognize: false); busy = false; voiceTask = nil }
    }
    func startVoiceRecognition() {
        guard !sessionLocked else { return }
        busy = true
        voiceTask = Task { await analyzeVoices(recognize: true); busy = false; voiceTask = nil }
    }
    func runAutomaticVoices() async {
        guard automaticVoices, voiceProfiles.contains(where: \.enabled) else { return }
        guard voiceModelsReady else {
            if var meeting = current {
                let warning = "Riconoscimento voci saltato: prepara i modelli opzionali Interlocutori e Profili vocali."
                if !meeting.warnings.contains(warning) { meeting.warnings.append(warning); current = meeting }
            }
            return
        }
        voiceTask = Task { await analyzeVoices(recognize: true, automatic: true) }
        await voiceTask?.value; voiceTask = nil
    }
    func analyzeVoices(recognize: Bool, automatic: Bool = false) async {
        guard let meeting = current else { return }
        voiceBusy = true; voiceProgress = "Preparazione dell’analisi vocale…"
        defer { voiceBusy = false; voiceProgress = "" }
        do {
            if recognize && !voiceProfiles.contains(where: \.enabled) { throw VerbaleError.message("Crea prima un profilo da «Ricorda questa voce» nella trascrizione.") }
            stopVoicePlayback(); await engine.unload()
            let diarization = try await models.verified("diarization")
            let audio = voiceAudio(meeting)
            let progress: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in if self?.voiceBusy == true { self?.voiceProgress = message } }
            }
            let input = try meeting.preparingVoiceAnalysis(learning:try? SpeakerAudit.load(from:speakerAuditURL(meeting)))
            var analyzed = try await voiceEngine.diarize(meeting: input, audio: audio, model: diarization, progress: progress)
            analyzed.modelDigests["diarization"] = models.catalog.first { $0.id == "diarization" }?.sha256
            if recognize {
                let voice = try await models.verified("voice"), hash = models.catalog.first { $0.id == "voice" }!.sha256
                analyzed = try await voiceEngine.recognize(meeting: analyzed, audio: audio, model: voice, hash: hash, profiles: voiceProfiles, progress: progress)
                analyzed.modelDigests["voice"] = hash
            }
            try Task.checkCancellation()
            guard current?.id == meeting.id else { return }
            guard saveReview(analyzed) else { return }
            discardStaleSpeakerAudit(for:analyzed)
            let automaticCount = Set((analyzed.voiceMatches ?? []).filter { $0.state == .automatic }.map(\.profileID)).count
            let suggestions = Set((analyzed.voiceMatches ?? []).filter { $0.state == .suggested }.map(\.profileID)).count
            status = recognize ? "Voci analizzate · \(automaticCount) profili riconosciuti · \(suggestions) proposte da verificare" : "Interlocutori separati · i passaggi corretti sono stati conservati"
        } catch {
            if automatic {
                if var latest = current, latest.id == meeting.id {
                    latest.warnings.append(error is CancellationError ? "Riconoscimento voci annullato: trascrizione conservata." : "Riconoscimento voci non completato: " + error.localizedDescription)
                    current = latest
                }
            } else if !(error is CancellationError) { self.error = error.localizedDescription }
            else { status = "Analisi vocale annullata · trascrizione conservata" }
        }
    }
    func confirmVoice(_ id: UUID) { guard !voiceDecisionLocked, var meeting = current else { return }; meeting.confirmVoice(id); persistVoiceDecision(meeting) }
    func rejectVoice(_ id: UUID) { guard !voiceDecisionLocked, var meeting = current else { return }; meeting.rejectVoice(id); persistVoiceDecision(meeting) }
    func updateVoiceProfile(_ id: UUID, name: String? = nil, enabled: Bool? = nil, remove: Bool = false) {
        guard !sessionLocked, let voiceStore else { return }
        do {
            if remove {
                let alert = NSAlert(); alert.messageText = "Eliminare questo profilo vocale?"
                alert.informativeText = "Verranno rimossi tutti i campioni del profilo. I nomi già assegnati alle riunioni rimangono."
                alert.addButton(withTitle: "Elimina"); alert.addButton(withTitle: "Annulla")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try voiceStore.remove(id)
            } else if let name { try voiceStore.rename(id, name: name) }
            else if let enabled { try voiceStore.setEnabled(id, enabled) }
            voiceProfiles = voiceStore.profiles
        } catch { self.error = error.localizedDescription }
    }
}
