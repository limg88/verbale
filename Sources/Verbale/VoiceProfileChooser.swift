import SwiftUI
import VerbaleCore

/// Search stays local to the chooser even with a large profile archive.
struct VoiceProfileChooser: View {
    let profiles: [VoiceProfile]
    @Binding var selection: String
    var allowsNew = false
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var matches: [VoiceProfile] {
        profiles.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        HStack {
            Text(allowsNew ? "Salva in" : "Profilo")
            Button { searching = true } label: {
                HStack {
                    Text(profiles.first { $0.id.uuidString == selection }?.name ?? (allowsNew ? "Nuovo profilo" : "Scegli un profilo…"))
                    Spacer()
                    Image(systemName:"magnifyingglass")
                }.frame(maxWidth:.infinity)
            }.popover(isPresented:$searching) {
                VStack(alignment:.leading,spacing:10) {
                    TextField("Cerca persona…",text:$query).textFieldStyle(.roundedBorder).focused($searchFocused)
                    if allowsNew {
                        Button("Crea nuovo profilo") { selection = ""; searching = false }
                        Divider()
                    }
                    Text("\(matches.count) profili").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:0) {
                            ForEach(matches) { profile in
                                Button { selection = profile.id.uuidString; searching = false } label: {
                                    HStack {
                                        Text(profile.name)
                                        Spacer()
                                        if selection == profile.id.uuidString { Image(systemName:"checkmark") }
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if matches.isEmpty { Text("Nessun profilo trovato").foregroundStyle(.secondary).padding(8) }
                        }
                    }.frame(height:240)
                }.padding(14).frame(width:340).onAppear { query = ""; searchFocused = true }
            }
        }
    }
}

struct VoiceProfileAssignmentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let segmentID: UUID
    var speakerGroupID: String? = nil
    @State private var selected = ""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Assegna nome da profilo").font(.headline)
            VoiceProfileChooser(profiles:model.voiceProfiles,selection:$selected)
            Text(speakerGroupID == nil ? "Assegna il nome ai passaggi di questa voce nella sorgente selezionata." : "Assegna il nome a tutti i passaggi di questo interlocutore, anche fra sorgenti diverse.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Assegna nome") {
                    guard model.current?.id == meetingID, let id = UUID(uuidString:selected) else { return }
                    model.assignSavedVoice(id,segmentID:segmentID,speakerGroupID:speakerGroupID)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty || model.sessionLocked || model.current?.id != meetingID)
            }
        }.padding(24).frame(width:480)
    }
}
