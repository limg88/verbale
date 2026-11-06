import SwiftUI
import VerbaleCore

@MainActor final class ProjectTracker: ObservableObject {
    @Published private(set) var ledger = ProjectLedger()
    @Published var error: String?
    @Published private(set) var available = false
    private let store: ProjectLedgerStore
    init(file: URL) { store = ProjectLedgerStore(file: file); reload() }
    func reload() {
        do { ledger = try store.load(); available = true; error = nil }
        catch { available = false; self.error = "Registro non disponibile. Il file è conservato: " + error.localizedDescription }
    }
    @discardableResult func change(_ edit: (inout ProjectLedger) throws -> Void) -> Bool {
        guard available else { return false }
        do {
            var next = ledger
            try edit(&next); try store.save(next)
            ledger = next; error = nil; return true
        } catch { self.error = "Modifiche non salvate: " + error.localizedDescription; return false }
    }
}

struct ProjectAssignmentView: View {
    @ObservedObject var tracker: ProjectTracker
    var meetingID: UUID?
    @State private var newName = ""
    @State private var creating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let meetingID {
                    Picker("Progetto", selection: Binding<UUID?>(get: { tracker.ledger.projectID(for: meetingID) }, set: { value in
                        tracker.change { try $0.assign(meetingID: meetingID, to: value) }
                    })) {
                        Text("Nessun progetto").tag(nil as UUID?)
                        ForEach(tracker.ledger.projects) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 340)
                }
                Button("Nuovo progetto…") { creating.toggle() }.disabled(!tracker.available)
                if creating {
                    TextField("Nome progetto", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Button("Crea") {
                        if tracker.change({ ledger in
                            let id = try ledger.addProject(name: newName)
                            if let meetingID { try ledger.assign(meetingID: meetingID, to: id) }
                        }) { newName = ""; creating = false }
                    }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer(minLength: 0)
            }.disabled(!tracker.available)
            if let error = tracker.error {
                HStack { Text(error).font(.callout).foregroundStyle(.orange); if !tracker.available { Button("Riprova lettura") { tracker.reload() } } }
            }
        }
    }
}

struct MeetingActionsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tracker: ProjectTracker
    let meeting: Meeting
    @State private var reviewing: ActionProposal?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conferma gli impegni da seguire").font(.headline)
            Text("Le proposte restano separate dalle attività confermate. Per registrare un aggiornamento scegli l’attività esistente nella finestra di revisione.").font(.callout).foregroundStyle(.secondary)
            if tracker.ledger.projectID(for: meeting.id) == nil { Label("Assegna un progetto per confermare le attività.", systemImage: "folder.badge.questionmark").foregroundStyle(.orange) }
            if meeting.reportNeedsUpdate { Label("Le fonti sono cambiate: rigenera il report operativo prima di confermare.", systemImage: "arrow.clockwise").foregroundStyle(.orange) }
            if let proposals = meeting.actionProposals, !proposals.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(proposals) { proposal in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    Text(proposal.text).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                                    if tracker.ledger.action(for: proposal) != nil { Label("Confermata", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                                    else {
                                        Button("Rivedi…") { reviewing = proposal }
                                            .disabled(!tracker.available || tracker.ledger.projectID(for: meeting.id) == nil || meeting.reportNeedsUpdate || model.workLocked(meeting.id) || model.viewingRecording)
                                    }
                                }
                                Text("\(["agreed":"Impegno esplicito", "proposed":"Proposta", "unclear":"Da confermare"][proposal.commitment] ?? "Da confermare") · \(proposal.owner ?? "Da assegnare") · \(proposal.deadline ?? "Scadenza non indicata")").font(.caption).foregroundStyle(.secondary)
                                if let status = proposal.declaredStatus { Text("Stato dichiarato: " + status).font(.caption) }
                                let matches = tracker.ledger.suggestedMatches(for: proposal)
                                if tracker.ledger.action(for: proposal) == nil, !matches.isEmpty { Text("Possibile aggiornamento di: " + matches.map { $0.fields.text }.joined(separator: "; ")).font(.caption).foregroundStyle(.orange) }
                            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else {
                ContentUnavailableView("Nessuna proposta di attività", systemImage: "checklist", description: Text("Genera o rigenera il report in formato Operativo. Le riunioni precedenti restano compatibili; i report estesi non alimentano il registro."))
            }
        }.sheet(item: $reviewing) { proposal in
            ActionEditor(tracker: tracker, proposal: proposal).environmentObject(model)
        }
    }
}

private enum FollowUpFilter: String, CaseIterable {
    case open = "Aperte", overdue = "Scadute", soon = "Entro 7 giorni", blocked = "Bloccate", unassigned = "Da assegnare", all = "Tutte"
}
struct ProjectFollowUpView: View {
    @ObservedObject var tracker: ProjectTracker
    @State private var projectID: UUID?
    @State private var filter = FollowUpFilter.open
    @State private var editing: TrackedAction?
    private var actions: [TrackedAction] {
        tracker.ledger.actions.filter { action in
            guard projectID == nil || action.projectID == projectID else { return false }
            switch filter {
            case .all: return true
            case .open: return action.fields.status != .completed
            case .overdue: return action.isOverdue(at: Date())
            case .soon: return action.isDueSoon(at: Date())
            case .blocked: return action.fields.status == .blocked
            case .unassigned: return action.fields.status != .completed && action.fields.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }.sorted {
            if $0.isOverdue(at: Date()) != $1.isOverdue(at: Date()) { return $0.isOverdue(at: Date()) }
            return ($0.fields.dueDate ?? .distantFuture) < ($1.fields.dueDate ?? .distantFuture)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProjectAssignmentView(tracker: tracker)
            HStack {
                Picker("Progetto", selection: $projectID) {
                    Text("Tutti i progetti").tag(nil as UUID?)
                    ForEach(tracker.ledger.projects) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 330)
                Picker("Mostra", selection: $filter) { ForEach(FollowUpFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 300)
                Spacer()
                Text("\(actions.count) attività").foregroundStyle(.secondary)
            }
            if actions.isEmpty {
                ContentUnavailableView("Nessuna attività in questa vista", systemImage: "checklist", description: Text("Assegna un progetto a una riunione, genera il report operativo e rivedi le proposte nella scheda Attività."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(actions) { action in
                            Button { editing = action } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .top) {
                                        Text(action.fields.text).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(action.fields.status.label).foregroundStyle(action.fields.status == .blocked ? .orange : .secondary)
                                    }
                                    Text("\(tracker.ledger.projects.first { $0.id == action.projectID }?.name ?? "Progetto") · \(action.fields.owner.isEmpty ? "Da assegnare" : action.fields.owner)").font(.callout).foregroundStyle(.secondary)
                                    HStack {
                                        if let due = action.fields.dueDate { Text("Scadenza: " + due.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(action.isOverdue(at: Date()) ? .red : .secondary) }
                                        else { Text(action.fields.originalDeadline.isEmpty ? "Scadenza non indicata" : "Data da confermare: " + action.fields.originalDeadline).foregroundStyle(.secondary) }
                                        Spacer()
                                        Text("\(action.revisions.count) revisioni · \(Set(action.sources.map(\.meetingID)).count) riunioni").foregroundStyle(.secondary)
                                    }.font(.caption)
                                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!tracker.available)
                        }
                    }
                }
            }
        }.padding(24).sheet(item: $editing) { action in ActionEditor(tracker: tracker, action: action) }
    }
}

struct ActionEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tracker: ProjectTracker
    let proposal: ActionProposal?
    let action: TrackedAction?
    @State private var targetID: UUID?
    @State private var fields: ActionFields
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var failure: String?
    init(tracker: ProjectTracker, proposal: ActionProposal? = nil, action: TrackedAction? = nil) {
        self.tracker = tracker; self.proposal = proposal; self.action = action
        let fields = action?.fields ?? ActionFields(text: proposal?.text ?? "", owner: proposal?.owner ?? "", originalDeadline: proposal?.deadline ?? "", dependencies: proposal?.dependencies ?? "")
        _fields = State(initialValue: fields); _hasDate = State(initialValue: fields.dueDate != nil); _date = State(initialValue: fields.dueDate ?? Date())
    }
    private var existing: [TrackedAction] { tracker.ledger.actions.filter { $0.projectID == proposal.flatMap { tracker.ledger.projectID(for: $0.meetingID) } } }
    private var selected: TrackedAction? { action ?? existing.first { $0.id == targetID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(proposal == nil ? "Modifica attività" : "Rivedi proposta").font(.title2)
            if let proposal {
                Text("Dalla riunione: " + proposal.text).font(.callout)
                if let deadline = proposal.deadline { Text("Scadenza pronunciata: " + deadline).font(.callout) }
                if let status = proposal.declaredStatus { Text("Stato dichiarato: " + status + ". Conferma lo stato nel campo sotto.").font(.callout) }
                Picker("Destinazione", selection: $targetID) {
                    Text("Crea nuova attività").tag(nil as UUID?)
                    ForEach(existing) { Text("Aggiorna: " + $0.fields.text).tag(Optional($0.id)) }
                }.onChange(of: targetID) { _, value in
                    if let old = existing.first(where: { $0.id == value }) { fields = old.fields }
                    else { fields = ActionFields(text: proposal.text, owner: proposal.owner ?? "", originalDeadline: proposal.deadline ?? "", dependencies: proposal.dependencies ?? "") }
                    hasDate = fields.dueDate != nil; date = fields.dueDate ?? Date()
                }
                if targetID != nil { Text("Sono mostrati i valori già confermati. Modifica esplicitamente quelli aggiornati dalla nuova riunione.").font(.caption).foregroundStyle(.secondary) }
            }
            Form {
                TextField("Attività", text: $fields.text)
                TextField("Responsabile", text: $fields.owner, prompt: Text("Da assegnare"))
                TextField("Scadenza originale", text: $fields.originalDeadline, prompt: Text("Non indicata"))
                Toggle("Data confermata dal PM", isOn: $hasDate)
                if hasDate { DatePicker("Scadenza", selection: $date, displayedComponents: .date) }
                Picker("Stato confermato", selection: $fields.status) { ForEach(ActionStatus.allCases) { Text($0.label).tag($0) } }
                TextField("Dipendenze", text: $fields.dependencies)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let proposal { sourceList(proposal.sources) }
                    if let selected {
                        Text("Cronologia e fonti").font(.headline)
                        ForEach(selected.revisions.reversed()) { revision in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(revision.date.formatted() + " · " + revision.note).font(.caption).foregroundStyle(.secondary)
                                Text(revision.fields.text)
                                Text("\(revision.fields.owner.isEmpty ? "Da assegnare" : revision.fields.owner) · \(revision.fields.status.label) · Data: \(revision.fields.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? "Non confermata") · Originale: \(revision.fields.originalDeadline.isEmpty ? "Non indicata" : revision.fields.originalDeadline)").font(.caption)
                                if !revision.fields.dependencies.isEmpty { Text("Dipendenze: " + revision.fields.dependencies).font(.caption) }
                                if let source = revision.sourceProposal { sourceList(source.sources) }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            if let failure { Text(failure).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer(); Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Conferma e salva") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!tracker.available || fields.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 680)
    }
    @ViewBuilder private func sourceList(_ sources: [ActionSource]) -> some View {
        ForEach(sources) { source in
            VStack(alignment: .leading, spacing: 3) {
                Button(source.meetingTitle + " · " + timecode(source.timestamp ?? 0)) {
                    guard let meeting = model.meetings.first(where: { $0.id == source.meetingID }), let segmentID = source.segmentID else { return }
                    dismiss(); model.open(meeting)
                    _ = model.openReportSource(URL(string: "transcript.md#segment-" + segmentID.uuidString.lowercased())!)
                }.disabled(model.navigationLocked || !model.meetings.contains { $0.id == source.meetingID })
                Text(source.quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func save() {
        fields.dueDate = hasDate ? date : nil
        if let proposal {
            guard let meeting = model.meetings.first(where: { $0.id == proposal.meetingID }), !meeting.reportNeedsUpdate,
                  meeting.actionProposals?.contains(proposal) == true, !model.workLocked(meeting.id), !(model.isRecording && model.recording?.id == meeting.id) else {
                failure = "La proposta o le fonti sono cambiate. Chiudi la revisione e rigenera il report operativo."; return
            }
        }
        // Detect an edit made since opening this sheet rather than overwriting it.
        if let action, tracker.ledger.actions.first(where: { $0.id == action.id }) != action { failure = "L’attività è cambiata: riaprila dal registro."; return }
        let saved = tracker.change { ledger in
            if let proposal { try ledger.confirm(proposal, fields: fields, updating: targetID) }
            else if let action { try ledger.edit(action.id, fields: fields) }
        }
        if saved { dismiss() } else { failure = tracker.error }
    }
}
