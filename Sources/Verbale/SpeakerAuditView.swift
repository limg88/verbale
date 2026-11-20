import SwiftUI
import VerbaleCore

private final class SpeakerAuditDraft: ObservableObject {
    @Published var groupID: UUID?
    @Published var fullAnalysis = false
    @Published var editing = false
    @Published var returnCaseID: UUID?
    @Published var selected: Set<UUID> = []
    @Published var name = ""
    @Published var verified = false
    @Published var listened: Set<UUID> = []
}
/// Memoises values that hash or rebuild the whole meeting, for the duration of one render pass.
private final class SpeakerAuditRenderCache {
    var valid: Bool?
    var triage: SpeakerAuditTriage??
    func reset() { valid = nil; triage = nil }
}
struct SpeakerAuditView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var draft = SpeakerAuditDraft()
    private let rendered = SpeakerAuditRenderCache()
    private var audit: SpeakerAudit? { model.speakerAudit }
    private var group: SpeakerAuditGroup? { audit?.groups.first { $0.id == draft.groupID } }
    private var pending: [SpeakerAuditPiece] { draft.groupID.flatMap { audit?.pending($0) } ?? [] }
    private var triage: SpeakerAuditTriage? {
        if let cached = rendered.triage { return cached }
        let value: SpeakerAuditTriage?
        if let audit, let meeting = model.current { value = SpeakerAuditTriage(audit: audit, meeting: meeting) } else { value = nil }
        rendered.triage = .some(value); return value
    }
    private var currentCase: SpeakerAuditCase? { triage?.cases.first { $0.groupID == draft.groupID } }
    private func choose(_ id: UUID?) {
        model.stopVoicePlayback(); draft.groupID = id; draft.selected = []; draft.name = ""; draft.verified = false; draft.listened = []; draft.editing = false
    }
    private var valid: Bool {
        if let cached = rendered.valid { return cached }
        let value: Bool
        if let meeting = model.current { value = audit?.isCurrent(for: meeting) == true } else { value = false }
        rendered.valid = value; return value
    }
    var body: some View {
        // Every model or draft change re-evaluates body, so the cache never outlives the state it was computed from.
        rendered.reset()
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Verifica altre voci").font(.title2).fontWeight(.semibold)
                Spacer()
                Button(draft.fullAnalysis ? "Torna ai casi prioritari" : "Analisi completa…") {
                    draft.fullAnalysis.toggle(); choose(draft.fullAnalysis ? audit?.groups.first?.id : triage?.cases.first?.groupID)
                }.font(.caption)
            }
            Text(draft.fullAnalysis ? "Analisi completa: include anche frammenti e gruppi incerti. I nomi cambiano solo dopo la tua conferma." : "Un massimo di 5 casi alla volta, con fino a 3 estratti ciascuno. Ascolta e apri la correzione solo se trovi un nome sbagliato.").font(.callout).foregroundStyle(.secondary)
            if model.learningBusy {
                HStack { ProgressView().controlSize(.small); Text(model.voiceProgress).font(.caption); Spacer(); Button("Annulla rivalutazione") { model.cancelVoiceAnalysis() } }
            } else if !model.learningSummary.isEmpty { Text(model.learningSummary).font(.caption).foregroundStyle(.secondary) }
            if !valid { Label("I contenuti sono cambiati: chiudi e ripeti la ricerca prima di applicare le proposte.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Palette.warning) }
            if let audit {
                DisclosureGroup("Avvisi dell’analisi · \(audit.warnings.count)") {
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(audit.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) } } }.frame(height: 80)
                }.font(.caption)
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if draft.fullAnalysis {
                                ForEach(audit.groups) { group in
                                    caseButton(group.id, title: group.label, subtitle: "\(audit.pending(group.id).count) passaggi")
                                }
                            } else {
                                ForEach(triage?.cases ?? []) { item in
                                    caseButton(item.groupID, title: item.title, subtitle: "\(item.examples.count) estratti da ascoltare")
                                }
                                if let triage {
                                    Text("\(triage.remainingPeopleCount) controlli mirati · \(triage.reviewedCount) messi da parte").font(.caption2).foregroundStyle(.secondary).padding(8)
                                    Text("Gli altri gruppi restano nell’analisi completa; non sono stati approvati o uniti automaticamente.").font(.caption2).foregroundStyle(.secondary).padding(8)
                                    if triage.reviewedCount > 0 { Button("Riapri messi da parte") { model.resetSpeakerAuditDeferrals() }.font(.caption).disabled(!valid).padding(8) }
                                }
                            }
                        }
                    }.frame(width: 205)
                    Divider()
                    if draft.fullAnalysis || draft.editing {
                        if let group { groupDetail(group) }
                    } else if let item = currentCase { quickDetail(item) }
                    else { ContentUnavailableView("Nessun altro caso prioritario", systemImage: "checkmark.circle", description: Text("Questo non certifica tutti i nomi. I frammenti incerti restano disponibili in Analisi completa.")) .frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.learningBusy)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(Palette.danger).lineLimit(3) }
            HStack {
                Button("Rivaluta con le conferme") { model.startSpeakerLearning() }.disabled(model.busy || !valid)
                Text("Audio e analisi restano sul Mac").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Chiudi") { model.stopVoicePlayback(); model.auditReviewVisible = false }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 890, height: 650).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { if draft.groupID == nil { choose(triage?.cases.first?.groupID) } }
            .onChange(of: audit?.reviewedBuckets?.count) { _, _ in rendered.reset(); if !draft.fullAnalysis { choose(triage?.cases.first?.groupID) } }
            .onChange(of: model.learningBusy) { _, active in rendered.reset(); if !active && !draft.fullAnalysis { choose(triage?.cases.first?.groupID) } }
            .onChange(of: draft.name) { _, _ in draft.verified = false }
            .onDisappear { model.stopVoicePlayback() }
    }
    private func caseButton(_ id: UUID, title: String, subtitle: String) -> some View {
        Button { choose(id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(draft.groupID == id ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    private func quickDetail(_ item: SpeakerAuditCase) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title).font(.headline)
            Text(item.detail).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(item.examples) { piece in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(item.referenceIDs.contains(piece.id) ? "Riferimento" : "Da confrontare") · \(timecode(piece.segment.start)) · \(originalName(piece))").font(.caption).foregroundStyle(.secondary)
                            Text(piece.segment.text).font(.callout).lineLimit(3)
                            HStack {
                                Button("Ascolta con contesto", systemImage: "play.fill") {
                                    if let clip = contextClip(piece.segment) { Task { if await model.listenAudit(clip) { draft.listened.insert(piece.id) } } }
                                }
                                Spacer()
                                Button("Correggi questo estratto…") {
                                    guard let groupID = piece.groupID else { return }
                                    let returnID = item.groupID
                                    choose(groupID); draft.returnCaseID = returnID; draft.editing = true
                                    draft.selected = [piece.id]; draft.listened = [piece.id]
                                }.disabled(!valid || !draft.listened.contains(piece.id))
                            }.font(.caption)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Button("Metti da parte questo controllo") { model.dismissSpeakerAuditCase(item.groupID) }.disabled(!valid || draft.listened.isDisjoint(with: Set(item.examples.filter { !item.referenceIDs.contains($0.id) }.map(\.id))))
                Spacer()
                Button("Correggi passaggi…") { draft.returnCaseID = item.groupID; draft.editing = true }.buttonStyle(.borderedProminent).disabled(!valid || draft.listened.isDisjoint(with: Set(item.examples.filter { !item.referenceIDs.contains($0.id) }.map(\.id))))
            }
            Text("Mette da parte il controllo rapido su questo nome e conserva tutte le assegnazioni. Gli altri gruppi restano nell’analisi completa.").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func groupDetail(_ group: SpeakerAuditGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(currentCase?.title ?? group.label).font(.headline)
                Spacer()
                if !draft.fullAnalysis { Button("Torna agli estratti") { choose(draft.returnCaseID ?? triage?.cases.first?.groupID) }.font(.caption) }
            }
            if let caution = group.caution { Text(caution).font(.caption).foregroundStyle(Palette.warning) }
            if group.clips.isEmpty { Text("Nessun campione di almeno 3 secondi: verifica i passaggi nella registrazione originale.").font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(group.clips) { clip in
                        Button("\(timecode(clip.start))", systemImage: "play.fill") { Task { if await model.listenAudit(clip) { draft.listened.insert(clip.id) } } }.font(.caption)
                    }
                }
            }.frame(height: 28)
            HStack {
                Text("Passaggi proposti · \(pending.count)").font(.caption)
                Spacer()
                Button("Tutti") { draft.selected = Set(pending.map(\.id)); draft.verified = false }
                Button("Nessuno") { draft.selected = []; draft.verified = false }
            }.font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(pending) { piece in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("Seleziona passaggio", isOn: Binding(get: { draft.selected.contains(piece.id) }, set: { value in
                                if value { draft.selected.insert(piece.id) } else { draft.selected.remove(piece.id) }; draft.verified = false
                            })).labelsHidden().toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(timecode(piece.segment.start)) · prima: \(originalName(piece))").font(.caption).foregroundStyle(.secondary)
                                Text(piece.segment.text).font(.callout).lineLimit(3)
                                Button("Ascolta estratto con contesto", systemImage: "play.fill") {
                                    if let clip = contextClip(piece.segment) { Task { if await model.listenAudit(clip) { draft.listened.insert(piece.id) } } }
                                }.font(.caption).disabled(contextClip(piece.segment) == nil)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.frame(maxHeight: .infinity)
            HStack {
                TextField("Nome verificato della persona", text: $draft.name).textFieldStyle(.roundedBorder)
                Menu("Nomi esistenti") {
                    ForEach(Array(Set(model.current?.speakers.values ?? Dictionary<String,String>().values)).sorted(), id: \.self) { name in Button(name) { draft.name = name } }
                }
            }
            Toggle("Ho verificato che i passaggi selezionati appartengono a questa persona", isOn: $draft.verified).toggleStyle(.checkbox).font(.caption)
            Text("La conferma salva questi nomi e rivaluta gli altri interventi. Solo corrispondenze forti vengono assegnate automaticamente; le tue correzioni restano protette.").font(.caption2).foregroundStyle(.secondary)
            Button("Assegna nome a \(draft.selected.count) passaggi") {
                if model.applySpeakerAudit(groupID: group.id, selected: draft.selected, name: draft.name) { draft.selected = []; draft.verified = false }
            }.buttonStyle(.borderedProminent)
                .disabled(!valid || !draft.verified || draft.selected.isEmpty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (draft.listened.isEmpty && !group.clips.isEmpty))
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func contextClip(_ segment: Segment) -> VoiceClip? {
        guard let meeting = model.current, meeting.duration >= 3 else { return nil }
        let end = min(meeting.duration, max(segment.start + 3.3, min(segment.end + 0.3, segment.start + 6)))
        let start = max(0, min(segment.start - 0.3, end - 3))
        return VoiceClip(meetingID: meeting.id, source: segment.source, start: start, end: end, text: segment.text)
    }
    private func originalName(_ piece: SpeakerAuditPiece) -> String {
        guard let original = audit?.originalSegments.first(where: { $0.id == piece.originalID }), let meeting = model.current else { return piece.segment.source.label }
        return meeting.speakerName(for: original)
    }
}
