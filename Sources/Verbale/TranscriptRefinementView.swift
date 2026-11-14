import SwiftUI
import VerbaleCore

private final class RefinementViewDraft:ObservableObject {
    @Published var scope:RefinementScope = .uncertain
    @Published var selected:Set<UUID> = []
    @Published var query = ""
}
struct TranscriptRefinementView:View {
    @EnvironmentObject var model:AppModel
    @StateObject private var state = RefinementViewDraft()
    private var proposals:[TranscriptProposal] {
        (model.refinementDraft?.pending ?? []).filter { state.query.isEmpty || $0.original.localizedCaseInsensitiveContains(state.query) || $0.candidate.localizedCaseInsensitiveContains(state.query) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("Riascolta e confronta").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Chiudi") { model.refinementVisible = false }.disabled(model.busy).keyboardShortcut(.cancelAction)
            }
            Text("Un secondo passaggio locale usa più contesto e unisce le pause brevi. Le correzioni manuali restano escluse. Scegli quali proposte applicare: nomi e collegamenti rimangono invariati.").font(.callout).foregroundStyle(.secondary)
            HStack {
                if model.refinementSelection != nil { Text("Solo il passaggio selezionato").font(.callout) }
                else { Picker("Analizza",selection:$state.scope) { Text("Passaggi incerti").tag(RefinementScope.uncertain);Text("Tutta la trascrizione").tag(RefinementScope.all) }.frame(maxWidth:350) }
                Spacer()
                Button(model.refinementDraft == nil ? "Prepara proposte":"Ripeti analisi") { state.selected = [];model.prepareRefinement(scope:model.refinementSelection == nil ? state.scope:.all) }.disabled(model.busy)
            }
            if model.refinementBusy {
                HStack { ProgressView().controlSize(.small);Text(model.refinementProgress).font(.callout);Spacer();Button("Annulla riascolto") { model.cancelRefinement() } }
            }
            if let draft = model.refinementDraft {
                ForEach(draft.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    TextField("Filtra per parola o termine tecnico",text:$state.query).textFieldStyle(.roundedBorder)
                    Button("Seleziona visibili") { state.selected.formUnion(proposals.map(\.id)) }.disabled(model.busy)
                    Button("Deseleziona") { state.selected = [] }.disabled(model.busy)
                }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:10) {
                        if proposals.isEmpty { Text("Nessuna proposta in questa selezione.").foregroundStyle(.secondary).padding() }
                        ForEach(proposals) { proposal in
                            HStack(alignment:.top,spacing:10) {
                                Toggle("",isOn:Binding(get:{state.selected.contains(proposal.id)},set:{if $0 {state.selected.insert(proposal.id)} else {state.selected.remove(proposal.id)}})).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Applica questa proposta").disabled(model.busy)
                                VStack(alignment:.leading,spacing:6) {
                                    HStack {
                                        Text(timecode(proposal.start)+" · "+proposal.source.label).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button(proposal.end-proposal.start > 8 ? "Ascolta primi 8 s":"Ascolta") { if let meeting = model.current { Task { _ = await model.listenRefinement(VoiceClip(meetingID:meeting.id,source:proposal.source,start:proposal.start,end:min(proposal.end,proposal.start+8),text:proposal.original)) } } }.disabled(model.busy)
                                    }
                                    Text("Prima: "+proposal.original).foregroundStyle(.secondary)
                                    Text("Proposta: "+proposal.candidate)
                                }.font(.callout).textSelection(.enabled)
                            }.padding(12).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }.frame(minHeight:140,maxHeight:340)
                HStack {
                    Text("\(draft.pending.count) proposte · \(state.selected.count) selezionate").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !draft.applied.isEmpty { Button("Ripristina precedente") { Task { if await model.applyRefinement([],undo:true) { state.selected = [] } } }.disabled(model.busy) }
                    Button("Applica selezionate") { let selected = state.selected;Task { if await model.applyRefinement(selected) { state.selected = [] } } }.buttonStyle(.borderedProminent).disabled(model.busy || state.selected.isEmpty)
                }
            } else { Spacer();Text("La trascrizione attuale resta disponibile durante il confronto.").foregroundStyle(.secondary);Spacer() }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(Palette.danger).textSelection(.enabled) }
        }.padding(24).frame(width:800,height:600).background(Color(nsColor:.windowBackgroundColor)).interactiveDismissDisabled(model.busy).onDisappear { model.stopVoicePlayback() }
    }
}
