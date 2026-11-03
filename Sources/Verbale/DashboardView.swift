import SwiftUI
import AppKit
import VerbaleCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    private var pageTitle: String {
        switch model.tab { case "archive": return "Le tue conversazioni"; case "models": return "Intelligenza, sul tuo Mac"; case "settings": return "Il tuo modo di lavorare"; default: return "Il tuo spazio di ascolto" }
    }
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 235, ideal: 245, max: 270)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("WORKSPACE").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(.secondary); Text(pageTitle).font(.system(size: 23, weight: .bold, design: .rounded)) }
                    Spacer()
                    Button { model.showWidget() } label: { Label("Widget", systemImage: "rectangle.inset.filled") }.controlSize(.large)
                    Button { model.newMeeting() } label: { Label("Nuova riunione", systemImage: "plus") }.controlSize(.large).disabled(model.sessionLocked)
                }.padding(.horizontal, 28).padding(.vertical, 22)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch model.tab { case "archive": archive; case "models": models; case "settings": settings; default: session }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.background(LinearGradient(colors: [Palette.accent.opacity(0.025), Color(nsColor: .windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .alert("Verbale", isPresented: Binding(get: { model.error != nil && !model.quietMode }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 11) {
                Image(systemName: "waveform").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white).frame(width: 45, height: 45).background(Palette.hero, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 2) { Text("Verbale").font(.system(size: 24, weight: .bold, design: .rounded)); Text("Dalle parole alle idee.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.top, 14)
            VStack(spacing: 7) {
                navigation("session", "Riunione", "waveform")
                navigation("archive", "Archivio", "tray.full")
                navigation("models", "Modelli locali", "cpu")
                navigation("settings", "Impostazioni", "slider.horizontal.3")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("A PORTATA DI MANO").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                Button { model.showWidget() } label: {
                    HStack(spacing: 10) { Image(systemName: "rectangle.inset.filled").foregroundStyle(Palette.accent); VStack(alignment: .leading, spacing: 3) { Text("Mini widget").font(.system(size: 12, weight: .semibold)); Text("Più spazio al tuo lavoro").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }.padding(12)
                }.buttonStyle(.plain).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            if !model.meetings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECENTI").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                    ForEach(Array(model.meetings.prefix(3))) { meeting in
                        Button { model.open(meeting) } label: { HStack(spacing: 8) { Image(systemName: "text.alignleft").foregroundStyle(.secondary); Text(meeting.title).lineLimit(1).font(.system(size: 11)); Spacer() } }.buttonStyle(.plain).disabled(model.sessionLocked)
                    }
                }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 10) {
                Label("Le conversazioni restano tue", systemImage: "lock.shield").font(.system(size: 11, weight: .medium))
                Text("Trascrizione locale · Italiano e inglese").font(.system(size: 10)).foregroundStyle(.secondary)
                StatePill(text: model.installed.isSuperset(of: ["asr", "vad"]) ? "Modelli pronti" : "Da preparare", color: model.installed.isSuperset(of: ["asr", "vad"]) ? Palette.mint : .orange)
            }
        }.padding(20).frame(maxHeight: .infinity).background(.ultraThinMaterial)
    }
    private func navigation(_ id: String, _ text: String, _ icon: String) -> some View {
        Button { model.tab = id } label: {
            HStack(spacing: 12) { Image(systemName: icon).frame(width: 20); Text(text).font(.system(size: 13, weight: model.tab == id ? .semibold : .medium)); Spacer(); if id == "session" && model.isRecording { Circle().fill(.red).frame(width: 7, height: 7) } }.padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(model.tab == id ? Palette.accent : .primary)
                .background(model.tab == id ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var session: some View {
        hero
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Label("Prepara la riunione", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold)); Spacer(); Text(model.isRecording ? "Sorgenti in ascolto" : "Scegli cosa ascoltare").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 12) {
                    SourceCard(title: "Microfono", subtitle: "La voce vicino al tuo Mac", icon: "mic.fill", enabled: $model.microphone, level: model.levels[.microphone] ?? 0, locked: model.sessionLocked)
                    SourceCard(title: "Audio di sistema", subtitle: "Chiamate, video e presentazioni", icon: "speaker.wave.2.fill", enabled: $model.system, level: model.levels[.system] ?? 0, locked: model.sessionLocked)
                }
                HStack(alignment: .top) {
                    Toggle(isOn: $model.keepAudio) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Salva anche l’audio").font(.system(size: 13, weight: .semibold))
                            Text(model.keepAudio ? "Conserva la registrazione nella cartella della riunione, per riascoltarla e rielaborarla." : "Verranno conservati testo e allegati. L’audio temporaneo sarà rimosso dopo il completamento riuscito.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.checkbox).disabled(model.sessionLocked)
                    Spacer(minLength: 10)
                    StatePill(text: model.keepAudio ? "Audio incluso" : "Solo testo", color: model.keepAudio ? Palette.mint : .secondary)
                }
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.system(size: 19)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 3) { Text("Dove salviamo le tue idee").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); Text(model.destination?.path ?? "Scegli una cartella sul tuo Mac").font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    Spacer()
                    Button("Scegli…") { model.chooseDestination() }.disabled(model.sessionLocked)
                }
                if model.system && model.microphone { Text("Ascolti dagli altoparlanti e non intervieni? Puoi usare solo Audio di sistema per evitare il rientro nel microfono.").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        if let error = model.exportError { Surface { HStack { Label(error, systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange); Spacer(); Button("Riprova") { model.exportCurrent() }; Button("Altra cartella") { model.exportElsewhere() } } } }
        if let meeting = model.current { transcript(meeting) }
        else { emptySession }
    }
    private var hero: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) { Circle().fill(model.isRecording ? Color.red : Palette.mint).frame(width: 6, height: 6); Text(model.isRecording ? "IN REGISTRAZIONE" : "UNO SPAZIO PER LE TUE CONVERSAZIONI").font(.system(size: 9, weight: .bold)).tracking(1.8) }.foregroundStyle(.white.opacity(0.8))
                Text(model.current?.title ?? "Ascolta. Le parole restano qui.").font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                if !model.sessionLocked && model.current == nil { TextField("Dai un titolo alla riunione…", text: $model.title).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white).padding(10).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: 340) }
                else { Text(model.status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(2) }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 12) {
                if model.isRecording { Text(timecode(model.elapsed)).font(.system(size: 32, weight: .medium, design: .monospaced)).monospacedDigit().foregroundStyle(.white) }
                if model.busy || model.working { ProgressView().controlSize(.small).colorScheme(.dark) }
                Button { Task { if model.isRecording { await model.stop() } else { await model.start() } } } label: {
                    Label(model.isRecording ? "Termina e salva" : model.busy ? "Preparazione…" : "Avvia registrazione", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).tint(model.isRecording ? Color.red : Color.white).foregroundStyle(model.isRecording ? Color.white : Palette.accent)
                    .disabled(model.busy || model.reportBusy || (!model.isRecording && (model.working || !model.installed.isSuperset(of: ["asr", "vad"]))))
                if !model.installed.isSuperset(of: ["asr", "vad"]) { Button("Prepara i modelli →") { model.tab = "models" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9)) }
            }
        }.padding(25).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading).background(Palette.hero, in: RoundedRectangle(cornerRadius: 22))
    }
    private var emptySession: some View {
        Surface {
            HStack(spacing: 20) {
                Image(systemName: "text.bubble").font(.system(size: 35, weight: .light)).foregroundStyle(Palette.accent).frame(width: 72, height: 72).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 7) { Text("Meno appunti. Più presenza.").font(.system(size: 18, weight: .semibold, design: .rounded)); Text("Durante la riunione troverai qui trascrizione e note.\nPuoi passare al widget per lasciare spazio al resto.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4) }
                Spacer()
                Button("Apri widget") { model.showWidget() }
            }.padding(.vertical, 8)
        }
    }
    private func transcript(_ meeting: Meeting) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Label("La conversazione", systemImage: "text.alignleft").font(.system(size: 16, weight: .semibold))
                    Text("\(meeting.segments.count) segmenti").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    StatePill(text: meeting.exported ? "Salvato" : "Da salvare", color: meeting.exported ? Palette.mint : .orange)
                    Button { model.reveal() } label: { Image(systemName: "folder") }.help("Apri cartella").disabled(!meeting.exported)
                    Button { Task { await model.screenshot() } } label: { Image(systemName: "camera") }.help("Screenshot").disabled(!model.isRecording)
                }
                if meeting.state == .failed || meeting.state == .interrupted { Button("Riprendi trascrizione") { Task { await model.resume() } }.disabled(model.sessionLocked) }
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if meeting.segments.isEmpty { ContentUnavailableView(model.isRecording ? "In ascolto…" : "Nessun segmento", systemImage: "waveform", description: Text("Il testo apparirà dopo i primi blocchi audio.")) }
                            ForEach(meeting.segments.sorted { $0.start < $1.start }) { segment in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(timecode(segment.start)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 5) { Text(meeting.speakerName(for: segment)).font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent); Text(segment.text).font(.system(size: 13)).textSelection(.enabled).lineSpacing(4) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.vertical, 10).padding(.trailing, 14)
                    }.frame(minWidth: 310)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Note personali", systemImage: "square.and.pencil").font(.system(size: 12, weight: .semibold))
                        TextEditor(text: Binding(get: { model.current?.notes ?? "" }, set: { model.saveNotes($0) })).font(.system(size: 12)).scrollContentBackground(.hidden).padding(6).background(Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        if !model.isRecording {
                            Button("Separa gli interlocutori") { Task { await model.separateSpeakers() } }.disabled(model.sessionLocked || !model.installed.contains("diarization") || (!meeting.keepAudio && !meeting.keepRecovery))
                            ForEach(Array(Set(meeting.segments.compactMap(\.speakerID))).sorted(), id: \.self) { id in TextField(id, text: Binding(get: { model.current?.speakers[id] ?? id }, set: { model.rename(id, to: $0) })).textFieldStyle(.roundedBorder) }
                            Button("Crea un report…") { model.tab = "settings" }
                        }
                        Label(meeting.keepAudio ? "Audio conservato nella destinazione" : "Audio non conservato per questa sessione", systemImage: meeting.keepAudio ? "waveform.badge.mic" : "text.alignleft").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.leading, 16).frame(minWidth: 210, idealWidth: 245)
                }.frame(height: 360)
            }
        }
    }

    @ViewBuilder private var archive: some View {
        HStack(spacing: 14) {
            statistic("Riunioni", value: "\(model.meetings.count)", icon: "tray.full")
            statistic("Tempo raccolto", value: timecode(model.meetings.reduce(0) { $0 + $1.duration }), icon: "clock")
            statistic("Con audio", value: "\(model.meetings.filter(\.keepAudio).count)", icon: "waveform")
        }
        if model.meetings.isEmpty { Surface { ContentUnavailableView("Le prossime idee ti aspettano", systemImage: "tray", description: Text("Le riunioni compariranno qui dopo la prima registrazione.")) } }
        ForEach(model.meetings) { meeting in
            Surface(padding: 18) {
                HStack(spacing: 16) {
                    Image(systemName: meeting.keepAudio ? "waveform" : "text.alignleft").font(.system(size: 21)).foregroundStyle(Palette.accent).frame(width: 48, height: 48).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) { Text(meeting.title).font(.system(size: 15, weight: .semibold)); Text("\(meeting.started.formatted(date: .abbreviated, time: .shortened)) · \(timecode(meeting.duration)) · \(meeting.keepAudio ? "Audio e testo" : "Solo testo")").font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    StatePill(text: stateTitle(meeting.state), color: meeting.state == .complete ? Palette.mint : .orange)
                    Button("Apri") { model.open(meeting) }.disabled(model.sessionLocked)
                    Button(role: .destructive) { model.delete(meeting) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(model.sessionLocked).help("Rimuovi copia interna")
                }
            }
        }
    }
    private func statistic(_ title: String, value: String, icon: String) -> some View {
        Surface { HStack { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); Text(value).font(.system(size: 23, weight: .bold, design: .rounded)) }; Spacer(); Image(systemName: icon).font(.title3).foregroundStyle(Palette.accent) } }
    }

    @ViewBuilder private var models: some View {
        Text("Una sola preparazione. Poi trascrivi anche senza connessione.").font(.system(size: 15)).foregroundStyle(.secondary)
        ForEach(model.models.catalog) { spec in
            Surface {
                HStack(spacing: 18) {
                    Image(systemName: spec.id == "asr" ? "text.bubble" : spec.id == "vad" ? "waveform" : "person.2").font(.system(size: 25)).foregroundStyle(Palette.accent).frame(width: 60, height: 60).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(spec.id == "asr" ? "Le parole diventano testo" : spec.id == "vad" ? "Ascolta quando serve" : "Ogni voce, il suo spazio").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text(spec.id == "asr" ? "Trascrizione multilingue · Italiano e inglese" : spec.id == "vad" ? "Rilevamento del parlato · Necessario" : "Separazione degli interlocutori · Opzionale").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(ByteCountFormatter.string(fromByteCount: spec.bytes, countStyle: .file)) · \(spec.license)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.modelWork == spec.id { ProgressView().controlSize(.small); Text("Preparazione…").font(.caption) }
                    else if model.installed.contains(spec.id) { StatePill(text: "Pronto sul Mac") }
                    else { VStack(spacing: 8) { Button("Scarica") { model.installModel(spec.id, importFile: false) }.buttonStyle(.borderedProminent); Button("Importa file…") { model.installModel(spec.id, importFile: true) }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary) } }
                }
            }.disabled(model.modelWork != nil || model.sessionLocked)
        }
        Surface { HStack(spacing: 12) { Image(systemName: "checkmark.shield").foregroundStyle(Palette.mint).font(.title2); VStack(alignment: .leading, spacing: 5) { Text("File verificati, conversazioni sul dispositivo").font(.system(size: 13, weight: .semibold)); Text("Ogni modello è controllato prima dell’uso. La lingua viene riconosciuta automaticamente.").font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer() } }
        Link("Modelli e attribuzioni ↗", destination: URL(string: "https://huggingface.co/mudler/parakeet-cpp-gguf")!).font(.caption)
    }

    @ViewBuilder private var settings: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                Label("Chiamate Teams, in automatico", systemImage: "app.connected.to.app.below.fill").font(.system(size: 16, weight: .semibold))
                Toggle("Registra automaticamente tutte le chiamate Teams desktop", isOn: $model.teamsAutoEnabled).toggleStyle(.checkbox)
                Text(model.teamsStatus).font(.callout).foregroundStyle(Palette.accent)
                Text("Verbale deve essere aperto. Quando rileva una chiamata, chiude finestra e widget e resta nella barra dei menu, senza icona nel Dock. Termina dopo 20 secondi senza chiamata; se la interrompi tu, non riparte nella stessa chiamata. Disattivare questa opzione termina la registrazione automatica in corso.").font(.caption).foregroundStyle(.secondary)
                Text("Prepara modelli, cartella e permessi con una prima registrazione manuale. Le sorgenti e i dispositivi selezionati vengono ricordati. Il rilevamento usa un segnale locale di Teams, che può cambiare tra versioni; non richiede Accessibilità.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Condivisione schermo: nessuna finestra viene aperta automaticamente. L’icona nella barra dei menu, i menu aperti e gli indicatori macOS possono comparire quando condividi tutto lo schermo; non è garantita l’esclusione dalla cattura.").font(.caption).foregroundStyle(.secondary)
                Button("Riduci alla sola barra dei menu") { model.enterQuietMode() }
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                Label("Audio e ascolto", systemImage: "headphones").font(.system(size: 16, weight: .semibold))
                Picker("Microfono", selection: $model.inputID) { Text("Predefinito del Mac").tag(UInt32(0)); ForEach(model.inputs) { Text($0.name).tag($0.id) } }
                Picker("Uscita da acquisire", selection: $model.outputID) { Text("Predefinita del Mac").tag(UInt32(0)); ForEach(model.outputs) { Text($0.name).tag($0.id) } }
                Button("Aggiorna dispositivi") { model.inputs = Devices.list(input: true); model.outputs = Devices.list(input: false) }
                Text("Per parlare mentre ascolti, le cuffie riducono il rientro degli altoparlanti nel microfono.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.sessionLocked)
        }
        Surface {
            VStack(alignment: .leading, spacing: 17) {
                Label("I tuoi file", systemImage: "folder").font(.system(size: 16, weight: .semibold))
                Toggle("Salva anche l’audio nella cartella della riunione", isOn: $model.keepAudio).toggleStyle(.checkbox).disabled(model.sessionLocked)
                Text("Attivo di default. Puoi togliere la spunta: la preferenza viene ricordata per le prossime registrazioni.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Conserva anche la copia audio interna per rielaborazione", isOn: $model.keepRecovery).toggleStyle(.checkbox).disabled(model.sessionLocked)
                Text("La copia di recupero rimane sempre disponibile in caso di errore. Dopo un salvataggio riuscito, i temporanei vengono rimossi se questa opzione non è attiva.").font(.caption).foregroundStyle(.secondary)
                HStack { Text(model.destination?.path ?? "Nessuna cartella selezionata").font(.caption).textSelection(.enabled); Spacer(); Button("Scegli cartella…") { model.chooseDestination() }.disabled(model.sessionLocked) }
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 17) {
                HStack { Label("Un controllo sempre vicino", systemImage: "rectangle.inset.filled").font(.system(size: 16, weight: .semibold)); Spacer(); Button("Apri widget") { model.showWidget() } }
                Toggle("Widget sempre in primo piano", isOn: $model.widgetPinned).toggleStyle(.checkbox)
                Text("Finestra compatta e spostabile con timer, livelli audio e controlli di registrazione. Si apre anche con ⇧⌘M.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Surface {
            VStack(alignment: .leading, spacing: 17) {
                Label("Dalla conversazione al report", systemImage: "sparkles").font(.system(size: 16, weight: .semibold))
                Text("Opzionale: la trascrizione funziona anche senza un servizio per i report.").font(.caption).foregroundStyle(.secondary)
                TextField("Endpoint base, es. http://localhost:1234/v1", text: $model.endpoint).textFieldStyle(.roundedBorder)
                TextField("Nome del modello", text: $model.reportModel).textFieldStyle(.roundedBorder)
                SecureField("Chiave API · salvata nel Portachiavi", text: $model.apiKey).textFieldStyle(.roundedBorder)
                Text("Con Genera report invii solo la trascrizione della riunione aperta all’endpoint scelto. Audio e immagini restano sul Mac.").font(.caption).foregroundStyle(.secondary)
                HStack { Button(model.reportBusy ? "Creazione in corso…" : "Genera report") { Task { await model.report() } }.buttonStyle(.borderedProminent).disabled(model.current == nil || model.isRecording || model.busy || model.working || model.reportBusy); if model.reportBusy { ProgressView().controlSize(.small) } }
                if let report = model.current?.report { Divider(); Text(report).font(.callout).textSelection(.enabled) }
            }
        }
    }
}
