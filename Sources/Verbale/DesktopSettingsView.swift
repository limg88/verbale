import SwiftUI
import AppKit
import VerbaleCore

struct DesktopSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Categoria impostazioni", selection: $model.settingsSection) {
                Text("Registrazione").tag("recording")
                Text("Report").tag("reports")
                Text("Voci").tag("voices")
                Text("Avanzate").tag("advanced")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 540)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.settingsSection {
                    case "voices": VoiceProfilesSettings()
                    case "reports": reports
                    case "advanced": advanced
                    default: recording
                    }
                }.task { await model.refreshAudioRouting() }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var recording: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Salvataggio").font(.headline)
                    HStack {
                        Text(model.destination?.path ?? "Nessuna cartella selezionata").font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Cambia cartella…") { model.chooseDestination() }.disabled(model.sessionLocked)
                    }
                    Toggle("Conserva anche l’audio", isOn: $model.keepAudio).toggleStyle(.checkbox).disabled(model.sessionLocked)
                    Picker("Trascrizione", selection: $model.transcriptionTiming) {
                        ForEach(TranscriptionTiming.allCases) { Text($0.label).tag($0) }
                    }.disabled(model.sessionLocked)
                    Text("Al termine: durante la call viene salvato l’audio; testo e interlocutori vengono elaborati dopo Stop. Se Teams è ancora in chiamata, l’attesa è visibile e la trascrizione riparte in background al termine della call. Durante la registrazione: il testo appare in diretta, con maggiori consumi.").font(.callout).foregroundStyle(.secondary)
                    Text("L’audio viene salvato sul Mac man mano. La cartella di output viene aggiornata ogni 30 secondi e al termine.").font(.callout).foregroundStyle(.secondary)
                    Text("Le preferenze valgono per le prossime registrazioni.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Teams").font(.headline)
                    Toggle("Registra automaticamente le chiamate Teams", isOn: $model.teamsAutoEnabled).toggleStyle(.checkbox)
                    Text(model.teamsStatus).font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Comportamento e condivisione schermo") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Verbale deve essere aperto. Alla chiamata passa alla barra dei menu; termina dopo 20 secondi senza chiamata. Se la interrompi, non riparte nella stessa chiamata.")
                            Text("Completa una prima registrazione manuale per verificare cartella, modelli e permessi. Disattivare questa opzione termina la registrazione automatica in corso.")
                            Text("Condividendo tutto lo schermo, l’icona nella barra dei menu e gli indicatori macOS possono comparire. L’esclusione dalla cattura non è garantita.")
                            Button("Mostra solo nella barra dei menu") { model.enterQuietMode() }
                        }.font(.callout).foregroundStyle(.secondary).padding(.top, 10)
                    }.font(.callout)
                }
            }
            Surface {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("Trascrizione sul Mac").font(.headline); Text("Italiano e inglese · modelli e licenze").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Gestisci modelli…") { model.tab = "models" }
                }
            }
        }
    }
    private var reports: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Servizio report").font(.headline); Spacer(); Button("Avvia gateway") { model.launchGateway() } }
                    GatewayModelPicker().frame(maxWidth: 500)
                    if !model.gatewayStatus.isEmpty { Text(model.gatewayStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("Genera i report dalla scheda Report della riunione. Il testo viene inviato al modello scelto tramite il gateway locale; audio e immagini restano sul Mac.").font(.callout).foregroundStyle(.secondary)
                    Text("Il gateway può servire altre app. Per arrestarlo usa Ctrl-C nella sua finestra Terminale.").font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Connessione e credenziali") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("URL del gateway", text: $model.gatewayEndpoint).textFieldStyle(.roundedBorder)
                            TextField("Cartella gateway", text: $model.gatewayProject).textFieldStyle(.roundedBorder)
                            HStack {
                                SecureField("Token locale del gateway", text: $model.gatewayToken).textFieldStyle(.roundedBorder)
                                Button("Importa token locale") { model.importGatewayToken() }
                            }
                            HStack { Button("Verifica e aggiorna modelli") { Task { await model.checkGateway() } }.disabled(model.checkingGateway); Button("Apri cartella") { model.openGatewayFolder() } }
                            Text("La verifica non usa modelli o quote. Credenziali dei provider e alias locali si configurano nel gateway.").font(.callout).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }.font(.callout)
                }.disabled(model.reportBusy)
            }
        }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Dispositivi audio").font(.headline)
                    Picker("Ascolto", selection: $model.listeningMode) { ForEach(ListeningMode.allCases) { Text($0.label).tag($0) } }.disabled(model.sessionLocked)
                    Picker("Microfono",selection:$model.inputChoice) {
                        Text("Automatico · dispositivo Teams").tag(AudioRouteSelection.automatic)
                        Text("Predefinito del Mac").tag(AudioRouteSelection.macDefault)
                        ForEach(model.routeInputs) { Text($0.name).tag($0.choice) }
                        if model.routeChoiceMissing(model.inputChoice,input:true) { Text("Dispositivo manuale non disponibile").tag(model.inputChoice) }
                    }.disabled(model.busy)
                    Text(model.routeDescription(input:true)).font(.caption).foregroundStyle(.secondary)
                    Picker("Uscita audio",selection:$model.outputChoice) {
                        Text("Automatico · dispositivo Teams").tag(AudioRouteSelection.automatic)
                        Text("Predefinita del Mac").tag(AudioRouteSelection.macDefault)
                        ForEach(model.routeOutputs) { Text($0.name).tag($0.choice) }
                        if model.routeChoiceMissing(model.outputChoice,input:false) { Text("Dispositivo manuale non disponibile").tag(model.outputChoice) }
                    }.disabled(model.busy)
                    Text(model.routeDescription(input:false)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Aggiorna rilevamento") { Task { await model.refreshAudioRouting() } }.disabled(model.routingRefreshing)
                        if model.routingRefreshing { ProgressView().controlSize(.small) }
                    }
                    if !model.routingStatus.isEmpty { Text(model.routingStatus).font(.caption).foregroundStyle(.orange) }
                    if model.isRecording,let route = model.recording?.latestAudioRoute {
                        Text("In questa registrazione: "+[route.inputName.map { "microfono "+$0 },route.outputName.map { "uscita "+$0 }].compactMap { $0 }.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                        Text("Le modifiche ai dispositivi si applicano alla prossima registrazione.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Automatico segue i dispositivi rilevati da Teams. All’avvio, se la scelta non è univoca, usa i predefiniti del Mac.").font(.callout).foregroundStyle(.secondary)
                    Text("Con gli altoparlanti, scegli la modalità di riduzione eco: richiede microfono e audio di sistema attivi. Le sorgenti da registrare e la modalità di ascolto restano quelle che hai scelto.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Audio interno").font(.headline)
                    Toggle("Conserva una copia interna per rielaborare", isOn: $model.keepRecovery).toggleStyle(.checkbox).disabled(model.sessionLocked)
                    Text("Dopo il salvataggio riuscito, i temporanei vengono eliminati se questa opzione è disattivata. In caso di errore la copia di recupero rimane disponibile.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Surface {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Widget").font(.headline)
                    Toggle("Sempre in primo piano", isOn: $model.widgetPinned).toggleStyle(.checkbox)
                    Text("Aprilo dalla barra laterale o con ⇧⌘M.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
