import SwiftUI
import VerbaleCore

final class VoiceEnrollmentDraft: ObservableObject {
    @Published var name: String
    @Published var existing = ""
    @Published private(set) var selected: Set<UUID> = []
    @Published var listened: Set<UUID> = []
    @Published var verified = false
    @Published var automatic = true
    init(name: String) { self.name = name }
    func select(_ id: UUID, _ value: Bool) {
        if value {
            guard listened.contains(id), selected.count < 6 else { return }
            selected.insert(id)
        } else { selected.remove(id) }
        verified = false
    }
    var canSave: Bool { verified && (2...6).contains(selected.count) && (!existing.isEmpty || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var guidance: String {
        if selected.count < 2 { return "Ascolta e seleziona almeno 2 campioni." }
        if existing.isEmpty && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Inserisci il nome della persona." }
        if !verified { return "Conferma che i campioni selezionati appartengono alla stessa persona." }
        return selected.count == 6 ? "Limite di 6 campioni raggiunto. Deselezionane uno per sostituirlo." : "Campioni pronti per il salvataggio."
    }
}

struct VoiceEnrollmentView: View {
    @EnvironmentObject var model: AppModel
    let request: VoiceEnrollmentRequest
    @StateObject private var draft: VoiceEnrollmentDraft
    init(request: VoiceEnrollmentRequest) {
        self.request = request; _draft = StateObject(wrappedValue: VoiceEnrollmentDraft(name: request.initialName))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ricorda questa voce", systemImage: "person.wave.2").font(.title2).fontWeight(.semibold)
            Text("Ascolta e seleziona da 2 a 6 passaggi con una sola persona. Evita musica, voci sovrapposte e rientri dagli altoparlanti.").font(.callout).foregroundStyle(.secondary)
            VoiceProfileChooser(profiles:model.voiceProfiles,selection:$draft.existing,allowsNew:true)
            if draft.existing.isEmpty { TextField("Nome della persona", text: $draft.name).textFieldStyle(.roundedBorder) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(request.clips) { clip in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("Seleziona", isOn: Binding(get: { draft.selected.contains(clip.id) }, set: { value in
                                draft.select(clip.id, value)
                            })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || !draft.listened.contains(clip.id) || (!draft.selected.contains(clip.id) && (model.voiceClipQualities[clip.id]?.usable == false || draft.selected.count >= 6)))
                            VStack(alignment: .leading, spacing: 4) {
                                VoiceClipQualityLabel(quality: model.voiceClipQualities[clip.id])
                                Text("\(timecode(clip.start)) – \(timecode(clip.end)) · \(clip.source.label)").font(.caption).monospacedDigit()
                                Text(clip.text).font(.callout).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(draft.listened.contains(clip.id) ? "Riascolta" : "Ascolta", systemImage: "play.fill") {
                                Task { if await model.listenVoice(clip, meeting: request.meeting) { draft.listened.insert(clip.id) } }
                            }
                        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(height: 230)
            Text("L’indicatore valuta volume, pause e saturazione; non certifica assenza di rumore o altre voci. La tua conferma prevale sulle differenze rilevate dal modello.").font(.caption).foregroundStyle(.secondary)
            Text(draft.guidance).font(.caption).foregroundStyle(.secondary)
            Text(request.speakerGroupID != nil ? "Il nome verrà assegnato a tutti i passaggi di questo interlocutore nella riunione." : request.segment.speakerID.map { "Il nome verrà assegnato ai passaggi di «\($0)» in questa riunione." } ?? "Il nome verrà assegnato solo a questo passaggio: gli altri non hanno ancora un interlocutore distinto.").font(.caption).foregroundStyle(.secondary)
            Toggle("Ho verificato che tutti i campioni selezionati sono della stessa persona", isOn: $draft.verified).toggleStyle(.checkbox)
            Toggle("Riconosci i profili salvati al termine delle prossime registrazioni", isOn: $draft.automatic).toggleStyle(.checkbox)
            Text("Il profilo resta su questo Mac. Si salvano caratteristiche della voce, senza copiare l’audio nel profilo. Il riconoscimento può sbagliare e non aggiorna i profili automaticamente.").font(.caption).foregroundStyle(.secondary)
            if model.voiceBusy { HStack { ProgressView().controlSize(.small); Text(model.voiceProgress).font(.callout); Spacer(); Button("Annulla analisi") { model.cancelVoiceAnalysis() } } }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("\(draft.selected.count) di 6 campioni selezionati").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annulla") { model.stopVoicePlayback(); model.voiceEnrollment = nil }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Salva profilo") { model.saveVoiceEnrollment(request, name: draft.name, existing: UUID(uuidString: draft.existing), selected: draft.selected, enableAutomatic: draft.automatic) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave || model.busy)
            }
        }.padding(24).frame(width: 650).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(model.busy)
            .onDisappear { model.stopVoicePlayback(); model.cancelVoiceQuality() }
    }
}

struct VoiceProfilesSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Riconoscimento delle voci").font(.headline)
                    Toggle("Riconosci i profili al termine delle registrazioni", isOn: $model.automaticVoices).toggleStyle(.checkbox).disabled(model.sessionLocked)
                    Text("Il nome viene assegnato solo quando più campioni concordano con sufficiente margine. Le corrispondenze dubbie restano proposte da confermare nella trascrizione.").font(.callout).foregroundStyle(.secondary)
                    if !model.voiceModelsReady {
                        HStack { Text("Servono i modelli opzionali Interlocutori e Profili vocali.").font(.callout); Spacer(); Button("Prepara modelli…") { model.tab = "models" } }
                    }
                }
            }
            if model.voiceStore == nil {
                Text("Archivio profili non disponibile. Consulta il messaggio di errore prima di creare nuovi profili.").foregroundStyle(.red)
            } else if model.voiceProfiles.isEmpty {
                ContentUnavailableView("Nessuna voce salvata", systemImage: "person.wave.2", description: Text("Apri una riunione con audio conservato e scegli «Ricorda questa voce» dal menu di un passaggio della trascrizione."))
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(model.voiceProfiles) { profile in VoiceProfileRow(profile: profile).environmentObject(model) }
            }
            Text("I profili sono separati dai file esportati e restano sul Mac. Rinomina, disattiva o elimina un profilo qui; i nomi già assegnati alle riunioni rimangono invariati. Per aggiungere campioni usa «Ricorda questa voce» e scegli un profilo esistente.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
private final class VoiceProfileDraft: ObservableObject {
    @Published var name: String
    init(_ name: String) { self.name = name }
}
private struct VoiceProfileRow: View {
    @EnvironmentObject var model: AppModel
    let profile: VoiceProfile
    @StateObject private var draft: VoiceProfileDraft
    init(profile: VoiceProfile) { self.profile = profile; _draft = StateObject(wrappedValue: VoiceProfileDraft(profile.name)) }
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(Palette.accent)
                    TextField("Nome", text: $draft.name).textFieldStyle(.roundedBorder)
                    Button("Rinomina") { model.updateVoiceProfile(profile.id, name: draft.name) }.disabled(draft.name == profile.name)
                    Toggle("Attivo", isOn: Binding(get: { profile.enabled }, set: { model.updateVoiceProfile(profile.id, enabled: $0) })).toggleStyle(.checkbox)
                    Button(role: .destructive) { model.updateVoiceProfile(profile.id, remove: true) } label: { Image(systemName: "trash") }.help("Elimina profilo").accessibilityLabel("Elimina profilo \(profile.name)")
                }
                if profile.needsMatchConfirmation { Label("Campioni variabili per il modello · riconoscimenti da confermare", systemImage: "person.crop.circle.badge.questionmark").font(.caption).foregroundStyle(.orange) }
                Text("\(profile.samples.count) campioni · creato il \(profile.created.formatted(date: .abbreviated, time: .omitted)) · modello legato al profilo").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.sessionLocked)
        }
    }
}

struct VoiceSuggestionsView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    private var matches: [VoiceMatch] {
        let pending = (meeting.voiceMatches ?? []).filter { $0.state == .automatic || $0.state == .suggested }
        var seen = Set<UUID>()
        return pending.filter { seen.insert($0.profileID).inserted }
    }
    var body: some View {
        if !matches.isEmpty {
            DisclosureGroup("Voci riconosciute o da verificare · \(matches.count)", isExpanded: $model.voiceMatchesExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(matches) { match in
                            HStack {
                                Label(match.name, systemImage: "person.crop.circle")
                                Text(match.state == .automatic ? "Nome automatico" : "Possibile corrispondenza").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Conferma") { model.confirmVoice(match.profileID) }
                                Button("Non è questa persona") { model.rejectVoice(match.profileID) }
                            }
                        }
                    }.padding(.vertical, 8).padding(.trailing, 6).disabled(model.voiceDecisionLocked)
                }.frame(height: min(140, CGFloat(matches.count * 36 + 16)))
            }.font(.callout)
        }
    }
}

private struct VoiceClipQualityLabel: View {
    let quality: VoiceClipQuality?
    var body: some View {
        if let quality {
            Label(quality.label, systemImage: quality.grade == .recommended ? "checkmark.circle" : quality.grade == .review ? "exclamationmark.circle" : "minus.circle")
                .font(.caption).foregroundStyle(quality.grade == .recommended ? Color.green : quality.grade == .review ? Color.orange : Color.secondary)
            Text(quality.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        } else { Text("Valutazione del segnale…").font(.caption).foregroundStyle(.secondary) }
    }
}
