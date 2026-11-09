import SwiftUI
import VerbaleCore

struct MarkerMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(MarkerKind.allCases) { kind in
                Button { model.addMarker(kind) } label: { Label(kind.label, systemImage: kind.icon) }
            }
        } label: { Label("Segna momento", systemImage: "flag") }
            .disabled(!model.isRecording || model.busy)
            .help("Segna un punto importante, una decisione o un’azione al tempo corrente")
    }
}

private final class TranscriptReviewState: ObservableObject {
    @Published var editing: Segment?
    @Published var assigningProfile: Segment?
    @Published var followLive = true
    private var key:String?
    private var index:TranscriptIndex?
    func presentation(_ meeting:Meeting)->TranscriptIndex {
        let revision="\(meeting.id):\(meeting.reportInputRevision?.uuidString ?? "legacy"):\(meeting.segments.count):\(meeting.voiceMatches?.count ?? 0)"
        if key != revision || index == nil {index=TranscriptIndex(meeting);key=revision}
        return index!
    }
}

struct TranscriptReviewView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @StateObject private var state = TranscriptReviewState()
    private var queuedTitle:String? {
        guard let job=model.work(meeting.id,kind:.transcription),job.state.pending else{return nil}
        switch job.state { case .running:return "Trascrizione in corso…";case .waitingForTeams:return "Attesa fine chiamata Teams";default:return "Trascrizione in coda" }
    }
    var body: some View {
        let presentation=state.presentation(meeting)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trascrizione").font(.headline)
                Spacer()
                if !model.viewingRecording && !meeting.segments.isEmpty {
                    Button("Riascolta e confronta…") { model.showRefinement() }.disabled(model.sessionLocked || (!meeting.keepAudio && !meeting.keepRecovery)).help("Prepara proposte con più contesto, senza cambiare la trascrizione")
                }
                if model.viewingRecording && !(model.viewingRecording && model.transcriptionDeferred) { Toggle("Segui il parlato", isOn: $state.followLive).toggleStyle(.checkbox).font(.callout) }
                if model.savingVoiceMeetings.contains(meeting.id) { ProgressView().controlSize(.small).help("Salvataggio delle conferme vocali…") }
                Label(model.viewingRecording && !meeting.chunks.isEmpty ? "Audio salvato sul Mac" : meeting.exported ? "Salvata" : "Da salvare", systemImage: (model.viewingRecording && !meeting.chunks.isEmpty) || meeting.exported ? "checkmark.circle" : "clock").font(.caption).foregroundStyle(.secondary)
            }
            if !model.viewingRecording {
                ForEach(RecordingReadiness.missingSourceWarnings(meeting.sources,chunks:meeting.chunks,segments:meeting.segments),id:\.self) { warning in
                    Label(warning,systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
            }
            if let job=model.work(meeting.id,kind:.transcription),job.state.pending {
                HStack {
                    Label(job.progress,systemImage:job.state == .running ? "waveform":"clock").font(.callout)
                    Spacer();Button("Sospendi") { model.cancelWork(job.id) }
                }
            } else if model.waitingTranscriptionID == meeting.id {
                HStack(alignment:.top,spacing:12) {
                    Label(model.waitingTranscriptionMessage,systemImage:"clock").font(.callout).frame(maxWidth:.infinity,alignment:.leading)
                    Button("Annulla attesa") { model.cancelWaitingTranscription() }
                }.padding(12).background(Palette.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
            } else if meeting.state == .failed || meeting.state == .interrupted || model.work(meeting.id,kind:.transcription).map({[.failed,.cancelled].contains($0.state)}) == true {
                Button("Riprendi trascrizione") { Task { await model.resume() } }.disabled(model.navigationLocked || model.work(meeting.id,kind:.report)?.state.pending == true)
            }
            if let job=model.work(meeting.id,kind:.transcription),job.state == .failed { Text(job.error ?? "Trascrizione interrotta").font(.callout).foregroundStyle(.orange) }
            if meeting.segments.isEmpty {
                ContentUnavailableView(queuedTitle ?? (model.waitingTranscriptionID == meeting.id ? "Attesa fine chiamata Teams" : (model.viewingRecording && model.transcriptionDeferred) ? "Audio in registrazione" : model.viewingRecording ? "In ascolto…" : meeting.state == .processing ? "Trascrizione in corso…" : "Trascrizione in attesa"), systemImage: "waveform", description: Text(queuedTitle != nil ? "Puoi consultare le altre riunioni. I risultati compariranno qui al termine dell’elaborazione." : model.waitingTranscriptionID == meeting.id ? "L’audio è salvato. La trascrizione ripartirà automaticamente quando Teams non segnalerà più la chiamata." : (model.viewingRecording && model.transcriptionDeferred) ? "La trascrizione inizierà al termine della registrazione, per ridurre i consumi durante la call." : model.viewingRecording ? "Il testo comparirà dopo i primi secondi di parlato." : meeting.state == .interrupted || meeting.state == .failed ? "L’audio è salvato. Dopo la call premi Riprendi trascrizione." : meeting.state == .processing ? "Sto elaborando l’audio salvato sul Mac." : "Nessun testo disponibile."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(presentation.segments) { segment in
                                HStack(alignment: .top, spacing: 16) {
                                    Text(timecode(segment.start)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 3).frame(width: 68, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 6) {
                                        let attribution = meeting.attribution(for:segment,match:presentation.matches[segment.id],learned:model.speakerAudit?.automaticAssignments?[segment.id.uuidString])
                                        HStack(spacing:6) {
                                            Button { if let id = segment.speakerID { model.focusSpeaker(id) } } label: {
                                                Text(attribution.name).font(.system(size:12,weight:.semibold)).foregroundStyle(Palette.accent)
                                            }.buttonStyle(.plain).disabled(segment.speakerID == nil).help("Vai alla prima occorrenza di questo interlocutore")
                                            if attribution.state == .uncertain || attribution.state == .unidentified {
                                                Menu {
                                                    if attribution.state == .uncertain {
                                                        Button("Conferma \(attribution.name) per questo passaggio") {
                                                            _ = model.correctSegment(meetingID:meeting.id,segmentID:segment.id,text:segment.text,speakerID:segment.speakerID,newSpeaker:attribution.name)
                                                        }
                                                    }
                                                    Button("Assegna o correggi nome…") { state.editing = segment }
                                                } label: { Image(systemName:"questionmark.circle.fill").foregroundStyle(.orange) }
                                                .menuStyle(.borderlessButton).fixedSize().disabled(model.sessionLocked).help(attribution.detail).accessibilityLabel("Identità da verificare: \(attribution.name)")
                                            } else if attribution.state == .recognized {
                                                Image(systemName:"checkmark.circle").foregroundStyle(.secondary).help(attribution.detail).accessibilityLabel("Voce riconosciuta")
                                            }
                                        }
                                        Text(segment.text).font(.system(size: 14)).textSelection(.enabled).lineSpacing(5)
                                        if presentation.corrected.contains(segment.id) { Text("Corretto").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                    Menu {
                                        if let assignment = model.speakerAudit?.automaticAssignments?[segment.id.uuidString] {
                                            Button("Conferma \(assignment.name)") { model.confirmLearningAssignment(segment.id) }
                                        }
                                        Button("Ritrascrivi questo passaggio…") { model.showRefinement(segment.id) }.disabled(!meeting.keepAudio && !meeting.keepRecovery)
                                        Button("Ricorda questa voce…") { model.beginVoiceEnrollment(segment) }
                                        if !model.voiceProfiles.isEmpty {
                                            Button("Assegna nome da profilo…") { state.assigningProfile = segment }
                                        }
                                    } label: { Image(systemName: "person.crop.circle.badge.plus") }
                                        .menuStyle(.borderlessButton).fixedSize().disabled(model.sessionLocked).help("Crea un profilo vocale dai passaggi registrati")
                                    Button { state.editing = segment } label: { Image(systemName: "pencil") }
                                        .buttonStyle(.plain).disabled(model.sessionLocked).help("Correggi testo o interlocutore")
                                        .accessibilityLabel("Correggi segmento a \(timecode(segment.start))")
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.focusedSegmentID == segment.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .id(segment.id)
                            }
                        }.padding(10)
                    }.background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .task(id: model.focusedSegmentID) { if let id = model.focusedSegmentID { proxy.scrollTo(id, anchor: .center) } }
                        .onChange(of: model.focusRequestID) { _, _ in if let id = model.focusedSegmentID { proxy.scrollTo(id,anchor:.top) } }
                        .onChange(of:meeting.id) { _,_ in
                            if model.viewingRecording && state.followLive,let last=meeting.segments.max(by:{$0.start<$1.start}) {proxy.scrollTo(last.id,anchor:.bottom)}
                        }
                        .onChange(of: meeting.segments.count, initial: true) { _, _ in
                            if model.viewingRecording && state.followLive, let last = meeting.segments.max(by: { $0.start < $1.start }) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                }
            }
            if !model.viewingRecording && !meeting.segments.isEmpty {
                VoiceSuggestionsView(meeting: meeting)
                DisclosureGroup("Interlocutori", isExpanded: $model.speakersExpanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("1 · Analisi iniziale").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Separa soltanto") { model.startSpeakerSeparation() }.disabled(model.sessionLocked || !model.installed.contains("diarization") || (!meeting.keepAudio && !meeting.keepRecovery))
                                Button("Separa e riconosci voci salvate") { model.startVoiceRecognition() }.disabled(model.sessionLocked || !model.voiceModelsReady || !model.voiceProfiles.contains(where: \.enabled) || (!meeting.keepAudio && !meeting.keepRecovery))
                                Spacer()
                                Button("Gestisci profili…") { model.tab = "settings"; model.settingsSection = "voices" }
                            }
                            Text("«Separa e riconosci» include già la separazione: non serve eseguirla prima.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text("2 · Facoltativo").font(.caption).foregroundStyle(.secondary)
                                Button("Cerca altre voci…") { model.startSpeakerAudit() }.disabled(model.sessionLocked || !model.voiceModelsReady || (!meeting.keepAudio && !meeting.keepRecovery))
                                if model.speakerAudit?.meetingID == meeting.id { Button("Rivedi proposte…") { model.showSpeakerAudit() }.disabled(model.sessionLocked) }
                            }
                            if !model.installed.contains("diarization") { Button("Prepara il modello per gli interlocutori…") { model.tab = "models" }.font(.callout) }
                            ForEach(meeting.speakerGroups) { person in
                                SpeakerNameRow(meetingID:meeting.id,speakerID:person.representativeID,name:person.name)
                            }
                            Text("La separazione distingue fino a 8 voci. «Cerca altre voci» prepara proposte locali da rivedere, senza cambiare i nomi. Le correzioni manuali vengono conservate.").font(.caption).foregroundStyle(.secondary)
                            Text("Dal menu di ogni interlocutore puoi ricordare la voce o assegnare un nome da profilo. Verifica sempre i campioni audio.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).padding(.trailing, 6)
                    }.frame(height: min(200, CGFloat(100 + meeting.speakerGroups.count * 32)))
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(item:$state.assigningProfile) { segment in VoiceProfileAssignmentView(meetingID:meeting.id,segmentID:segment.id).environmentObject(model) }
            .sheet(item: $state.editing) { segment in SegmentEditor(meeting: meeting, segment: segment).environmentObject(model) }
    }
}

private final class SegmentDraft: ObservableObject {
    @Published var text: String
    @Published var speaker: String
    @Published var newSpeaker = ""
    init(_ segment: Segment) { text = segment.text; speaker = segment.speakerID ?? "" }
}

private struct SegmentEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let segment: Segment
    @StateObject private var draft: SegmentDraft
    init(meeting: Meeting, segment: Segment) {
        self.meeting = meeting; self.segment = segment
        _draft = StateObject(wrappedValue: SegmentDraft(segment))
    }
    private var speakerIDs: [String] { Array(Set(meeting.segments.compactMap(\.speakerID)).union(meeting.speakers.keys)).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Correggi segmento · \(timecode(segment.start))").font(.headline)
            TextEditor(text: $draft.text).font(.body).frame(height: 150).border(.secondary.opacity(0.25))
            Picker("Interlocutore", selection: $draft.speaker) {
                Text(segment.source.label).tag("")
                ForEach(speakerIDs, id: \.self) { id in Text(meeting.speakers[id] ?? id).tag(id) }
            }.disabled(!draft.newSpeaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextField("Oppure un nuovo interlocutore", text: $draft.newSpeaker).textFieldStyle(.roundedBorder)
            Text("Le modifiche sono conservate nella cronologia. I timestamp del segmento restano invariati.").font(.caption).foregroundStyle(.secondary)
            let history = (model.current?.corrections ?? meeting.corrections).filter { $0.segmentID == segment.id }
            if !history.isEmpty {
                DisclosureGroup("Cronologia · \(history.count) correzioni") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(history) { correction in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(correction.date.formatted()).font(.caption2)
                                    Text("Prima: \(correction.previousText)")
                                    Text("Dopo: \(correction.text)")
                                    Text("Interlocutore: \(speakerName(correction.previousSpeakerID)) → \(speakerName(correction.speakerID))")
                                }.font(.caption).textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 140)
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salva correzione") {
                    if model.correctSegment(meetingID: meeting.id, segmentID: segment.id, text: draft.text, speakerID: draft.speaker.isEmpty ? nil : draft.speaker, newSpeaker: draft.newSpeaker) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sessionLocked)
            }
        }.padding(24).frame(width: 580)
    }
    private func speakerName(_ id: String?) -> String { id.map { meeting.speakers[$0] ?? $0 } ?? segment.source.label }
}

final class SpeakerNameDraft: ObservableObject {
    @Published var text: String
    @Published var editing = false
    init(_ name: String) { text = name }
}
private struct SpeakerNameRow: View {
    @EnvironmentObject var model: AppModel
    let meetingID: UUID
    let speakerID: String
    let name: String
    @StateObject private var draft: SpeakerNameDraft
    @FocusState private var focused: Bool
    @State private var assigningProfile = false
    init(meetingID: UUID, speakerID: String, name: String) {
        self.meetingID = meetingID; self.speakerID = speakerID; self.name = name
        _draft = StateObject(wrappedValue:SpeakerNameDraft(name))
    }
    var body: some View {
        HStack(spacing:10) {
            if draft.editing {
                TextField("Nome dell’interlocutore",text:$draft.text).textFieldStyle(.roundedBorder).focused($focused).onSubmit { commit() }
                Button("Salva") { commit() }.disabled(model.sessionLocked || draft.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("Annulla") { draft.text = name; draft.editing = false }
            } else {
                Button { model.focusSpeaker(speakerID) } label: {
                    Label(name,systemImage:"text.magnifyingglass").frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain).help("Vai al primo passaggio di questo interlocutore")
                if let meeting = model.current, meeting.id == meetingID, let segment = meeting.firstSegment(forSpeaker:speakerID) {
                    Menu {
                        Button("Ricorda questa voce…") { model.beginVoiceEnrollment(segment,speakerGroupID:speakerID) }.disabled(!meeting.keepAudio && !meeting.keepRecovery)
                        Button("Assegna nome da profilo…") { assigningProfile = true }.disabled(model.voiceProfiles.isEmpty)
                    } label: { Image(systemName:"person.crop.circle.badge.plus") }
                        .menuStyle(.borderlessButton).fixedSize().help("Profili vocali di questo interlocutore")
                        .sheet(isPresented:$assigningProfile) { VoiceProfileAssignmentView(meetingID:meetingID,segmentID:segment.id,speakerGroupID:speakerID).environmentObject(model) }
                }
                Button { draft.text = name; draft.editing = true; focused = true } label: { Image(systemName:"pencil") }.buttonStyle(.plain).help("Modifica il nome in tutti i passaggi di questa persona")
            }
        }.font(.callout).disabled(model.sessionLocked)
            .onChange(of:name) { _,value in if !draft.editing { draft.text = value } }
    }
    private func commit() {
        guard model.current?.id == meetingID, !model.sessionLocked else { return }
        if draft.text.trimmingCharacters(in:.whitespacesAndNewlines) == name { draft.editing = false; return }
        Task { if await model.rename(speakerID,to:draft.text,meetingID:meetingID) { draft.editing = false } }
    }
}
