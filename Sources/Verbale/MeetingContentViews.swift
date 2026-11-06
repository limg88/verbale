import SwiftUI
import AppKit
import VerbaleCore

struct GatewayModelPicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            if model.gatewayModels.isEmpty {
                TextField("Modello del report", text: $model.gatewayModel).textFieldStyle(.roundedBorder)
            } else {
                Picker("Modello", selection: $model.gatewayModel) {
                    ForEach(model.gatewayModels, id: \.id) { Text($0.id).tag($0.id) }
                }
            }
            Button { Task { await model.checkGateway() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Verifica gateway e aggiorna modelli").accessibilityLabel("Aggiorna modelli del report")
                .disabled(model.checkingGateway)
        }.disabled(model.reportBusy || model.busy)
    }
}
struct MeetingReportView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    private var reportState:MeetingWorkState? {model.work(meeting.id,kind:.report)?.state}
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                GatewayModelPicker().frame(maxWidth: 300)
                Picker("Formato",selection:$model.reportStyle) {
                    ForEach(ReportStyle.allCases) { Text($0.label).tag($0) }
                }.frame(maxWidth:180).disabled(model.reportBusy || model.busy)
                    .help("Operativo: sintesi e attività con impaginazione locale. Esteso: resoconto approfondito, più lento. Si applica alla prossima generazione.")
                Spacer()
                Button(meeting.report == nil ? "Genera report" : "Rigenera report") { model.startReport() }
                    .buttonStyle(.borderedProminent).disabled(model.navigationLocked || model.viewingRecording || meeting.segments.isEmpty || model.work(meeting.id,kind:.report)?.state.pending == true)
                if let report = meeting.reportDocument {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.help("Copia report").accessibilityLabel("Copia report")
                }
            }
            if let job=model.work(meeting.id,kind:.report),job.state != .completed { Text(job.error ?? job.progress).font(.callout).foregroundStyle(job.state == .failed ? .orange:.secondary) }
            if meeting.reportNeedsUpdate { Label("La riunione è stata modificata. Rigenera il report per aggiornarlo.", systemImage: "arrow.clockwise").font(.callout).foregroundStyle(.orange) }
            if let report = meeting.report {
                ScrollView {
                    ReportDocumentView(text: report).equatable()
                        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                        .environment(\.openURL, OpenURLAction { url in model.openReportSource(url) ? .handled : .systemAction })
                }.background(.background, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ContentUnavailableView(model.reportBusy || reportState == .running ? "Generazione del report…" : reportState == .queued ? "Report in coda" : "Il report della riunione", systemImage: "doc.text", description: Text(model.reportBusy || reportState?.pending == true ? "Puoi consultare le altre riunioni mentre attendi." : "Sintesi, decisioni, azioni e punti aperti, con rimandi alla trascrizione."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("Trascrizione e note vengono inviate al modello scelto tramite il gateway.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Configura servizio…") { model.tab = "settings"; model.settingsSection = "reports" }.font(.callout)
            }
            if !model.gatewayStatus.isEmpty { Text(model.gatewayStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct MeetingNotesView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @ObservedObject var drafts:NotesDraftState
    init(meeting:Meeting,drafts:NotesDraftState) {self.meeting=meeting;self.drafts=drafts}
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Note personali").font(.headline)
                Spacer()
                if drafts.failures.contains(meeting.id) {
                    Button("Riprova salvataggio") {drafts.commit(meeting.id)}.font(.caption)
                } else {Text(drafts.contains(meeting.id) ? "Salvataggio…":"Salvataggio automatico").font(.caption).foregroundStyle(.secondary)}
            }
            TextEditor(text: Binding(get: { drafts.text(for:meeting.id,fallback:meeting.notes) }, set: { drafts.edit($0,id:meeting.id) }))
                .font(.system(size: 14)).scrollContentBackground(.hidden).padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .focused($focused).disabled(model.reportBusy || model.busy || model.workJobs.contains{$0.meetingID==meeting.id && $0.state.pending} || model.pendingWorkSubmissions.contains(meeting.id))
                .accessibilityLabel("Note personali della riunione")
            if !meeting.markers.isEmpty {
                DisclosureGroup("Momenti segnati · \(meeting.markers.count)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(meeting.markers.sorted { $0.timestamp < $1.timestamp }) { marker in
                                HStack {
                                    Button("\(timecode(marker.timestamp)) · \(marker.kind.label)") { _ = model.openReportSource(URL(string: "transcript.md#\(marker.anchor)")!) }.buttonStyle(.plain)
                                    Spacer()
                                    Button { model.removeMarker(marker.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).disabled(model.reportBusy || model.busy).help("Rimuovi marcatore")
                                }
                            }
                        }.padding(.top, 8)
                    }.frame(maxHeight: 150)
                }.font(.callout)
            }
            Text("Gli appunti restano distinti dalle parole pronunciate e vengono inclusi quando generi il report.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear { drafts.commit(meeting.id) }
            .onAppear { focused = model.focusNotes }
            .onChange(of: model.focusNotes) { _, value in focused = value }
    }
}
