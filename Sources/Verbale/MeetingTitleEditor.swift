import SwiftUI
import VerbaleCore

private final class MeetingTitleDraft: ObservableObject {
    @Published var value: String
    init(_ value: String) { self.value = value }
}
struct MeetingTitleEditor: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @StateObject private var draft: MeetingTitleDraft
    @FocusState private var focused: Bool
    init(meeting: Meeting) { self.meeting = meeting; _draft = StateObject(wrappedValue:MeetingTitleDraft(meeting.title)) }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Modifica titolo della riunione").font(.headline)
            TextField("Titolo",text:$draft.value).textFieldStyle(.roundedBorder).focused($focused).onSubmit { save() }
            Text("Il titolo viene aggiornato nell’archivio e nei file di testo. I file rimangono nella cartella già scelta.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if model.archiveBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Annulla") { model.titleEditing = nil }.keyboardShortcut(.cancelAction).disabled(model.archiveBusy)
                Button("Salva titolo") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.archiveBusy || draft.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || draft.value.count > 160)
            }
        }.padding(24).frame(width:500).background(Color(nsColor:.windowBackgroundColor)).interactiveDismissDisabled(model.archiveBusy)
            .onAppear { focused = true }
    }
    private func save() { guard !model.archiveBusy else { return }; Task { await model.renameMeetingTitle(meeting,to:draft.value) } }
}
