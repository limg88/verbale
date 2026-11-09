import SwiftUI
import AppKit
import Combine
import VerbaleCore

@main struct VerbaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            Text(model.status)
            if model.isRecording { Text("In registrazione · " + timecode(model.elapsed)) }
            if model.isRecording && model.recording?.usesEchoCancellation == true { Text("Altoparlanti · riduzione eco") }
            if model.teamsAutoEnabled { Text(model.teamsStatus) }
            if model.workJobs.contains(where:{$0.state.pending}) { Text("Attività in coda o in corso: \(model.workJobs.filter{$0.state.pending}.count)") }
            if model.waitingTranscriptionID != nil { Text("Trascrizione in attesa della fine della chiamata Teams") }
            if let error = model.captureWarning ?? model.exportError ?? model.error {
                Text("Attenzione: " + error)
                Button("Apri dettagli") { model.showMainWindow() }
            }
            Divider()
            Button("Mostra Verbale") { model.showMainWindow() }
            Button(model.isRecording ? "Termina registrazione" : "Avvia registrazione") {
                Task { if model.isRecording { await model.stop() } else { await model.start() } }
            }.disabled(model.busy || model.reportBusy || (!model.isRecording && (model.working || model.voiceEnrollment != nil || model.auditReviewVisible || model.refinementVisible)))
            Toggle("Registrazione automatica Teams", isOn: $model.teamsAutoEnabled)
            Button("Riduci alla barra dei menu") { model.enterQuietMode() }
            Button("Mostra widget") { model.showWidget() }
            Button("Screenshot") { Task { await model.screenshot() } }.disabled(!model.isRecording)
            Menu("Segna momento") {
                ForEach(MarkerKind.allCases) { kind in
                    Button(kind.label) { model.addMarker(kind) }
                }
            }.disabled(!model.isRecording || model.busy)
            Divider()
            Button("Esci da Verbale") { NSApp.terminate(nil) }.disabled(model.busy || model.working || model.reportBusy || model.archiveBusy)
        } label: {
            Image(systemName: model.error != nil || model.exportError != nil ? "exclamationmark.square" : model.isRecording ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .accessibilityLabel(model.isRecording ? "Verbale · registrazione in corso" : "Verbale")
                .help(model.isRecording ? "Verbale · registrazione in corso" : "Verbale · " + model.teamsStatus)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Termina riunione" : "Avvia riunione") {
                    Task { if model.isRecording { await model.stop() } else { await model.start() } }
                }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy || model.reportBusy || (!model.isRecording && (model.working || model.voiceEnrollment != nil || model.auditReviewVisible || model.refinementVisible)))
                Button("Mostra widget") { model.showWidget() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Screenshot della riunione") { Task { await model.screenshot() } }.keyboardShortcut("2", modifiers: [.command, .shift]).disabled(!model.isRecording)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Esci da Verbale") { NSApp.terminate(nil) }.keyboardShortcut("q").disabled(model.busy || model.working || model.reportBusy || model.archiveBusy)
            }
        }
    }
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel { AppModel.shared }
    private var terminationPending = false
    private var mayTerminate = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "VerbalePreviewDataRoot") != nil,
           CommandLine.arguments.contains("--check-background-ui") {
            Task { await checkBackgroundUI() }
            return
        }
        model.configureTeamsAutomation()
        if model.teamsAutoEnabled { model.enterQuietMode() }
        else { model.showMainWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Activation/reopen events must never surface a window in quiet mode.
        // The status menu remains the explicit route back to the dashboard.
        if !model.quietMode { model.showMainWindow() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Available only in the isolated preview bundle; never starts capture or detection.
    private func checkBackgroundUI() async {
        var checks: [String: Bool] = [:]
        do { checks.merge(try await model.checkDeferredRecording()) { _,new in new } }
        catch { checks["deferred recording checks complete"] = false }
        do { checks.merge(try await model.checkWaitingResume()) { _,new in new } }
        catch { checks["waiting resume checks complete"] = false }
        let savedListeningMode = model.listeningMode
        defer { model.listeningMode = savedListeningMode }
        model.listeningMode = .speakers
        checks["speaker mode preference persists"] = ListeningMode.saved() == .speakers
        var audioMeeting = Meeting(title: "AEC check", sources: [.microphone, .system], destination: FileManager.default.temporaryDirectory, keepAudio: true)
        audioMeeting.listeningMode = model.listeningMode
        checks["speaker mode requires both sources"] = audioMeeting.usesEchoCancellation
        audioMeeting.sources = [.microphone]
        checks["single source bypasses echo cancellation"] = !audioMeeting.usesEchoCancellation
        do {
            var reference = AudioReference(count: 160)
            reference.covered = [UInt8](repeating: 1, count: 160)
            let result = try await model.echoCancellation.clean(microphone: [Float](repeating: 0, count: 160), reference: reference)
            checks["bundled AEC runtime loads and processes"] = result.count == 160 && result.allSatisfy { $0.isFinite }
        } catch { checks["bundled AEC runtime loads and processes"] = false }
        model.showMainWindow()
        checks["dashboard opens explicitly"] = NSApp.windows.contains { $0 is MainWindow && $0.isVisible }
        model.showWidget()
        checks["widget opens explicitly"] = model.widgetVisible
        model.enterQuietMode()
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        try? await Task.sleep(for: .milliseconds(300))
        checks["no dashboard or widget after quiet and reopen"] = !NSApp.windows.contains { ($0 is MainWindow || $0 is WidgetPanel) && $0.isVisible }
        checks["no Dock icon in quiet mode"] = NSApp.activationPolicy() == .accessory
        checks["no recording during checks"] = !model.isRecording
        model.showMainWindow()
        checks["dashboard reopens explicitly"] = NSApp.windows.contains { $0 is MainWindow && $0.isVisible } && !model.quietMode
        if let root = Bundle.main.object(forInfoDictionaryKey: "VerbalePreviewDataRoot") as? String {
            let folder = URL(fileURLWithPath: root).appendingPathComponent("ReviewChecks")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var meeting = Meeting(title: "Pianificazione settimanale · demo", sources: [.system], destination: folder, keepAudio: false)
                let segment = Segment(source: .system, start: 12, end: 18, text: "Rivediamo la proposta lunedì.", speakerID: "1")
                meeting.state = .complete; meeting.duration = 620; meeting.segments = [segment]; meeting.speakers = ["1": "Anna", "2": "Luca"]
                let demoLines = ["Ho raccolto i feedback del team. Le priorità sono la ricerca e il report della riunione.", "Partiamo dalla ricerca: deve trovare anche le parole nella trascrizione.", "D’accordo. Per il report teniamo visibili le decisioni e le prossime azioni.", "Preparo una proposta e la condivido con il gruppo entro venerdì.", "Verifichiamo anche la leggibilità su uno schermo più piccolo.", "Sì, poi facciamo una prova con una registrazione lunga.", "Resta da scegliere il modello del report per il test finale.", "Confrontiamo due risultati sulla stessa riunione, usando i rimandi alle fonti."]
                meeting.segments += demoLines.enumerated().map { index, text in Segment(source: .system, start: Double(25 + index * 42), end: Double(44 + index * 42), text: text, speakerID: index.isMultiple(of: 2) ? "2" : "1") }
                meeting.notes = "Appunto personale: preparare una proposta alternativa."
                try meeting.addMarker(.important, at: 14)
                meeting.report = ReportService.resolveReferences("## Sintesi\nIl gruppo ha discusso ricerca nell’archivio e leggibilità dei report. [[S2]]\n\n## Decisioni\n- La ricerca deve includere il testo della trascrizione. [[S3]]\n- Il report deve evidenziare decisioni e prossime azioni. [[S4]]\n\n## Attività e responsabilità\n| Attività | Responsabile | Scadenza | Stato e dipendenze | Fonti |\n| --- | --- | --- | --- | --- |\n| Preparare la proposta | Da assegnare | Venerdì | Pianificata | [[S5]] |\n| Verificare la finestra piccola | Da assegnare | Non indicata | Proposta | [[S6]] |\n\n## Rischi e problemi aperti\nNon emersi dalle fonti disponibili.\n\n## Opportunità\nNon emerse dalle fonti disponibili.\n\n## Note personali\nL’appunto dell’utente resta distinto dal parlato. [[N]]\n\nPassaggio da rivedere: [[M1]].", meeting: meeting)
                meeting.reportStatus = "Completato"
                try model.store.save(meeting); model.open(meeting)
                checks["report source opens segment"] = model.openReportSource(URL(string: "transcript.md#\(segment.anchor)")!) && model.focusedSegmentID == segment.id && model.meetingSection == "transcript"
                checks["report source opens notes"] = model.openReportSource(URL(string: "notes.md")!) && model.focusNotes && model.meetingSection == "notes"
                model.focusSpeaker("1")
                checks["speaker navigation opens first occurrence"] = model.focusedSegmentID == segment.id && model.meetingSection == "transcript"
                if let originalMeeting = model.current {
                    var aliases = originalMeeting
                    let alias = Segment(source:.system,start:1,end:3,text:"Same person with another key",speakerID:"same-person")
                    aliases.segments.append(alias); aliases.speakers["same-person"] = "Anna"; model.current = aliases
                    model.focusSpeaker("1")
                    checks["speaker navigation recognizes equal names with different keys"] = model.focusedSegmentID == alias.id
                    model.current = originalMeeting; model.focusSpeaker("1")
                }
                let wrongMeetingSave = await model.rename("1",to:"Wrong meeting",meetingID:UUID())
                await model.flushVoiceSaves()
                checks["speaker rename cannot target a different meeting"] = !wrongMeetingSave && model.current?.speakers["1"] == "Anna"
                let request = model.focusRequestID; model.focusSpeaker("1")
                checks["speaker navigation can repeat after manual scrolling"] = model.focusRequestID != request
                var appChanges = 0,meterChanges = 0
                let appObserver = model.objectWillChange.sink { appChanges += 1 }
                let meterObserver = model.audioLevels.objectWillChange.sink { meterChanges += 1 }
                for i in 0..<1000 { model.levels[.system] = Float(i % 100)/100 }
                checks["audio levels update meters without invalidating the application"] = appChanges == 0 && meterChanges == 1000
                appObserver.cancel(); meterObserver.cancel(); model.levels = [:]
                let nameDraft = SpeakerNameDraft("Anna")
                let untouched = try Data(contentsOf:model.store.workspace(meeting.id).appendingPathComponent("meeting.json"))
                for i in 0..<100 { nameDraft.text = "Nome in modifica \(i)" }
                checks["typing a speaker name performs no persistence"] = try Data(contentsOf:model.store.workspace(meeting.id).appendingPathComponent("meeting.json")) == untouched && model.current?.speakers["1"] == "Anna"
                checks["manual correction saves through coordinator"] = model.correctSegment(meetingID: meeting.id, segmentID: segment.id, text: "Rivediamo la proposta martedì.", speakerID: "1", newSpeaker: "")
                await model.flushVoiceSaves()
                let saved = try model.store.read(meeting.id)
                checks["correction history and stale report persist"] = saved.corrections.count == 1 && saved.reportNeedsUpdate && saved.exported
                model.focusNotes = false; model.meetingSection = "transcript"
                try? await Task.sleep(for: .milliseconds(300))
                if let content = NSApp.windows.first(where: { $0 is MainWindow })?.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("review-ui.png"))
                }
                // Render the real desktop views using demo data; never invoke recording or a report backend.
                if let window = NSApp.windows.first(where: { $0 is MainWindow }) {
                    window.setContentSize(NSSize(width: 1180, height: 800))
                    for section in ["transcript", "notes", "report", "archive", "settings", "recording"] {
                        model.tab = ["archive", "settings"].contains(section) ? section : "session"
                        if model.tab == "session" { model.meetingSection = section == "recording" ? "transcript" : section }
                        let savedMeeting = model.current, savedStatus = model.status
                        if section == "recording" {
                            // UI fixture only: no CaptureService start, timer or device acquisition.
                            model.current?.sources = [.microphone, .system]
                            model.isRecording = true; model.elapsed = 84; model.status = "Registrazione in corso"
                            model.levels = [.microphone: 0.25, .system: 0.65]
                        }
                        try? await Task.sleep(for: .milliseconds(350))
                        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                            content.cacheDisplay(in: content.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("desktop-" + section + ".png"))
                        }
                        if section == "recording" { model.isRecording = false; model.current = savedMeeting; model.levels = [:]; model.status = savedStatus }
                    }
                    await previewEmptyLayouts(window:window,root:URL(fileURLWithPath:root))
                    await checkSpeakerLayout(window: window, root: URL(fileURLWithPath: root), checks: &checks)
                    await checkSpeakerAuditUI(root: URL(fileURLWithPath: root), checks: &checks)
                    await checkVoiceUI(root: URL(fileURLWithPath: root), checks: &checks)
                    await checkRefinementUI(root:URL(fileURLWithPath:root),checks:&checks)
                    await checkASRBoundaryUI(root:URL(fileURLWithPath:root),checks:&checks)
                    await checkSpeakerGroupingUI(root:URL(fileURLWithPath:root),checks:&checks)
                    await checkArchiveManagementUI(root:URL(fileURLWithPath:root),checks:&checks)
                    await checkAudioRoutingUI(root:URL(fileURLWithPath:root),checks:&checks)
                    try await model.checkResponsiveEdits(root:URL(fileURLWithPath:root),checks:&checks)
                    try await model.checkProjectTrackingUI(window:window,root:URL(fileURLWithPath:root),checks:&checks)
                    window.setContentSize(NSSize(width: 1000, height: 680))
                    model.tab = "session"; model.meetingSection = "report"
                    try? await Task.sleep(for: .milliseconds(350))
                    if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("desktop-compact-report.png"))
                    }
                    do { checks.merge(try await model.checkBackgroundWork(window:window,root:URL(fileURLWithPath:root))) { _,new in new } }
                    catch { checks["background work UI checks complete"] = false }
                    do { checks.merge(try await model.checkRecordingNavigation(window:window,root:URL(fileURLWithPath:root))) { _,new in new } }
                    catch {checks["recording navigation checks complete"] = false}
                    model.newMeeting()
                    checks["new meeting resets desktop content"] = model.current == nil && model.meetingSection == "transcript"
                    try? await Task.sleep(for: .milliseconds(350))
                    if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root).appendingPathComponent("desktop-new.png"))
                    }
                }
                checks["review checks never capture audio"] = !model.isRecording
                var legacy = Meeting(title: "Verifica audit legacy", sources: [.system, .microphone], destination: folder, keepAudio: false)
                legacy.listeningMode = .speakers; legacy.state = .complete
                let text = "Esaminiamo insieme la proposta del progetto"
                let words = text.split(separator: " ").enumerated().map { i, w in Word(w: String(w), start: Double(i) * 0.4, end: Double(i + 1) * 0.4) }
                let remote = Segment(source: .system, start: 0, end: 2.4, text: text, words: words)
                let local = Segment(source: .microphone, start: 0, end: 2.4, text: text, words: words)
                let stale = UUID()
                legacy.segments = [remote]; legacy.echoDuplicates = [EchoDuplicate(original: local, systemSegments: [stale])]
                try model.store.save(legacy); model.open(legacy)
                let repaired = try model.store.read(legacy.id)
                checks["opening legacy archive repairs echo refs"] = repaired.echoDuplicates?.first?.systemSegments == [remote.id]
                checks["legacy archive retains previous refs"] = repaired.echoDuplicates?.first?.previousSystemSegments == [stale]
                let audit = try JSONCoding.decoder().decode([EchoDuplicate].self, from: Data(contentsOf: folder.appendingPathComponent(legacy.folderName).appendingPathComponent("echo-duplicates.json")))
                checks["repaired legacy audit exported"] = audit.first?.systemSegments == [remote.id]
            } catch { checks["review checks complete"] = false }
        }
        if let root = Bundle.main.object(forInfoDictionaryKey: "VerbalePreviewDataRoot") as? String,
           let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: root).appendingPathComponent("background-ui-checks.json"))
        }
        if let root = Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") as? String {
            model.showMainWindow();model.tab = "settings";model.settingsSection = "recording"
            try? await Task.sleep(for:.milliseconds(200))
            if let content = NSApp.windows.first(where:{ $0 is MainWindow })?.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:bitmap)
                try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:root).appendingPathComponent("recording-settings.png"))
            }
        }
        model.enterQuietMode()
        // Leave the validation task before asking AppKit to terminate.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    /// Visual fixtures only. No hardware, model inference, persistence or gateway.
    private func previewEmptyLayouts(window:NSWindow,root:URL) async {
        let current = model.current,tab = model.tab,section = model.meetingSection,settings = model.settingsSection
        let meetings = model.meetings,profiles = model.voiceProfiles,status = model.status
        let oldRecording = model.isRecording,oldReportBusy = model.reportBusy,oldElapsed = model.elapsed
        let oldWaiting = model.waitingTranscriptionID,oldWaitingMessage = model.waitingTranscriptionMessage
        defer {
            model.isRecording = oldRecording;model.reportBusy = oldReportBusy;model.elapsed = oldElapsed
            model.waitingTranscriptionID = oldWaiting;model.waitingTranscriptionMessage = oldWaitingMessage
            model.current = current;model.meetings = meetings;model.voiceProfiles = profiles
            model.tab = tab;model.meetingSection = section;model.settingsSection = settings;model.status = status
        }
        for size in [NSSize(width:1180,height:800),NSSize(width:1000,height:680)] {
            window.setContentSize(size)
            for variant in ["deferred","listening","processing","interrupted","waiting","report","report-progress","archive","voices"] {
                var meeting = Meeting(title:"Stati di attesa · demo",sources:[.microphone,.system],destination:root,keepAudio:true)
                meeting.transcriptionTiming = variant == "listening" ? .duringRecording:.afterRecording
                meeting.state = variant == "processing" ? .processing:variant == "interrupted" ? .interrupted:.complete
                model.current = meeting;model.meetings = [];model.voiceProfiles = []
                model.waitingTranscriptionID = variant == "waiting" ? meeting.id:nil
                model.waitingTranscriptionMessage = "Teams segnala una chiamata in corso. La trascrizione ripartirà automaticamente alla fine della call, quando questa riunione è aperta."
                model.isRecording = ["deferred","listening"].contains(variant);model.elapsed = 84
                model.reportBusy = variant == "report-progress"
                model.status = variant == "processing" ? "Trascrizione in corso…":"Registrazione in corso"
                model.tab = variant == "archive" ? "archive":variant == "voices" ? "settings":"session"
                model.meetingSection = variant.hasPrefix("report") ? "report":"transcript"
                model.settingsSection = "voices"
                try? await Task.sleep(for:.milliseconds(200))
                if let content = window.contentView,let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                    content.cacheDisplay(in:content.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("empty-\(variant)-\(Int(size.width)).png"))
                }
            }
        }
    }
    private func checkSpeakerLayout(window: NSWindow, root: URL, checks: inout [String: Bool]) async {
        let oldMeeting = model.current, oldTab = model.tab, oldSection = model.meetingSection
        let oldFrame = window.frame, oldSpeakers = model.speakersExpanded, oldMatches = model.voiceMatchesExpanded
        defer {
            model.current = oldMeeting; model.tab = oldTab; model.meetingSection = oldSection
            model.speakersExpanded = oldSpeakers; model.voiceMatchesExpanded = oldMatches
            window.setFrame(oldFrame, display: true)
        }
        var fixture = Meeting(title: "Verifica layout · 60 interlocutori", sources: [.system], destination: root, keepAudio: false)
        fixture.state = .complete; fixture.duration = 1200
        fixture.segments = (0..<60).map { i in Segment(source: .system, start: Double(i * 20), end: Double(i * 20 + 15), text: "Passaggio dimostrativo di un interlocutore della riunione.", speakerID: "Interlocutore \(i + 1)") }
        for segment in fixture.segments.prefix(30) {
            fixture.applyVoiceGroup([segment.id], ranking: VoiceRanking(profileID: UUID(), name: "Profilo di prova", score: 0.65, margin: 0.1), automatic: false)
        }
        model.current = fixture; model.tab = "session"; model.meetingSection = "transcript"
        for (name, speakers, matches) in [("speakers", true, false), ("voice matches", false, true), ("both panels", true, true)] {
            model.speakersExpanded = false; model.voiceMatchesExpanded = false
            window.setContentSize(NSSize(width: 1180, height: 800))
            try? await Task.sleep(for: .milliseconds(180))
            let baseline = window.frame
            model.speakersExpanded = speakers; model.voiceMatchesExpanded = matches
            try? await Task.sleep(for: .milliseconds(250))
            checks["expanding \(name) does not grow window"] = abs(window.frame.height - baseline.height) < 1 && window.minSize.height <= 680
            window.setContentSize(NSSize(width: 1000, height: 680))
            try? await Task.sleep(for: .milliseconds(250))
            checks["expanded \(name) can resize to compact window"] = abs((window.contentView?.bounds.height ?? 0) - 680) < 1 && window.minSize.height <= 680 && window.contentMinSize.height <= 680
            if name == "both panels", let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("desktop-expanded-speakers.png"))
            }
        }
    }

    private func checkSpeakerAuditUI(root: URL, checks: inout [String: Bool]) async {
        let oldMeeting = model.current, oldAudit = model.speakerAudit
        defer { model.auditReviewVisible = false; model.current = oldMeeting; model.speakerAudit = oldAudit }
        do {
            var meeting = Meeting(title: "Revisione dimostrativa · più di otto voci", sources: [.system], destination: root, keepAudio: false)
            meeting.state = .complete; meeting.duration = 720
            meeting.segments = (0..<36).map { i in Segment(source: .system, start: Double(i*20), end: Double(i*20+8), text: "Passaggio dimostrativo da verificare prima di cambiare il nome.", speakerID: "old-\(i % 8)") }
            for i in 0..<8 { meeting.speakers["old-\(i)"] = "Nome precedente \(i+1)" }
            let groups = (0..<12).map { SpeakerAuditGroup(label: "Voce proposta \($0+1)", clips: [VoiceClip(meetingID: meeting.id, source: .system, start: 0, end: 4, text: "Demo"), VoiceClip(meetingID: meeting.id, source: .system, start: 5, end: 9, text: "Demo")], caution: "Gruppo da verificare all’ascolto: il numero di gruppi non è il conteggio certo delle persone.") }
            let pieces = meeting.segments.enumerated().map { i, segment in SpeakerAuditPiece(originalID: segment.id, segment: segment, groupID: groups[i/3].id) }
            let audit = try SpeakerAudit(meeting: meeting, groups: groups, pieces: pieces, modelDigests: [:], warnings: ["Dati dimostrativi: nessun audio reale analizzato."])
            let quick = SpeakerAuditTriage(audit: audit, meeting: meeting)
            checks["audit quick review shows at most five distinct people"] = quick.cases.count <= 5 && Set(quick.cases.map(\.bucket)).count == quick.cases.count && !quick.cases.isEmpty
            checks["audit quick review caps examples at three"] = quick.cases.allSatisfy { !$0.examples.isEmpty && $0.examples.count <= 3 }
            let before = try JSONCoding.encoder().encode(meeting)
            try model.store.save(meeting); try audit.save(to: model.speakerAuditURL(meeting))
            var changed = meeting; changed.speakers["old-0"] = "Identità aggiornata"
            checks["outdated speaker sidecar is not reopened"] = model.loadSpeakerAudit(changed) == nil
            model.speakerAudit = audit; model.discardStaleSpeakerAudit(for:changed)
            checks["outdated speaker suggestions are removed from UI"] = model.speakerAudit == nil
            model.current = meeting; model.speakerAudit = audit; model.auditReviewVisible = true
            checks["audit review locks recording"] = model.sessionLocked && !model.readyToRecord
            checks["audit proposal presentation keeps original names"] = try JSONCoding.encoder().encode(model.current!) == before
            checks["audit sidecar loads without modifying meeting"] = model.loadSpeakerAudit(meeting)?.isCurrent(for: meeting) == true
            model.learningSummary = "2 passaggi assegnati automaticamente · 3 ancora incerti · 1 campione confermato"
            try? await Task.sleep(for: .milliseconds(350))
            if let sheet = NSApp.windows.first(where: { $0 is MainWindow })?.attachedSheet,
               let view = sheet.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("desktop-speaker-audit.png"))
                checks["audit review sheet renders"] = view.bounds.height <= 650 && view.bounds.width <= 900
            } else { checks["audit review sheet renders"] = false }
            if let item = quick.cases.first {
                model.dismissSpeakerAuditCase(item.groupID)
                checks["audit deferring a check leaves transcript untouched"] = try JSONCoding.encoder().encode(model.current!) == before
                checks["audit deferred person is not repeated in next batch"] = !SpeakerAuditTriage(audit: model.speakerAudit!, meeting: meeting).cases.contains(where: { $0.bucket == item.bucket })
                checks["audit deferred checks survive reopening"] = model.loadSpeakerAudit(meeting)?.reviewedBuckets?.contains(item.bucket) == true
                model.resetSpeakerAuditDeferrals()
                checks["audit deferred check can be reopened"] = model.loadSpeakerAudit(meeting)?.reviewedBuckets?.isEmpty == true && SpeakerAuditTriage(audit: model.speakerAudit!, meeting: meeting).cases.contains(where: { $0.bucket == item.bucket })
            }
            let first = pieces[0]
            checks["audit selection applies through coordinator"] = model.applySpeakerAudit(groupID: groups[0].id, selected: [first.id], name: "Nome confermato")
            await model.flushVoiceSaves()
            let saved = try model.store.read(meeting.id)
            checks["audit applies only explicitly selected names"] = saved.speakerName(for: saved.segments[0]) == "Nome confermato" && saved.speakerName(for: saved.segments[1]) == "Nome precedente 2"
            checks["audit can continue after partial confirmation"] = model.speakerAudit?.isCurrent(for: saved) == true && model.speakerAudit?.pending(groups[0].id).count == 2
            checks["audit confirmation becomes explicit learning evidence"] = model.speakerAudit?.manualEvidence[first.id.uuidString] == "Nome confermato" && model.speakerAudit?.automaticAssignments?.isEmpty != false
            checks["audit automatic outputs are not manual evidence"] = model.speakerAudit?.manualEvidence.count == 1
            model.auditReviewVisible = false
            let renamed = await model.rename("old-1",to:"Persona rinominata",meetingID:meeting.id)
            await model.flushVoiceSaves()
            checks["manual rename invalidates obsolete speaker proposals"] = renamed && model.speakerAudit == nil && model.loadSpeakerAudit(model.current!) == nil
            try? await Task.sleep(for: .milliseconds(250))
        } catch { checks["audit UI checks complete"] = false; print("Audit UI checks: \(error)") }
    }

    private func checkAudioRoutingUI(root:URL,checks:inout [String:Bool]) async {
        let oldSnapshot = model.audioRouteSnapshot,oldInput = model.inputChoice,oldOutput = model.outputChoice
        let oldMigration = model.routingMigrated,oldTab = model.tab,oldSection = model.settingsSection
        let oldCurrent = model.current,oldRecording = model.isRecording,oldStatus = model.routingStatus
        let microphone = model.microphone,system = model.system
        let defaults = UserDefaults.standard,storedInput = defaults.object(forKey:"captureInputChoice"),storedOutput = defaults.object(forKey:"captureOutputChoice")
        defer {
            model.audioRouteSnapshot = oldSnapshot;model.inputChoice = oldInput;model.outputChoice = oldOutput
            model.routingMigrated = oldMigration;model.tab = oldTab;model.settingsSection = oldSection
            model.current = oldCurrent;model.isRecording = oldRecording;model.routingStatus = oldStatus
            if let storedInput { defaults.set(storedInput,forKey:"captureInputChoice") } else { defaults.removeObject(forKey:"captureInputChoice") }
            if let storedOutput { defaults.set(storedOutput,forKey:"captureOutputChoice") } else { defaults.removeObject(forKey:"captureOutputChoice") }
        }
        do {
            let mac = RouteDevice(uid:"ui-mac",runtimeID:1,name:"Microfono e altoparlanti Mac",input:true,output:true)
            let headset = RouteDevice(uid:"ui-call-headset",runtimeID:2,name:"Cuffie della call",input:true,output:true)
            let snapshot = AudioRouteSnapshot(devices:[mac,headset],defaultInput:1,defaultOutput:1,teamsInput:[2],teamsOutput:[2],activeTeamsInput:[2],activeTeamsOutput:[2])
            model.routingMigrated = true;model.routingStatus = "Errore precedente";model.installAudioSnapshot(snapshot);model.inputChoice = AudioRouteSelection.automatic;model.outputChoice = AudioRouteSelection.automatic
            checks["successful device detection clears previous error"] = model.routingStatus.isEmpty
            checks["automatic routing displays actual Teams device"] = model.routeDescription(input:true).contains("Cuffie della call") && model.routeDescription(input:false).contains("Teams")
            let input = try AudioRouteSelection.resolve(model.inputChoice,input:true,snapshot:snapshot),output = try AudioRouteSelection.resolve(model.outputChoice,input:false,snapshot:snapshot)
            var recording = Meeting(title:"Dispositivi della call",sources:[.microphone,.system],destination:root,keepAudio:false)
            recording.audioRoute = RecordedAudioRoute(input:input,output:output);model.current = recording;model.isRecording = true
            model.inputChoice = mac.choice
            checks["manual device choice persists independently"] = defaults.string(forKey:"captureInputChoice") == mac.choice && model.routeDescription(input:true).contains("Scelta manuale")
            checks["device preference change preserves active recording snapshot"] = model.current?.audioRoute?.inputName == headset.name && model.isRecording
            checks["device selection never disables microphone or system sources"] = model.microphone == microphone && model.system == system
            model.tab = "settings";model.settingsSection = "advanced"
            try? await Task.sleep(for:.milliseconds(300))
            if let view = NSApp.windows.first(where: { $0 is MainWindow })?.contentView,let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("audio-routing-settings.png"))
            }
            model.inputChoice = "device:ui-disconnected"
            checks["unavailable manual device remains visible with explanation"] = model.routeChoiceMissing(model.inputChoice,input:true) && model.routeDescription(input:true).contains("non è disponibile")
        } catch { checks["audio routing UI completes"] = false;print("Audio routing UI check: \(error)") }
    }

    private func checkRefinementUI(root:URL,checks:inout [String:Bool]) async {
        let previous = model.current,oldDraft = model.refinementDraft,oldMeetings = model.meetings,oldAudit = model.speakerAudit
        let folder = root.appendingPathComponent("RefinementUI-"+UUID().uuidString)
        var meeting = Meeting(title:"Confronto del secondo passaggio",sources:[.system],destination:folder,keepAudio:false)
        defer {
            model.refinementVisible = false;model.refinementSelection = nil;model.refinementDraft = oldDraft
            model.current = previous;model.meetings = oldMeetings;model.speakerAudit = oldAudit
            try? model.store.deleteWorkspace(meeting.id);try? FileManager.default.removeItem(at:folder)
        }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            meeting.state = .complete;meeting.duration = 20
            meeting.segments = [Segment(source:.system,start:1,end:5,text:"Non approvare il cambio.",speakerID:"A"),Segment(source:.system,start:7,end:12,text:"La riunione è venerdì.",speakerID:"B")]
            meeting.speakers = ["A":"Anna","B":"Luca"]
            var draft = try TranscriptRefinement(meeting:meeting,proposals:[TranscriptProposal(segment:meeting.segments[0],candidate:"Non approvare la modifica."),TranscriptProposal(segment:meeting.segments[1],candidate:"La prossima riunione è venerdì.")])
            let group = SpeakerAuditGroup(label:"Voce",clips:[])
            let pieces = meeting.segments.map { SpeakerAuditPiece(originalID:$0.id,segment:$0,groupID:group.id) }
            let analysis = try SpeakerAudit(meeting:meeting,groups:[group],pieces:pieces,modelDigests:[:],warnings:[])
            draft.originalSpeakerAnalysis = analysis
            try model.store.save(meeting);try analysis.save(to:model.speakerAuditURL(meeting));try draft.save(to:model.refinementURL(meeting));model.open(meeting);model.showRefinement()
            checks["refinement preview loads separately and locks recording"] = model.refinementVisible && model.sessionLocked && model.current?.segments[0].text == meeting.segments[0].text
            try? await Task.sleep(for:.milliseconds(300))
            if let window = NSApp.windows.first(where: { $0.sheetParent != nil }),let view = window.contentView,let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("transcript-refinement.png"))
                checks["refinement comparison sheet has bounded dimensions"] = view.bounds.width <= 850 && view.bounds.height <= 650
            } else { checks["refinement comparison sheet has bounded dimensions"] = false }
            let id = meeting.segments[0].id
            let applied = await model.applyRefinement([id])
            checks["refinement adopts only selected passage through coordinator"] = applied && model.current?.segments[0].text == "Non approvare la modifica." && model.current?.segments[1].text == meeting.segments[1].text
            checks["refinement preserves names timestamps and report anchors"] = model.current?.segments[0].speakerID == "A" && model.current?.segments[0].start == 1 && model.current?.segments[0].id == id
            checks["refinement revision is exported beside transcript"] = FileManager.default.fileExists(atPath:folder.appendingPathComponent(meeting.folderName).appendingPathComponent("transcription-refinement.json").path)
            checks["refinement preserves current voice analysis after text approval"] = model.current.map { model.speakerAudit?.isCurrent(for:$0) == true } == true
            checks["refinement persisted revision reopens with undo"] = model.current.flatMap { model.loadRefinement($0) }?.applied.contains(id) == true
            let undone = await model.applyRefinement([],undo:true)
            checks["refinement undo restores previous voice analysis"] = model.current.map { model.speakerAudit?.isCurrent(for:$0) == true } == true
            checks["refinement undo restores original through coordinator"] = undone && model.current?.segments[0].text == meeting.segments[0].text && model.current?.corrections.isEmpty == true
            model.refinementVisible = false
            try? await Task.sleep(for:.milliseconds(200))
        } catch { checks["refinement UI completes"] = false;print("Refinement UI checks: \(error)") }
    }

    private func checkASRBoundaryUI(root:URL,checks:inout [String:Bool]) async {
        let previous = model.current, oldMeetings = model.meetings, oldSection = model.meetingSection
        let folder = root.appendingPathComponent("ASRBoundaryUI-"+UUID().uuidString)
        var fixture = Meeting(title:"Raccordo fra blocchi audio",sources:[.system],destination:folder,keepAudio:false)
        defer {
            try? model.store.deleteWorkspace(fixture.id); try? FileManager.default.removeItem(at:folder)
            model.current = previous; model.meetings = oldMeetings; model.meetingSection = oldSection
        }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let old = Segment(source:.system,start:39.66,end:40.22,text:"allenarmi",words:[Word(w:"allenarmi",start:39.66,end:40.22)])
            let incoming = Segment(source:.system,start:39.73,end:41,text:"allenarmi con Giuseppe",words:[Word(w:"allenarmi",start:39.73,end:40.29),Word(w:"con",start:40.3,end:40.5),Word(w:"Giuseppe",start:40.5,end:41)])
            let chunk = AudioChunk(source:.system,start:40,sampleCount:80000,filename:"fixture.caf")
            fixture.segments = [old]; fixture.state = .complete; fixture.duration = 45
            fixture.appendTranscription(AppModel.ownedSegments([incoming],chunk:chunk),for:chunk)
            let saved = try model.store.export(fixture); model.open(saved)
            checks["ASR ownership and reconciliation retain following text"] = model.current?.segments.last?.text == "con Giuseppe" && model.current?.segments.count == 2
            checks["ASR duplicate hypotheses remain available after reopening"] = model.current?.transcriptBoundaryEdits?.first?.original.text == incoming.text
            let kept = saved.segments.last!
            checks["ASR reconciled segment remains addressable from report"] = model.openReportSource(URL(string:"transcript.md#\(kept.anchor)")!) && model.focusedSegmentID == kept.id
            checks["ASR reconciled text remains manually editable"] = model.correctSegment(meetingID:saved.id,segmentID:kept.id,text:"con Giuseppe.",speakerID:nil,newSpeaker:"") && model.current?.transcriptBoundaryEdits?.count == 1
            await model.flushVoiceSaves()
            try? await Task.sleep(for:.milliseconds(200))
        } catch { checks["ASR boundary UI completes"] = false; print("ASR boundary UI check: \(error)") }
    }

    private func checkSpeakerGroupingUI(root:URL,checks:inout [String:Bool]) async {
        let previous = model.current, oldMeetings = model.meetings, oldAudit = model.speakerAudit
        let oldExpanded = model.speakersExpanded, oldSection = model.meetingSection
        let folder = root.appendingPathComponent("GroupedSpeakers-"+UUID().uuidString)
        var fixture = Meeting(title:"Una persona, più gruppi vocali",sources:[.system,.microphone],destination:folder,keepAudio:false)
        defer {
            try? model.store.deleteWorkspace(fixture.id); try? FileManager.default.removeItem(at:folder)
            model.current = previous; model.meetings = oldMeetings; model.speakerAudit = oldAudit
            model.speakersExpanded = oldExpanded; model.meetingSection = oldSection
        }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            fixture.state = .complete; fixture.duration = 90
            for i in 0..<6 {
                let source:AudioSource = i == 0 ? .microphone:.system
                let start = Double(i)*10, key = "group-\(i)"
                fixture.segments.append(Segment(source:source,start:start,end:start+6,text:"Intervento della stessa persona, assegnato in un momento diverso.",speakerID:key))
                fixture.speakers[key] = "Persona unica"
            }
            fixture.segments.append(Segment(source:.system,start:70,end:75,text:"Passaggio ancora da assegnare.",speakerID:"Interlocutore 2"))
            try model.store.save(fixture); model.open(fixture); model.speakersExpanded = true
            checks["speaker list groups repeated names into one row"] = model.current?.speakerGroups.count == 2 && model.current?.speakerGroups.filter { $0.name == "Persona unica" }.count == 1
            try? await Task.sleep(for:.milliseconds(250))
            if let content = NSApp.windows.first(where: { $0 is MainWindow })?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("desktop-grouped-speakers.png"))
            }
            let renamed = await model.rename("group-4",to:"Nome aggiornato",meetingID:fixture.id)
            await model.flushVoiceSaves()
            let saved = try model.store.read(fixture.id)
            checks["person rename persists across all underlying speaker slots"] = renamed && (0..<6).allSatisfy { saved.speakers["group-\($0)"] == "Nome aggiornato" } && saved.speakerGroups.count == 2
            let voiceStore = try VoiceProfileStore(directory:folder.appendingPathComponent("profiles"))
            let clip = VoiceClip(meetingID:fixture.id,source:.system,start:10,end:14,text:"Campione sintetico")
            let profile = try voiceStore.enroll(name:"Nome dal profilo",samples:[VoiceSample(clip:clip,embedding:[1,0,0]),VoiceSample(clip:VoiceClip(meetingID:fixture.id,source:.system,start:20,end:24,text:"Altro campione"),embedding:[1,0,0])],encoder:VoiceEncoderID(identity:"fixture",family:"demo",dimension:3))
            let priorStore = model.voiceStore, priorInstalled = model.installed
            model.voiceStore = voiceStore; model.installed.insert("voice")
            model.beginVoiceEnrollment(fixture.segments[4],speakerGroupID:"group-4")
            let request = model.voiceEnrollment
            checks["speaker list enrollment includes grouped sources and excludes other people"] = request?.speakerGroupID == "group-4" && Set(request?.clips.map(\.source) ?? []) == Set([AudioSource.microphone,.system]) && request?.clips.contains(where:{$0.start >= 70}) == false
            model.cancelVoiceQuality();model.voiceEnrollment = nil
            model.voiceStore = priorStore;model.installed = priorInstalled
            let applied = model.applyVoiceProfileName(profile,meetingID:fixture.id,segmentID:fixture.segments[4].id,speakerGroupID:"group-4")
            await model.flushVoiceSaves()
            let grouped = try model.store.read(fixture.id)
            checks["speaker list profile assignment covers all grouped slots and sources"] = applied && (0..<6).allSatisfy { grouped.speakers["group-\($0)"] == profile.name } && grouped.segments.last?.speakerID == "Interlocutore 2"
            // Restore the rename fixture for the existing navigation/export checks.
            _ = await model.rename("group-4",to:"Nome aggiornato",meetingID:fixture.id)
            await model.flushVoiceSaves()
            model.focusSpeaker("group-5")
            checks["grouped person navigation finds first occurrence across sources"] = model.focusedSegmentID == fixture.segments[0].id
            let text = try String(contentsOf:folder.appendingPathComponent(fixture.folderName).appendingPathComponent("transcript.md"))
            checks["grouped person rename updates all exported passages"] = !text.contains("Persona unica") && text.components(separatedBy:"**Nome aggiornato**").count == 7
        } catch { checks["speaker grouping UI completes"] = false; print("Speaker grouping UI checks: \(error)") }
    }

    private func checkArchiveManagementUI(root:URL,checks:inout [String:Bool]) async {
        let previous = model.current, oldMeetings = model.meetings, oldTitle = model.title
        let folder = root.appendingPathComponent("ArchiveUIChecks-"+UUID().uuidString)
        defer {
            model.titleEditing = nil; model.pendingRemoval = nil; model.isRecording = false
            model.current = previous; model.meetings = oldMeetings; model.title = oldTitle
            try? FileManager.default.removeItem(at:folder)
        }
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            var meeting = Meeting(title:"Riunione da rinominare",sources:[.system],destination:folder,keepAudio:false)
            meeting.state = .complete; try model.store.save(meeting)
            model.current = meeting; model.meetings = try model.store.list()
            model.editMeetingTitle(meeting)
            checks["meeting title editor opens"] = model.titleEditing?.id == meeting.id
            try? await Task.sleep(for:.milliseconds(250))
            if let window = NSApp.windows.first(where: { $0.sheetParent != nil }), let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("meeting-title-editor.png"))
            }
            let renamed = await model.renameMeetingTitle(meeting,to:"Titolo modificato")
            checks["meeting title persists without changing folder"] = renamed && model.current?.title == "Titolo modificato" && model.current?.folderName == meeting.folderName && model.titleEditing == nil
            var offline = model.current!
            offline.destination = folder.appendingPathComponent("volume-non-disponibile").path
            offline.segments = [Segment(source:.system,start:0,end:5,text:"Prova",speakerID:"persona")]
            offline.speakers["persona"] = "Prima"
            try model.store.save(offline); model.current = offline
            let nameSaved = await model.rename("persona",to:"Dopo",meetingID:offline.id)
            await model.flushVoiceSaves()
            let offlineSaved = try model.store.read(offline.id)
            checks["speaker rename remains consistent when export destination is unavailable"] = nameSaved && model.current?.speakers["persona"] == "Dopo" && offlineSaved.speakers["persona"] == "Dopo" && model.exportError != nil
            model.exportError = nil
            let live = Meeting(title:"Registrazione in corso",sources:[.system],destination:folder,keepAudio:false)
            model.current = live; model.isRecording = true
            checks["archive protects active recording but permits other meetings"] = !model.canManageMeeting(live) && model.canManageMeeting(meeting)
            model.delete(meeting)
            checks["archive removal asks for confirmation"] = model.pendingRemoval?.id == meeting.id && FileManager.default.fileExists(atPath:model.store.workspace(meeting.id).path)
            let removed = await model.removeMeeting(meeting)
            checks["archive removal preserves recording and exported files"] = removed && model.isRecording && model.current?.id == live.id && !model.meetings.contains(where:{$0.id == meeting.id}) && FileManager.default.fileExists(atPath:folder.appendingPathComponent(meeting.folderName).appendingPathComponent("transcript.md").path)
        } catch { checks["archive UI management completes"] = false; print("Archive UI checks: \(error)") }
    }

    private func checkVoiceUI(root: URL, checks: inout [String: Bool]) async {
        let oldStore = model.voiceStore, oldProfiles = model.voiceProfiles, oldInstalled = model.installed
        let oldSection = model.settingsSection, oldTab = model.tab, oldMeeting = model.current
        let folder = root.appendingPathComponent("VoiceUIChecks-" + UUID().uuidString)
        defer {
            model.voiceEnrollment = nil; model.voiceStore = oldStore; model.voiceProfiles = oldProfiles
            model.installed = oldInstalled; model.settingsSection = oldSection; model.tab = oldTab; model.current = oldMeeting
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            let store = try VoiceProfileStore(directory: folder)
            guard var meeting = oldMeeting, let segment = meeting.segments.last else { throw VerbaleError.message("Missing demo meeting") }
            let encoder = VoiceEncoderID(identity: "sha256:ui-fixture", family: "demo", dimension: 3)
            let clips = VoiceClips.candidates(meeting: meeting, speakerID: segment.speakerID, source: segment.source, maximum: 2)
            let profile = try store.enroll(name: "Voce dimostrativa", samples: clips.map { VoiceSample(clip: $0, embedding: [1,0,0]) }, encoder: encoder)
            model.voiceStore = store; model.voiceProfiles = store.profiles; model.installed.formUnion(["voice", "diarization"])
            let draft = VoiceEnrollmentDraft(name: "Demo")
            let choices = (0..<8).map { _ in UUID() }
            draft.listened = Set(choices)
            for id in choices { draft.select(id, true) }
            draft.verified = true
            checks["voice selection cannot exceed six samples"] = draft.selected.count == 6 && draft.canSave
            draft.select(choices[0], false)
            checks["changing voice selection requires reconfirmation"] = !draft.verified && !draft.canSave
            draft.select(UUID(), true)
            checks["unheard voice samples cannot be selected"] = draft.selected.count == 5
            draft.verified = true; draft.name = ""; draft.existing = profile.id.uuidString
            checks["existing voice profile does not require a new name"] = draft.canSave
            model.assignSavedVoice(profile.id, segmentID: segment.id)
            await model.flushVoiceSaves()
            let assigned = try model.store.read(meeting.id)
            checks["saved voice profile assigns name without re-enrollment"] = assigned.segments.first(where: { $0.id == segment.id }).map { assigned.speakerName(for: $0) == profile.name } == true
            checks["profile name exported in transcript"] = try String(contentsOf: URL(fileURLWithPath: assigned.destination).appendingPathComponent(assigned.folderName).appendingPathComponent("transcript.md")).contains(profile.name)
            model.current = meeting
            model.tab = "settings"; model.settingsSection = "voices"
            try? await Task.sleep(for: .milliseconds(300))
            if let view = NSApp.windows.first(where: { $0 is MainWindow })?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("desktop-voices.png"))
                checks["voice profiles settings render"] = true
            }
            model.tab = "session"; model.meetingSection = "transcript"
            var qualityMeeting = meeting
            let qualityClips = VoiceClips.candidates(meeting: meeting, speakerID: segment.speakerID, source: segment.source, selected: segment.id)
            let audioFolder = model.store.workspace(meeting.id).appendingPathComponent("audio")
            try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
            for (i, clip) in qualityClips.enumerated() {
                let count = Int((clip.end * 16000).rounded()) - Int((clip.start * 16000).rounded())
                let samples = (0..<count).map { frame -> Float in
                    let level = i == 1 ? 0.004 : 0.2
                    return Float(sin(Double(frame) * 0.08) * level)
                }
                let filename = "audio/quality-ui-\(i).caf"
                try AudioFiles.write(samples, to: model.store.workspace(meeting.id).appendingPathComponent(filename))
                qualityMeeting.chunks.append(AudioChunk(source: clip.source, start: clip.start, sampleCount: samples.count, filename: filename))
            }
            model.current = qualityMeeting
            model.beginVoiceEnrollment(segment)
            await model.voiceQualityTask?.value
            checks["voice quality indicators cover all candidate clips"] = model.voiceClipQualities.count == qualityClips.count
            checks["voice quality distinguishes regular and low levels"] = model.voiceClipQualities.values.contains(where: { $0.grade == .recommended }) && model.voiceClipQualities.values.contains(where: { $0.grade == .review })
            checks["explicit voice enrollment locks session"] = model.voiceEnrollment != nil && model.sessionLocked
            if CommandLine.arguments.contains("--hold-voice-ui") { try? await Task.sleep(for: .seconds(45)) }
            try? await Task.sleep(for: .milliseconds(350))
            if let sheet = NSApp.windows.first(where: { $0 is MainWindow })?.attachedSheet,
               let view = sheet.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("desktop-voice-enrollment.png"))
                checks["voice enrollment renders without audio inference"] = true
            } else { checks["voice enrollment renders without audio inference"] = false }
            model.voiceEnrollment = nil
            model.current = meeting
            try? await Task.sleep(for: .milliseconds(300))
            let ranking = VoiceRanking(profileID: profile.id, name: profile.name, score: 0.9, margin: 0.3)
            let id = segment.id
            if let i = meeting.segments.firstIndex(where: { $0.id == id }) { meeting.segments[i].speakerID = "Anonymous demo" }
            meeting.applyVoiceGroup([id], ranking: ranking, automatic: true)
            model.current = meeting
            model.rejectVoice(profile.id)
            checks["voice rejection updates before background export"] = model.savingVoiceMeetings.contains(meeting.id) && model.current?.voiceMatches?.first?.state == .rejected
            await model.flushVoiceSaves()
            let rejected = try model.store.read(meeting.id)
            checks["voice rejection through coordinator restores slot"] = model.current?.segments.first(where: { $0.id == id })?.speakerID == "Anonymous demo" && rejected.voiceMatches?.first?.state == .rejected
            meeting.voiceMatches = nil; meeting.segments[meeting.segments.count - 1].speakerID = "Anonymous demo"
            meeting.applyVoiceGroup([id], ranking: ranking, automatic: false); model.current = meeting
            model.confirmVoice(profile.id)
            checks["voice confirmation updates before background export"] = model.savingVoiceMeetings.contains(meeting.id) && model.current?.voiceMatches?.first?.state == .confirmed
            await model.flushVoiceSaves()
            checks["voice confirmation through coordinator persists"] = (try model.store.read(meeting.id)).voiceMatches?.first?.state == .confirmed
            meeting.voiceMatches = nil; meeting.segments[meeting.segments.count - 1].speakerID = "Anonymous demo"
            meeting.applyVoiceGroup([id], ranking: ranking, automatic: true); model.current = meeting
            await model.rename("voice-" + profile.id.uuidString, to: "Nome corretto")
            await model.flushVoiceSaves()
            checks["manual rename overrides voice recognition"] = model.current?.voiceProtectedSegments.contains(id) == true && model.current?.voiceMatches?.isEmpty == true
            meeting.voiceMatches = nil; meeting.segments[meeting.segments.count - 1].speakerID = "Anonymous demo"
            meeting.applyVoiceGroup([id], ranking: ranking, automatic: false); model.current = meeting
            try? await Task.sleep(for: .milliseconds(300))
            if let view = NSApp.windows.first(where: { $0 is MainWindow })?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("desktop-voice-suggestions.png"))
            }
        } catch { checks["voice UI checks complete"] = false; print("Voice UI check failed: \(error)") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        if terminationPending { return .terminateCancel }
        if model.busy || model.working || model.reportBusy || model.archiveBusy { return .terminateCancel }
        terminationPending = true
        model.prepareToQuit()
        Task {
            await model.flushVoiceSaves()
            guard !model.hasUnsavedEdits else {terminationPending=false;model.cancelQuitAfterSaveFailure();return}
            await model.workQueue.shutdown()
            if model.isRecording { await model.stop() }
            await model.flushVoiceSaves()
            await model.engine.unload()
            mayTerminate = true
            sender.terminate(nil)
        }
        // Avoid a nested AppKit termination loop holding the main actor while saving.
        return .terminateCancel
    }
}
