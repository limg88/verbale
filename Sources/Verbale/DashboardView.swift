import SwiftUI
import AppKit
import VerbaleCore

private final class DesktopNavigationState: ObservableObject {
    @Published var query = ""
}
struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var viewState = DesktopNavigationState()
    private var prepared: Bool { model.installed.isSuperset(of: ["asr", "vad"]) }
    private var title: String {
        switch model.tab {
        case "followup": return "Da seguire"
        case "archive": return "Archivio"
        case "settings": return "Impostazioni"
        case "models": return "Modelli locali"
        default: return model.current?.title ?? "Nuova riunione"
        }
    }
    private var filteredMeetings: [Meeting] {
        let text = viewState.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.meetings.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || $0.notes.localizedCaseInsensitiveContains(text) || $0.segments.contains { $0.text.localizedCaseInsensitiveContains(text) } }
    }
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if (model.isRecording || model.activeRecording != nil) && (model.tab != "session" || !model.viewingRecording) { ActiveRecordingBanner() }
                if model.reportBusy {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(model.reportProgress).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Sospendi") { model.cancelReport() }
                    }.padding(.horizontal, 24).padding(.vertical, 12).background(Palette.accent.opacity(0.06))
                }
                if model.voiceBusy && model.voiceEnrollment == nil {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(model.voiceProgress).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Annulla analisi") { model.cancelVoiceAnalysis() }
                    }.padding(.horizontal, 24).padding(.vertical, 12).background(Palette.accent.opacity(0.06))
                }
                if !model.visibleWork.isEmpty { MeetingJobsView() }
                if model.tab == "session" { session.padding(24) }
                else if model.tab == "followup" { ProjectFollowUpView(tracker: model.projectTracker) }
                else if model.tab == "archive" { archive }
                else if model.tab == "settings" { DesktopSettingsView().padding(24) }
                else { ScrollView { models.padding(24) } }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $model.titleEditing) { meeting in MeetingTitleEditor(meeting:meeting).environmentObject(model) }
        .confirmationDialog("Rimuovere la riunione dall’archivio?", isPresented: Binding(get:{ model.pendingRemoval != nil },set:{ if !$0 { model.pendingRemoval = nil } }), presenting:model.pendingRemoval) { meeting in
            Button("Rimuovi dall’archivio",role:.destructive) { Task { await model.removeMeeting(meeting) } }
            Button("Annulla",role:.cancel) { model.pendingRemoval = nil }
        } message: { meeting in Text("La copia interna di «\(meeting.title)» verrà spostata nel Cestino. I file nella cartella di esportazione rimarranno disponibili.") }
        .sheet(isPresented:$model.refinementVisible) { TranscriptRefinementView().environmentObject(model) }
        .sheet(isPresented: $model.auditReviewVisible) { SpeakerAuditView().environmentObject(model) }
        .sheet(item: $model.voiceEnrollment) { request in VoiceEnrollmentView(request: request).environmentObject(model) }
        .alert("Verbale", isPresented: Binding(get: { model.error != nil && !model.refinementVisible && model.titleEditing == nil && model.pendingRemoval == nil && !model.quietMode && model.voiceEnrollment == nil && !model.auditReviewVisible }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size:21,weight:.semibold)).lineLimit(1).help(title)
                    if model.tab == "session", let meeting = model.current, !model.viewingRecording {
                        Button { model.editMeetingTitle(meeting) } label: { Image(systemName:"pencil") }.buttonStyle(.plain).help("Modifica titolo").disabled(!model.canManageMeeting(meeting))
                    }
                }
                if model.tab == "session", let meeting = model.current {
                    Text("\(meeting.started.formatted(date: .abbreviated, time: .shortened)) · \(timecode(model.viewingRecording ? model.elapsed : meeting.duration)) · \(meeting.sources.map { $0 == .microphone ? "Microfono" : "Sistema" }.joined(separator: " + "))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.isRecording && (model.tab != "session" || !model.viewingRecording) {
                Button("Vai alla registrazione") {model.showRecording()}.controlSize(.large).disabled(model.navigationLocked)
            } else if model.tab == "session", model.current == nil || model.viewingRecording {
                Button { Task { if model.isRecording { await model.stop() } else { await model.start() } } } label: {
                    Label(model.isRecording ? "Termina e salva" : "Avvia registrazione", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                }.buttonStyle(.borderedProminent).tint(model.isRecording ? .red : Palette.accent).controlSize(.large)
                    .disabled(model.busy || model.reportBusy || (!model.isRecording && (!prepared || model.working || (!model.microphone && !model.system))))
                    .help("⇧⌘R")
            } else {
                Button { model.newMeeting() } label: { Label("Nuova riunione", systemImage: "plus") }
                    .controlSize(.large).disabled(model.navigationLocked)
            }
            if model.tab == "session", let meeting = model.current, !model.viewingRecording {
                Button { model.reveal() } label: { Image(systemName: "folder") }.help("Apri cartella della riunione").disabled(!meeting.exported)
                Button(role:.destructive) { model.delete(meeting) } label: { Image(systemName:"trash") }
                    .help(model.workLocked(meeting.id) ? "Sospendi le attività della riunione prima di rimuoverla.":"Rimuovi riunione…").accessibilityLabel("Rimuovi riunione").disabled(!model.canManageMeeting(meeting))
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Verbale", systemImage: "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.accent).padding(.vertical, 12)
            VStack(spacing: 4) {
                navigation("session", "Riunione", "waveform")
                navigation("archive", "Archivio", "tray.full")
                navigation("followup", "Da seguire", "checklist")
            }
            if !model.meetings.isEmpty {
                Text("Recenti").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                VStack(spacing: 2) {
                    ForEach(Array(model.meetings.prefix(5))) { meeting in
                        Button { model.open(meeting) } label: {
                            HStack { Text(meeting.title).lineLimit(1); Spacer(minLength: 0) }
                                .font(.callout).padding(10)
                                .background(model.current?.id == meeting.id && model.tab == "session" ? Palette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(model.navigationLocked).help(meeting.title)
                    }
                }
            }
            Spacer()
            if !prepared {
                Button { model.tab = "models" } label: { Label("Prepara trascrizione", systemImage: "arrow.down.circle") }.font(.callout)
            }
            Button { model.showWidget() } label: { Label("Apri widget", systemImage: "rectangle.inset.filled") }.buttonStyle(.plain).font(.callout).padding(10).help("⇧⌘M")
            navigation("settings", "Impostazioni", "gearshape")
        }.padding(16).frame(maxHeight: .infinity).background(.thinMaterial)
    }
    private func navigation(_ id: String, _ label: String, _ icon: String) -> some View {
        Button { if id == "session",model.isRecording {model.showRecording()} else {model.tab=id} } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(label)
                Spacer()
                if id == "session" && model.isRecording { Circle().fill(.red).frame(width: 7, height: 7) }
            }.font(.system(size: 13, weight: model.tab == id ? .semibold : .regular)).padding(10)
                .foregroundStyle(model.tab == id ? Palette.accent : .primary)
                .background(model.tab == id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var session: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.exportError {
                HStack { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange); Spacer(); Button("Riprova") { model.exportCurrent() }.disabled(model.sessionLocked); Button("Cambia cartella") { model.exportElsewhere() }.disabled(model.sessionLocked) }.font(.callout)
            }
            if model.current == nil {
                if !prepared {
                    Surface {
                        HStack { VStack(alignment: .leading, spacing: 5) { Text("Prepara la trascrizione").font(.headline); Text("Scarica i due modelli necessari una volta, poi registra anche offline.").foregroundStyle(.secondary) }; Spacer(); Button("Prepara…") { model.tab = "models" }.buttonStyle(.borderedProminent) }
                    }
                }
                preparation
                Spacer(minLength: 20)
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 40, weight: .light)).foregroundStyle(Palette.accent)
                    Text("Pronto per la prossima riunione").font(.title3).fontWeight(.medium)
                    Text("Avvia la registrazione. Trascrizione, note e report saranno qui.").foregroundStyle(.secondary)
                    if model.teamsAutoEnabled { Label("Avvio automatico Teams attivo", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                }.font(.callout).frame(maxWidth: .infinity)
                Spacer(minLength: 20)
            } else if let meeting = model.current {
                if model.viewingRecording || (model.busy && (model.activeRecording == nil || model.activeRecording?.id==meeting.id)) || (model.working && !model.isRecording) {
                    HStack(spacing: 14) {
                        if model.viewingRecording { Circle().fill(.red).frame(width: 8, height: 8); Text(timecode(model.elapsed)).monospacedDigit().fontWeight(.semibold) }
                        else { ProgressView().controlSize(.small) }
                        Text(model.status).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if model.viewingRecording { MarkerMenu().fixedSize(); Button { Task { await model.screenshot() } } label: { Label("Screenshot", systemImage: "camera") } }
                    }.font(.callout)
                }
                if model.viewingRecording {
                    HStack(spacing: 24) {
                        ForEach(meeting.sources, id: \.self) { source in
                            HStack(spacing: 8) {
                                Image(systemName: source == .microphone ? "mic" : "speaker.wave.2")
                                Text(source == .microphone ? "Microfono" : "Sistema")
                                LiveAudioLevel(state:model.audioLevels,source:source)
                            }
                        }
                    }.font(.caption).foregroundStyle(.secondary).accessibilityLabel("Livelli delle sorgenti audio attive")
                }
                if !meeting.warnings.isEmpty || !(meeting.echoDuplicates ?? []).isEmpty || !(meeting.transcriptBoundaryEdits ?? []).isEmpty {
                    DisclosureGroup("Avvisi della registrazione") {
                        ForEach(meeting.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        if let edits = meeting.transcriptBoundaryEdits, !edits.isEmpty {
                            Text("\(edits.reduce(0) { $0+$1.duplicates.count }) parole duplicate riconciliate. Le ipotesi originali sono conservate nei file della riunione.").font(.callout).foregroundStyle(.secondary)
                        }
                        if let duplicates = meeting.echoDuplicates, !duplicates.isEmpty { Text("\(duplicates.count) passaggi di eco riconciliati. Gli originali sono conservati nei file della riunione.").font(.callout).foregroundStyle(.secondary) }
                    }
                }
                if !model.viewingRecording { ProjectAssignmentView(tracker: model.projectTracker, meetingID: meeting.id) }
                Picker("Contenuto della riunione", selection: $model.meetingSection) {
                    Text("Trascrizione").tag("transcript")
                    Text("Note").tag("notes")
                    Text("Report").tag("report")
                    Text("Attività").tag("actions")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 410)
                switch model.meetingSection {
                case "actions": MeetingActionsView(tracker: model.projectTracker, meeting: meeting)
                case "notes": MeetingNotesView(meeting: meeting,drafts:model.noteDrafts)
                case "report": MeetingReportView(meeting: meeting)
                default: TranscriptReviewView(meeting: meeting)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var preparation: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Titolo della riunione (facoltativo)", text: $model.title).textFieldStyle(.roundedBorder).controlSize(.large).disabled(model.sessionLocked)
                HStack(spacing: 20) {
                    Toggle("Microfono", isOn: $model.microphone).toggleStyle(.checkbox)
                    Toggle("Audio di sistema", isOn: $model.system).toggleStyle(.checkbox)
                    Spacer()
                    Picker("Ascolto", selection: $model.listeningMode) { ForEach(ListeningMode.allCases) { Text($0.label).tag($0) } }.frame(maxWidth: 300)
                }.disabled(model.sessionLocked)
                if !model.microphone && !model.system { Label("Attiva almeno una sorgente audio.", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout) }
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.destination?.path ?? "Scegli dove salvare le riunioni").font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button(model.destination == nil ? "Scegli cartella…" : "Cambia…") { model.chooseDestination() }.disabled(model.sessionLocked)
                }
                HStack {
                    Toggle("Conserva l’audio", isOn: $model.keepAudio).toggleStyle(.checkbox).disabled(model.sessionLocked)
                        .help("Salva l’audio nella cartella della riunione. Se disattivato, i temporanei vengono rimossi dopo il completamento riuscito.")
                    Spacer()
                    Button("Dispositivi audio…") { model.tab = "settings"; model.settingsSection = "advanced" }.buttonStyle(.link)
                }

            }
        }
    }
    private var archive: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca in titoli, trascrizioni e note", text: $viewState.query).textFieldStyle(.plain)
                if !viewState.query.isEmpty { Button { viewState.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Cancella ricerca") }
            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10))
            Text("\(filteredMeetings.count) riunioni").font(.callout).foregroundStyle(.secondary)
            if filteredMeetings.isEmpty {
                ContentUnavailableView(viewState.query.isEmpty ? "Nessuna riunione" : "Nessun risultato", systemImage: viewState.query.isEmpty ? "tray" : "magnifyingglass", description: Text(viewState.query.isEmpty ? "Le registrazioni salvate compariranno qui." : "Prova un altro titolo o una parola della conversazione."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredMeetings) { meeting in
                    HStack {
                    Button { model.open(meeting) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: meeting.keepAudio ? "waveform" : "text.alignleft").foregroundStyle(Palette.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(meeting.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text("\(meeting.started.formatted(date: .abbreviated, time: .shortened)) · \(timecode(meeting.duration))").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if meeting.report != nil { Image(systemName: "doc.text").foregroundStyle(.secondary).help("Report disponibile") }
                            Text(model.workJobs.first(where:{$0.meetingID==meeting.id && $0.state.pending}).map{$0.state == .running ? "In elaborazione":$0.state == .waitingForTeams ? "Attesa Teams":"In coda"} ?? stateTitle(meeting.state)).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.navigationLocked)
                        Button { model.editMeetingTitle(meeting) } label: { Image(systemName:"pencil") }.buttonStyle(.borderless).help("Modifica titolo").disabled(!model.canManageMeeting(meeting))
                    Button(role:.destructive) { model.delete(meeting) } label: { Image(systemName:"trash") }.buttonStyle(.borderless).help("Rimuovi dall’archivio…").disabled(!model.canManageMeeting(meeting))
                    }
                    .contextMenu {
                        Button("Apri riunione") { model.open(meeting) }.disabled(model.navigationLocked)
                        Button("Modifica titolo…") { model.editMeetingTitle(meeting) }.disabled(!model.canManageMeeting(meeting))
                        Button("Rimuovi dall’archivio…",role:.destructive) { model.delete(meeting) }.disabled(!model.canManageMeeting(meeting))
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var models: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Una preparazione iniziale per trascrivere sul Mac, anche offline.").foregroundStyle(.secondary)
            ForEach(model.models.catalog) { spec in
                Surface {
                    HStack(spacing: 16) {
                        Image(systemName: spec.id == "asr" ? "text.bubble" : spec.id == "vad" ? "waveform" : "person.2").font(.title2).foregroundStyle(Palette.accent).frame(width: 38)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(spec.id == "asr" ? "Trascrizione" : spec.id == "vad" ? "Rilevamento del parlato" : spec.id == "voice" ? "Profili vocali" : "Interlocutori").font(.headline)
                            Text("\(["diarization", "voice"].contains(spec.id) ? "Opzionale" : "Necessario") · \(ByteCountFormatter.string(fromByteCount: spec.bytes, countStyle: .file)) · \(spec.license)").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.modelWork == spec.id { ProgressView().controlSize(.small) }
                        else if model.installed.contains(spec.id) { Label("Installato", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                        else { Button("Scarica") { model.installModel(spec.id, importFile: false) }.buttonStyle(.borderedProminent); Button("Importa…") { model.installModel(spec.id, importFile: true) } }
                    }
                }.disabled(model.modelWork != nil || model.sessionLocked)
            }
            Link("Licenze e modelli", destination: URL(string: "https://huggingface.co/mudler/parakeet-cpp-gguf")!)
        }
    }
}
