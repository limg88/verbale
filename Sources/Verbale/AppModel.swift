import SwiftUI
import AppKit
import AVFoundation
import Darwin
import VerbaleCore

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var meetings: [Meeting] = []
    @Published var archiveBusy = false
    @Published var titleEditing: Meeting?
    @Published var pendingRemoval: Meeting?
    @Published var refinementVisible = false
    @Published var refinementBusy = false
    @Published var refinementProgress = ""
    @Published var refinementDraft:TranscriptRefinement?
    var refinementSelection:Set<UUID>?
    var refinementTask:Task<Void,Never>?
    @Published var current: Meeting?
    @Published private(set) var activeRecording:Meeting?
    var recording:Meeting? {activeRecording ?? (isRecording ? current:nil)}
    var viewingRecording:Bool {isRecording && recording?.id == current?.id}
    private var previewRecordingHandoff:((Meeting) async -> Void)?
    private var previewLiveTranscriber:(([Float],AudioSource,Double) async throws -> [Segment])?
    private func installRecording(_ meeting:Meeting) {
        if let activeRecording,activeRecording.id != meeting.id {return}
        if activeRecording != nil {activeRecording=meeting}
        if current?.id==meeting.id {current=meeting}
        if let i=meetings.firstIndex(where:{$0.id==meeting.id}) {meetings[i]=meeting}
    }
    func showRecording() {if let recording {open(recording);tab="session"}}

    @Published var title = ""
    @Published var microphone = UserDefaults.standard.object(forKey: "captureMicrophone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(microphone, forKey: "captureMicrophone") }
    }
    @Published var system = UserDefaults.standard.object(forKey: "captureSystem") as? Bool ?? true {
        didSet { UserDefaults.standard.set(system, forKey: "captureSystem") }
    }
    @Published var keepAudio = RecordingPreferences.keepAudio() {
        didSet { RecordingPreferences.setKeepAudio(keepAudio) }
    }
    @Published var keepRecovery = false
    @Published var transcriptionTiming = TranscriptionTiming.saved() {
        didSet { UserDefaults.standard.set(transcriptionTiming.rawValue, forKey: "transcriptionTiming") }
    }
    var transcriptionDeferred: Bool { !((recording ?? current)?.transcriptionTiming ?? .duringRecording).allowsProcessing(isRecording:isRecording) }
    private var exportCadence = RecordingExportCadence()
    @Published var listeningMode = ListeningMode.saved() {
        didSet { UserDefaults.standard.set(listeningMode.rawValue, forKey: "listeningMode") }
    }
    @Published var inputChoice = UserDefaults.standard.string(forKey:"captureInputChoice") ?? AudioRouteSelection.automatic {
        didSet { UserDefaults.standard.set(inputChoice,forKey:"captureInputChoice") }
    }
    @Published var outputChoice = UserDefaults.standard.string(forKey:"captureOutputChoice") ?? AudioRouteSelection.automatic {
        didSet { UserDefaults.standard.set(outputChoice,forKey:"captureOutputChoice") }
    }
    @Published var audioRouteSnapshot:AudioRouteSnapshot?
    @Published var routingRefreshing = false
    @Published var routingStatus = ""
    var routingMigrated = false
    @Published var destination: URL?
    @Published var isRecording = false
    @Published var busy = false
    @Published var working = false
    @Published var reportBusy = false
    @Published var reportProgress = ""
    private var reportTask: Task<Void, Never>?
    // Reassigned every second by timers, usually with the same text: publish only real changes
    // so the whole dashboard is not re-rendered while idle.
    var status = "Scegli la destinazione e prepara i modelli." { willSet { if newValue != status { objectWillChange.send() } } }
    private var meetingExportErrors:[UUID:String] = [:]
    @Published var exportError: String?
    @Published var error: String?
    let audioLevels = AudioLevelState()
    var levels:[AudioSource:Float] {
        get { audioLevels.values }
        set { audioLevels.values = newValue }
    }
    @Published var installed: Set<String> = []
    @Published var modelWork: String?
    @Published var elapsed: Double = 0
    @Published var tab = "session"
    @Published var meetingSection = "transcript"
    @Published var settingsSection = "recording"
    @Published var speakersExpanded = false
    @Published var voiceMatchesExpanded = false
    @Published var focusedSegmentID: UUID?
    @Published var focusRequestID = UUID()
    @Published var focusNotes = false
    @Published var widgetVisible = false
    @Published var teamsAutoEnabled = UserDefaults.standard.bool(forKey: "teamsAutoEnabled") {
        didSet {
            UserDefaults.standard.set(teamsAutoEnabled, forKey: "teamsAutoEnabled")
            configureTeamsAutomation()
        }
    }
    var teamsStatus = "Automazione Teams disattivata" { willSet { if newValue != teamsStatus { objectWillChange.send() } } }
    @Published var quietMode = false
    @Published var widgetPinned = true {
        didSet { widgetPanel?.level = widgetPinned ? .floating : .normal }
    }
    @Published var gatewayEndpoint = UserDefaults.standard.string(forKey: "gatewayEndpoint") ?? LocalGateway.defaultEndpoint {
        didSet { UserDefaults.standard.set(gatewayEndpoint, forKey: "gatewayEndpoint"); gatewayModels = []; gatewayStatus = "" }
    }
    @Published var gatewayProject = UserDefaults.standard.string(forKey: "gatewayProject") ?? LocalGateway.defaultProject {
        didSet { UserDefaults.standard.set(gatewayProject, forKey: "gatewayProject"); gatewayStatus = "" }
    }
    @Published var reportStyle = ReportStyle(rawValue:UserDefaults.standard.string(forKey:"reportStyle") ?? "") ?? .operational {
        didSet { UserDefaults.standard.set(reportStyle.rawValue,forKey:"reportStyle") }
    }
    @Published var gatewayModel = UserDefaults.standard.string(forKey: "gatewayModel") ?? "claude/haiku" {
        didSet { UserDefaults.standard.set(gatewayModel, forKey: "gatewayModel") }
    }
    @Published var gatewayToken = ""
    @Published var gatewayModels: [GatewayModel] = []
    @Published var gatewayStatus = ""
    @Published var checkingGateway = false
    @Published var voiceProfiles: [VoiceProfile] = []
    @Published var voiceEnrollment: VoiceEnrollmentRequest?
    @Published var learningBusy = false
    @Published var learningSummary = ""
    @Published var speakerAudit: SpeakerAudit?
    @Published var auditReviewVisible = false
    @Published var voiceProgress = ""
    @Published var voiceClipQualities: [UUID: VoiceClipQuality] = [:]
    var voiceQualityTask: Task<Void, Never>?
    @Published var voiceBusy = false
    @Published var automaticVoices = (UserDefaults.standard.object(forKey:"automaticVoices") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(automaticVoices, forKey: "automaticVoices") }
    }
    var voiceStore: VoiceProfileStore?
    let voiceEngine = VoiceAnalysisEngine()
    var voiceTask: Task<Void, Never>?
    var voicePlayer: AVAudioPlayer?
    var voicePlaybackID = UUID()
    let projectTracker: ProjectTracker
    let store: SessionStore
    let models: ModelManager
    let engine = TranscriptionEngine()
    let echoCancellation = EchoCancellation()
    let capture = CaptureService()
    let noteDrafts = NotesDraftState()
    let workDisk:MeetingWorkDisk
    let workQueue:MeetingWorkQueue
    private var workPreviewGeneration:UUID?
    @Published var workJobs:[MeetingWorkJob] = []
    var visibleWork:[MeetingWorkJob] { workJobs.filter(\.showsBanner) }
    @Published var savingVoiceMeetings:Set<UUID> = []
    @Published var pendingWorkSubmissions:Set<UUID> = []
    private var voiceSaveSnapshots:[UUID:Meeting] = [:]
    private var voiceSaveOriginals:[UUID:Meeting] = [:]
    private var voiceSaveFailures:Set<UUID> = []
    private var voiceSaveTask:Task<Void,Never>?
    var currentWork:MeetingWorkJob? { guard let id=current?.id else{return nil};return workJobs.first{$0.meetingID==id && $0.state.pending} }
    func work(_ id:UUID,kind:MeetingWorkKind)->MeetingWorkJob? { workJobs.last{$0.meetingID==id && $0.kind==kind} }
    func workLocked(_ id:UUID)->Bool { workJobs.contains{$0.meetingID==id && $0.state.pending} || savingVoiceMeetings.contains(id) || pendingWorkSubmissions.contains(id) || noteDrafts.contains(id) }
    var navigationLocked:Bool { shuttingDown || busy || (working && !isRecording) || reportBusy || archiveBusy || titleEditing != nil || pendingRemoval != nil || voiceEnrollment != nil || auditReviewVisible || refinementVisible }
    var voiceDecisionLocked:Bool { navigationLocked || current.map{pendingWorkSubmissions.contains($0.id)} == true || current.map{meeting in workJobs.contains{$0.meetingID==meeting.id && $0.state.pending}} == true }
    func flushVoiceSaves() async { noteDrafts.flush(); if let voiceSaveTask { await voiceSaveTask.value } }
    var hasUnsavedEdits:Bool { !noteDrafts.values.isEmpty }
    func cancelQuitAfterSaveFailure() {shuttingDown=false;if Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") == nil {let call=automaticCallID,attempted=automaticAttempted;configureTeamsAutomation();automaticCallID=call;automaticAttempted=attempted};error="Ci sono modifiche non salvate. Riprova il salvataggio prima di uscire."}
    func cancelWork(_ id:UUID) { Task { await workQueue.cancel(id) } }
    func dismissWorkError(_ id:UUID) {
        Task {
            do {
                try await workQueue.dismissFailure(id)
                acceptWork(await workQueue.snapshot())
            } catch { self.error="Impossibile salvare la chiusura dell’avviso: "+error.localizedDescription }
        }
    }
    private func acceptWork(_ jobs:[MeetingWorkJob]) {
        let old=workJobs;workJobs=jobs
        let settled=jobs.filter { job in !job.state.pending && old.first(where:{$0.id==job.id})?.state.pending == true }
        guard !settled.isEmpty else{return}
        Task {
            for id in Set(settled.map(\.meetingID)) {
                guard let fresh=try? await workDisk.read(id) else{continue}
                if let i=meetings.firstIndex(where:{$0.id==id}) {meetings[i]=fresh}
                if current?.id==id {current=fresh;speakerAudit=nil;learningSummary=""}
            }
        }
    }

    func persistVoiceDecision(_ meeting:Meeting) {
        voiceSaveFailures.remove(meeting.id)
        if voiceSaveOriginals[meeting.id] == nil { voiceSaveOriginals[meeting.id]=current?.id==meeting.id ? current : meetings.first(where:{$0.id==meeting.id}) }
        if current?.id==meeting.id {current=meeting}
        if let i=meetings.firstIndex(where:{$0.id==meeting.id}) { meetings[i]=meeting }
        if current?.id==meeting.id {speakerAudit=nil;learningSummary=""}
        voiceSaveSnapshots[meeting.id]=meeting;savingVoiceMeetings.insert(meeting.id)
        guard voiceSaveTask == nil else{return}
        voiceSaveTask=Task {
            while !voiceSaveSnapshots.isEmpty {
                try? await Task.sleep(for:.milliseconds(100))
                guard let (id,snapshot)=voiceSaveSnapshots.first else{break}
                voiceSaveSnapshots.removeValue(forKey:id)
                do {
                    try await workDisk.save(snapshot)
                    voiceSaveOriginals[id]=snapshot
                    noteDrafts.saved(id,text:snapshot.notes)
                } catch {
                    let persisted=(try? await workDisk.read(id)) ?? voiceSaveOriginals[id]
                    voiceSaveSnapshots.removeValue(forKey:id)
                    if let persisted {
                        if current?.id==id {current=persisted}
                        if let i=meetings.firstIndex(where:{$0.id==id}) {meetings[i]=persisted}
                    }
                    noteDrafts.failed(id)
                    voiceSaveFailures.insert(id)
                    self.error="Modifiche non salvate per «\(snapshot.title)». Riprova la modifica: "+error.localizedDescription
                    savingVoiceMeetings.remove(id);voiceSaveOriginals.removeValue(forKey:id)
                    continue
                }
                // If another click arrived, persist its newer snapshot before
                // spending time on an obsolete export.
                if voiceSaveSnapshots[id] != nil {continue}
                do {
                    let saved=try await workDisk.exportReview(snapshot)
                    meetingExportErrors.removeValue(forKey:id)
                    if current?.id==id {exportError=nil}
                    if voiceSaveSnapshots[id] == nil {
                        if current?.id==id { current=saved }
                        if let i=meetings.firstIndex(where:{$0.id==id}) { meetings[i]=saved }
                    }
                } catch {
                    let issue="Modifiche salvate sul Mac; aggiornamento dell’output da riprovare: "+error.localizedDescription
                    meetingExportErrors[id]=issue
                    if current?.id==id {exportError=issue}
                }
                if voiceSaveSnapshots[id] == nil { savingVoiceMeetings.remove(id);voiceSaveOriginals.removeValue(forKey:id) }
            }
            voiceSaveTask=nil
        }
    }
    func queueTranscription(_ meeting:Meeting) async {
        if let previewRecordingHandoff {await previewRecordingHandoff(meeting);return}
        pendingWorkSubmissions.insert(meeting.id);defer{pendingWorkSubmissions.remove(meeting.id)}
        await flushVoiceSaves()
        guard !voiceSaveFailures.contains(meeting.id),!noteDrafts.contains(meeting.id) else{return}
        var job=MeetingWorkJob(meetingID:meeting.id,title:meeting.title,kind:.transcription);job.automaticVoices=automaticVoices
        _=await workQueue.enqueue(job)
        acceptWork(await workQueue.snapshot())
    }
    @Published var waitingTranscriptionID: UUID?
    @Published var waitingTranscriptionMessage = ""
    private var waitingTranscriptionTask: Task<Void,Never>?
    private var deferredTeamsProbe: @Sendable () async -> TeamsCallSignal = {
        await Task.detached(priority:.utility) { TeamsCallProbe.sample() }.value
    }
    // Preview can replace only the expensive automatic-resume action.
    private var deferredResumeAction: (@MainActor () async -> Void)?
    private var processing: Task<Void, Never>?
    private var timer: Timer?
    private var failedProcessing = false
    private var finalizingDeferred = false
    private var pauseDeferredProcessing = false
    private var lastDeferredTeamsProbe = -Double.infinity
    private func checkDeferredTeamsCall(force:Bool = false) async {
        guard finalizingDeferred else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now-lastDeferredTeamsProbe >= 2 else { return }
        lastDeferredTeamsProbe = now
        if await deferredTeamsProbe() != .inactive { prioritizeTeamsCall() }
    }
    private func watchDeferredCalls() -> Task<Void,Never>? {
        guard finalizingDeferred else { return nil }
        return Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkDeferredTeamsCall()
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }
    private func prioritizeTeamsCall() {
        guard finalizingDeferred, !isRecording else { return }
        pauseDeferredProcessing = true
        voiceTask?.cancel()
    }
    private var accessURL: URL?
    private var observers: [NSObjectProtocol] = []
    private var widgetPanel: NSPanel?
    private var mainWindow: NSWindow?
    private let teamsMonitor = TeamsCallMonitor()
    private var teamsTracker = TeamsCallTracker()
    private var automaticCallID: UUID?
    private var automaticSessionID: UUID?
    private var automaticAttempted = false
    private var automaticStarting = false
    private var shuttingDown = false
    func prepareToQuit() { waitingTranscriptionTask?.cancel(); refinementTask?.cancel(); voiceQualityTask?.cancel(); voiceTask?.cancel(); voicePlayer?.stop(); reportTask?.cancel(); shuttingDown = true; teamsMonitor.stop(); automaticCallID = nil }
    var readyToRecord: Bool { installed.isSuperset(of: ["asr", "vad"]) && destination != nil && (microphone || system) && !busy && !working && !reportBusy && !archiveBusy && titleEditing == nil && pendingRemoval == nil && voiceEnrollment == nil && !auditReviewVisible && !refinementVisible }
    var sessionLocked: Bool { isRecording || navigationLocked || current.map{workLocked($0.id)} == true }
    var audioSavedForDisplay: Bool { isRecording ? (recording?.keepAudio ?? keepAudio) : keepAudio }
    func showWidget() {
        quietMode = false
        if widgetPanel == nil {
            let panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 286), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Verbale — Widget"
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: RecordingWidget().environmentObject(self))
            panel.setFrameAutosaveName("VerbaleRecordingWidget")
            panel.center(); widgetPanel = panel
        }
        widgetPanel?.level = widgetPinned ? .floating : .normal
        widgetPanel?.makeKeyAndOrderFront(nil); widgetVisible = true
    }
    func hideWidget() { widgetPanel?.orderOut(nil); widgetVisible = false }
    func showMainWindow() {
        quietMode = false
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Verbale"
            window.minSize = NSSize(width: 1000, height: 680)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DashboardView().environmentObject(self).tint(.indigo))
            window.setFrameAutosaveName("VerbaleMainWindow")
            window.center(); mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
    func enterQuietMode() {
        quietMode = true; hideWidget(); mainWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
    func configureTeamsAutomation() {
        teamsMonitor.stop(); teamsTracker = TeamsCallTracker(); automaticCallID = nil; automaticAttempted = false
        if teamsAutoEnabled {
            teamsStatus = "In attesa di una chiamata Teams"
            teamsMonitor.start { [weak self] signal in Task { @MainActor in self?.receiveTeamsSignal(signal) } }
        } else {
            teamsStatus = "Automazione Teams disattivata"
            if let id = automaticSessionID, recording?.id == id {
                Task { if self.automaticSessionID == id { await self.stop() } }
            }
        }
    }
    private func receiveTeamsSignal(_ signal: TeamsCallSignal) {
        guard teamsAutoEnabled && !shuttingDown else { return }
        let event = teamsTracker.update(signal, at: Date())
        if signal == .active { prioritizeTeamsCall() }
        if event == .callBegan {
            automaticCallID = UUID(); automaticAttempted = false
        } else if event == .callEnded {
            automaticCallID = nil; automaticAttempted = false
            teamsStatus = "Chiamata conclusa · in attesa della prossima"
            if let id = automaticSessionID, recording?.id == id {
                Task { if self.automaticSessionID == id { await self.stop() } }
            }
            return
        }
        guard signal != .unavailable else {
            teamsStatus = "Rilevamento Teams non disponibile · stato chiamata non verificato"
            return
        }
        guard teamsTracker.isInCall, let callID = automaticCallID else {
            teamsStatus = signal == .active ? "Verifica della chiamata Teams…" : "In attesa di una chiamata Teams"
            return
        }
        if automaticAttempted {
            if automaticSessionID != nil { teamsStatus = signal == .inactive ? "Verifica fine chiamata · attesa di 20 secondi" : "Registrazione automatica Teams attiva" }
            return
        }
        guard signal == .active else { teamsStatus = "Verifica fine chiamata · nessun nuovo avvio"; return }
        guard !automaticStarting else { return }
        if isRecording { automaticAttempted = true; teamsStatus = "Chiamata rilevata · registrazione manuale già attiva"; return }
        guard !busy && !working && !reportBusy && !archiveBusy && titleEditing == nil && pendingRemoval == nil && voiceEnrollment == nil && !auditReviewVisible && !refinementVisible else { teamsStatus = "Chiamata rilevata · attesa della finalizzazione in corso"; return }
        guard readyToRecord else { teamsStatus = "Chiamata rilevata · configura cartella, modelli e sorgenti audio"; return }
        guard !microphone || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            teamsStatus = "Prima dell’avvio automatico, autorizza il microfono con una registrazione manuale"; return
        }
        // One attempt per call: errors and manual stops cannot cause a restart loop.
        automaticAttempted = true; automaticStarting = true
        enterQuietMode(); title = "Chiamata Teams"; current = nil
        teamsStatus = "Avvio della registrazione Teams…"
        Task {
            await start(automaticCall: callID)
            automaticStarting = false
            if let id = automaticSessionID, recording?.id == id {
                if !teamsAutoEnabled || automaticCallID != callID { await stop() }
                else { teamsStatus = "Registrazione automatica Teams attiva" }
            } else { teamsStatus = "Avvio automatico non riuscito · consulta lo stato nel menu" }
        }
    }
    func newMeeting() {
        guard !navigationLocked else { return }
        if isRecording {showRecording();return}
        refinementDraft = nil; learningSummary = ""; speakerAudit = nil; current = nil; meetingSection = "transcript"; speakersExpanded = false; voiceMatchesExpanded = false; focusedSegmentID = nil; focusNotes = false; title = ""; tab = "session"; status = "Pronto per una nuova conversazione."
    }
    /// Startup cannot continue without the data folder: explain why and where instead of crashing.
    private static func failStartup(_ title: String, _ error: Error, dataRoot: URL?) -> Never {
        let folder = dataRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Verbale", isDirectory: true)
        let message = "\(error.localizedDescription)\n\nCartella dati: \(folder.path)\n\nVerifica lo spazio su disco e i permessi della cartella, poi riapri Verbale."
        // The model is created while SwiftUI builds the scene, where a modal AppKit run loop
        // aborts the process; this system alert blocks without re-entering the app's event loop.
        var response: CFOptionFlags = 0
        CFUserNotificationDisplayAlert(0, kCFUserNotificationStopAlertLevel, nil, nil, nil, title as CFString, message as CFString, "Esci" as CFString, "Mostra nel Finder" as CFString, nil, &response)
        if response & 0x3 == kCFUserNotificationAlternateResponse {
            var visible = folder
            while !FileManager.default.fileExists(atPath: visible.path) && visible.path != "/" { visible.deleteLastPathComponent() }
            NSWorkspace.shared.activateFileViewerSelecting([visible])
        }
        exit(1)
    }
    init() {
        let previewRoot = (Bundle.main.object(forInfoDictionaryKey: "VerbalePreviewDataRoot") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        do { store = try SessionStore(root: previewRoot?.appendingPathComponent("Sessions")); models = try ModelManager(directory: previewRoot?.appendingPathComponent("Models")) }
        catch { Self.failStartup("Impossibile creare la cartella dati di Verbale", error, dataRoot: previewRoot) }
        projectTracker = ProjectTracker(file: store.root.deletingLastPathComponent().appendingPathComponent("project-ledger.json"))
        do {
            workDisk=try MeetingWorkDisk(root:store.root)
            let processor=MeetingWorkProcessor(root:store.root,models:models,disk:workDisk,credential:{ config in
                let saved=Keychain.read(account:"gateway-token")
                return saved.isEmpty ? try LocalGateway.readToken(project:config.project):saved
            })
            workQueue=try MeetingWorkQueue(file:store.root.deletingLastPathComponent().appendingPathComponent("work-queue.json"),execute:{ job,progress in try await processor.run(job,progress:progress) })
            workJobs=workQueue.initialSnapshot
        } catch { Self.failStartup("Impossibile preparare la coda di elaborazione di Verbale", error, dataRoot: previewRoot) }
        if previewRoot == nil {
            Task { [self] in
                await workQueue.start(observe:{ [weak self] jobs in Task { @MainActor in self?.acceptWork(jobs) } })
                if let warning=await workQueue.restorationWarning() {self.error=warning}
                let existing=await workQueue.snapshot()
                for meeting in (try? await workDisk.list()) ?? [] where meeting.resumeAfterTeams == true && !existing.contains(where:{$0.meetingID==meeting.id && $0.kind == .transcription}) {
                    await queueTranscription(meeting)
                }
            }
        }

        do {
            voiceStore = try VoiceProfileStore(directory: store.root.deletingLastPathComponent().appendingPathComponent("VoiceProfiles"))
            voiceProfiles = voiceStore?.profiles ?? []
        } catch { self.error = "Profili vocali non disponibili: " + error.localizedDescription }
        if let data = UserDefaults.standard.data(forKey: "destinationBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                destination = url; if url.startAccessingSecurityScopedResource() { accessURL = url }
                if stale { persistDestination(url) }
            }
        }
        noteDrafts.submit = { [weak self] id,text in self?.saveNotes(text,meetingID:id) }
        reload()
        Task { await refreshModels() }
        Task { await refreshAudioRouting() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.isRecording == true { self?.error = "Il Mac sta andando in stop: la registrazione viene finalizzata."; await self?.stop() } }
        })
    }
    func reload() {
        do { meetings = try store.list().map { meeting in
            if meeting.state == .recording || meeting.state == .processing { return (try? store.recover(meeting)) ?? meeting }; return meeting
        } } catch { self.error = error.localizedDescription }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Salva qui"; panel.message = "Scegli la cartella per trascrizioni, note e allegati."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        accessURL?.stopAccessingSecurityScopedResource(); accessURL = nil
        if url.startAccessingSecurityScopedResource() { accessURL = url }
        destination = url; persistDestination(url)
    }
    private func persistDestination(_ url: URL) {
        do { UserDefaults.standard.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "destinationBookmark") }
        catch { self.error = "La cartella è utilizzabile, ma non è stato possibile ricordarla: \(error.localizedDescription)" }
    }
    func refreshModels() async {
        var available = Set<String>()
        for spec in models.catalog { if (try? await models.verified(spec.id)) != nil { available.insert(spec.id) } }
        installed = available
    }
    func installModel(_ id: String, importFile: Bool) {
        var source: URL?
        if importFile {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.prompt = "Importa GGUF"
            guard panel.runModal() == .OK, let url = panel.url else { return }; source = url
        }
        modelWork = id
        Task {
            defer { modelWork = nil }
            let accessing = source?.startAccessingSecurityScopedResource() ?? false
            defer { if accessing { source?.stopAccessingSecurityScopedResource() } }
            do { try await models.install(id, from: source); await refreshModels() } catch { self.error = error.localizedDescription }
        }
    }
    private func loadEngine(diarization: Bool = false) async throws {
        let asr = try await models.verified("asr"), vad = try await models.verified("vad")
        let diar = diarization ? try await models.verified("diarization") : nil
        await checkDeferredTeamsCall(force:true)
        if finalizingDeferred && pauseDeferredProcessing { return }
        try await engine.load(asr: asr, vad: vad, diarization: diar)
    }
    func start(automaticCall: UUID? = nil) async {
        guard !shuttingDown && !busy && !isRecording && !reportBusy && !working && !archiveBusy && titleEditing == nil && pendingRemoval == nil && voiceEnrollment == nil && !auditReviewVisible && !refinementVisible else { return }
        guard let destination else { if automaticCall == nil { chooseDestination() }; return }
        let sources = AudioSource.allCases.filter { $0 == .microphone ? microphone : system }
        guard !sources.isEmpty else { error = "Seleziona almeno una sorgente audio."; return }
        busy = true; status = "Preparazione della trascrizione…"; exportError = nil; error = nil; failedProcessing = false
        defer { busy = false }
        do {
            await workQueue.setCaptureActive(true)
            guard await capture.available else { throw CaptureOperationError.recovering }
            // Capture must not compete with the call for inference resources.
            // Freeze the preference into the meeting, not the mutable settings.
            let timing = transcriptionTiming
            if timing == .duringRecording {
                if listeningMode == .speakers && microphone && system { try await echoCancellation.prepare() }
                try await loadEngine()
            }
            if let automaticCall, (!teamsAutoEnabled || automaticCallID != automaticCall) {
                await engine.unload(); await echoCancellation.unload(); status = "Avvio automatico annullato"; return
            }
            let routeSnapshot = try await readAudioSnapshot()
            installAudioSnapshot(routeSnapshot)
            let selectedInput = sources.contains(.microphone) ? try AudioRouteSelection.resolve(inputChoice,input:true,snapshot:routeSnapshot):nil
            let selectedOutput = sources.contains(.system) ? try AudioRouteSelection.resolve(outputChoice,input:false,snapshot:routeSnapshot):nil
            var meeting = Meeting(title: title, sources: sources, destination: destination, keepAudio: keepAudio)
            meeting.audioRoute = RecordedAudioRoute(input:selectedInput,output:selectedOutput)
            if let warning = AudioRouteSelection.outputMismatchWarning(selectedOutput,snapshot:routeSnapshot) { meeting.warnings.append(warning) }
            meeting.transcriptionTiming = timing
            exportCadence = RecordingExportCadence()
            meeting.keepRecovery = keepRecovery
            meeting.listeningMode = listeningMode
            meeting.captureTimelineVersion = 2
            meeting.echoProcessingVersion = meeting.usesEchoCancellation ? 1 : nil
            meeting.modelDigests = Dictionary(uniqueKeysWithValues: models.catalog.filter { ["asr", "vad"].contains($0.id) }.map { ($0.id, $0.sha256) })
            try store.save(meeting); learningSummary = ""; speakerAudit = nil; current = meeting;activeRecording=meeting;elapsed=0
            // Preflight the selected folder before requesting recording permission.
            installRecording(try store.export(meeting))
            let id = meeting.id
            let started = try await capture.start(sources: sources, input: selectedInput?.device.runtimeID ?? 0, output: selectedOutput?.device.runtimeID ?? 0, folder: store.workspace(id), onChunk: { [weak self] chunk in
                Task { @MainActor in self?.receive(chunk, id: id) }
            }, onLevel: { [weak self] source, level in Task { @MainActor in
                guard let self,self.isRecording,self.recording?.id == id else { return }
                self.levels[source] = level
            } }, onError: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.recording?.id == id else { return }
                    self.error = text
                    if self.isRecording { await self.stop() }
                }
            })
            if let failure = self.error { throw VerbaleError.message(failure) }
            if var recording {recording.started=started;installRecording(recording);try store.save(recording);exportRecording()}
            isRecording = true; elapsed = 0; status = "Registrazione attiva · in attesa dell’audio"
            scheduleProcessing()
            if automaticCall != nil { automaticSessionID = meeting.id }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            reloadWithoutRecovery()
        } catch {
            failedProcessing = true
            await capture.stop()
            isRecording = false; automaticSessionID = nil; timer?.invalidate(); timer = nil
            self.error = error.localizedDescription; status = "Preparazione non riuscita"
            await workQueue.setCaptureActive(false)
            if var meeting = recording, meeting.state == .recording { meeting.state = .interrupted;try? store.save(meeting);installRecording(meeting) }
            activeRecording=nil
            await engine.unload()
            await echoCancellation.unload()
        }
    }
    var captureWarning: String? {
        guard isRecording, let meeting = recording else { return nil }
        return RecordingReadiness.systemWarning(meeting.sources,chunks:meeting.chunks,elapsed:elapsed) ?? meeting.warnings.first { $0.hasPrefix("L’uscita registrata") }
    }
    private func tick() {
        guard isRecording, let current=recording else { return }
        elapsed = Date().timeIntervalSince(current.started)
        if RecordingReadiness.missingMicrophone(current.sources,chunks:current.chunks,elapsed:elapsed) {
            error = "Nessun buffer ricevuto dal microfono. Verifica il dispositivo e il permesso Microfono."; Task { await stop() }
        } else if RecordingReadiness.waitingForSystem(current.sources,chunks:current.chunks) {
            status = captureWarning ?? "Registrazione attiva · in attesa dell’audio di sistema"
        } else { status = "Registrazione in corso" }
    }

    private func receive(_ chunk: AudioChunk, id: UUID) {
        guard var meeting = recording, meeting.id == id, !meeting.chunks.contains(where: { $0.id == chunk.id }) else { return }
        meeting.chunks.append(chunk); meeting.duration = max(meeting.duration, chunk.start + chunk.duration); meeting.exported = false
        installRecording(meeting)
        do { try store.save(meeting) } catch { self.error = error.localizedDescription; if isRecording { Task { await stop() } } }
        exportRecording()
        // stop() replays the durable journal and owns final processing. A late
        // capture callback must not race deferred model loading after Stop.
        if !failedProcessing && isRecording { scheduleProcessing() }
    }
    private func scheduleProcessing() {
        guard processing == nil, !transcriptionDeferred else { return }
        processing = Task(priority: .utility) { [weak self] in
            await self?.processPending()
            self?.processing = nil
        }
    }
    private func processPending() async {
        guard !transcriptionDeferred else { return }
        working = true; defer { working = false }
        while let meeting = activeRecording ?? current {
            await checkDeferredTeamsCall()
            if pauseDeferredProcessing || Task.isCancelled { break }
            let eligible = meeting.chunks.filter { !$0.processed }.sorted { $0.start < $1.start }.first { chunk in
                if !isRecording { return true }
                guard meeting.chunks.contains(where: { $0.source == chunk.source && $0.start > chunk.start }) else { return false }
                if chunk.source == .microphone && meeting.usesEchoCancellation {
                    return (meeting.chunks.filter { $0.source == .system }.map { $0.start + $0.duration }.max() ?? 0) >= chunk.start + chunk.duration
                }
                return true
            }
            guard let chunk = eligible else { break }
            do {
                let siblings = meeting.chunks.filter { $0.source == chunk.source }.sorted { $0.start < $1.start }
                let index = siblings.firstIndex { $0.id == chunk.id }!
                let needsEchoCancellation = chunk.source == .microphone && meeting.usesEchoCancellation
                let neighborhood = siblings[max(0, index - (needsEchoCancellation ? 2 : 1))...min(index + 1, siblings.count - 1)]
                let transcriptionOffset = siblings[max(0, index - 1)].start
                var audio: [Float] = []; var offset = neighborhood.first!.start
                for item in neighborhood {
                    let start = Int((item.start - offset) * 16000)
                    guard start < 60 * 16000 else { continue }
                    if start > audio.count { audio.append(contentsOf: repeatElement(0, count: start - audio.count)) }
                    let input = try AudioFiles.samples(audioURL(meeting, filename: item.filename))
                    let overlap = max(0, audio.count - start)
                    audio.append(contentsOf: input.dropFirst(overlap))
                }
                var cleanedFilename: String?
                var incompleteReference = false
                if needsEchoCancellation {
                    let result = try await echoCancellation.cleanWindow(microphone: audio, start: offset, chunks: meeting.chunks,
                        workspace: store.workspace(meeting.id), exported: URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName))
                    audio = result.samples
                    let begin = max(0, Int(((chunk.start - offset) * 16000).rounded()))
                    let end = min(audio.count, begin + chunk.sampleCount)
                    guard end - begin == chunk.sampleCount else { throw VerbaleError.message("Blocco microfono AEC incompleto") }
                    incompleteReference = result.covered[begin..<end].contains(0)
                    let filename = "audio/cleaned_\(chunk.id.uuidString).caf"
                    try AudioFiles.write(Array(audio[begin..<end]), to: store.workspace(meeting.id).appendingPathComponent(filename))
                    cleanedFilename = filename
                }
                // Give the adaptive filter extra warm-up without expanding ASR work.
                if transcriptionOffset > offset {
                    let trim = Int(((transcriptionOffset - offset) * 16000).rounded())
                    audio = Array(audio.dropFirst(trim)); offset = transcriptionOffset
                }
                let result:[Segment]
                if let previewLiveTranscriber {result=try await previewLiveTranscriber(audio,chunk.source,offset)}
                else {result=try await engine.transcribe(samples:audio,source:chunk.source,offset:offset)}
                let selected = Self.ownedSegments(result, chunk: chunk)
                guard var latest = activeRecording ?? current, latest.id == meeting.id else { break }
                latest.appendTranscription(selected,for:chunk)
                latest.reconcileEchoTranscript(near: chunk.start, end: chunk.start + chunk.duration)
                latest.invalidateReport()
                if let i = latest.chunks.firstIndex(where: { $0.id == chunk.id }) {
                    latest.chunks[i].processed = true; latest.chunks[i].cleanedFilename = cleanedFilename
                }
                if incompleteReference {
                    let warning = "Riferimento eco non disponibile in alcune porzioni: lì il microfono è stato conservato senza trattamento."
                    if !latest.warnings.contains(warning) { latest.warnings.append(warning) }
                }
                latest.exported = false;installRecording(latest);try store.save(latest)
                if activeRecording != nil {exportRecording()} else {exportCurrent()}
            } catch is CancellationError { break }
            catch { failedProcessing = true; self.error = "Trascrizione interrotta: \(error.localizedDescription). L'audio resta recuperabile."; break }
        }
    }
    static func ownedSegments(_ segments: [Segment], chunk: AudioChunk) -> [Segment] {
        TranscriptBoundaries.owned(segments,by:chunk)
    }

    func stop() async {
        noteDrafts.flush()
        guard isRecording && !busy else { return }
        if automaticSessionID != nil { teamsStatus = "Registrazione terminata · attesa della prossima chiamata" }
        automaticSessionID = nil
        let stoppedAt = Date()
        busy = true; isRecording = false; timer?.invalidate(); timer = nil; levels = [:]; status = "Finalizzazione…"
        let captureStopped = await capture.stop()
        if !captureStopped { failedProcessing = true; self.error = "L’arresto del dispositivo audio è in ritardo. I blocchi salvati restano recuperabili; attendi il ripristino o chiudi e riapri Verbale." }
        if var meeting = recording {
            // Journal replay also accounts for callbacks enqueued just before stop.
            meeting = (try? store.recover(meeting)) ?? meeting
            meeting.duration = max(meeting.duration,stoppedAt.timeIntervalSince(meeting.started))
            for warning in RecordingReadiness.missingSourceWarnings(meeting.sources,chunks:meeting.chunks) where !meeting.warnings.contains(warning) { meeting.warnings.append(warning) }
            meeting.state = .processing;installRecording(meeting);try? store.save(meeting)
        }
        processing?.cancel()
        if let processing { await processing.value }
        await engine.unload();await echoCancellation.unload()
        if var meeting=recording {
            meeting.state=failedProcessing ? .failed:.interrupted;meeting.exported=false
            do {
                try await workDisk.save(meeting)
                meeting=try await workDisk.export(meeting);installRecording(meeting)
                if !failedProcessing { await queueTranscription(meeting) }
            } catch { self.error=error.localizedDescription }
        }
        await workQueue.setCaptureActive(false)
        activeRecording=nil
        status="Audio salvato · trascrizione in coda";busy=false
    }
    private func finishSession() {
        guard var meeting = current else { return }
        meeting.state = failedProcessing ? .failed : pauseDeferredProcessing ? .interrupted : .complete
        if pauseDeferredProcessing {
            meeting.resumeAfterTeams = true
            let warning = "Trascrizione in pausa per dare priorità alla chiamata Teams. Riprendi dall’archivio al termine."
            if !meeting.warnings.contains(warning) { meeting.warnings.append(warning) }
        }
        if meeting.state == .complete {
            meeting.resumeAfterTeams = false
            meeting.warnings.removeAll { $0 == "Trascrizione in pausa per dare priorità alla chiamata Teams. Riprendi dall’archivio al termine." }
        }
        meeting.exported = false; current = meeting
        do { try store.save(meeting); exportCurrent() } catch { self.error = error.localizedDescription }
        status = failedProcessing ? "Audio salvato · trascrizione da riprendere" : pauseDeferredProcessing ? "Audio salvato · trascrizione in pausa per Teams" : "Riunione completata"
        if let saved = current, saved.exported && !saved.keepRecovery {
            do { try store.cleanupAudio(saved) } catch { self.error = "Output salvato. Non è stato possibile rimuovere l'audio temporaneo: \(error.localizedDescription)" }
        }
        reloadWithoutRecovery()
    }
    private func exportRecording() {
        guard let meeting=recording else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard exportCadence.shouldExport(isRecording:isRecording,now:now) else{return}
        do {
            let saved=try store.export(meeting);installRecording(saved)
            exportCadence.succeeded(at:now);meetingExportErrors.removeValue(forKey:meeting.id)
            if current?.id==meeting.id {exportError=nil}
        } catch {
            meetingExportErrors[meeting.id]=error.localizedDescription
            if current?.id==meeting.id {exportError=error.localizedDescription}
        }
    }
    func exportCurrent() {
        guard let meeting = current else { return }
        if isRecording,recording?.id==meeting.id {exportRecording();return}
        let now = ProcessInfo.processInfo.systemUptime
        guard exportCadence.shouldExport(isRecording:false,now:now) else { return }
        do {
            let saved = try store.export(meeting); current = saved; exportError = nil
            meetingExportErrors.removeValue(forKey:meeting.id)
            if saved.state == .complete && !saved.keepRecovery { try store.cleanupAudio(saved) }
        }
        catch { exportError = error.localizedDescription;meetingExportErrors[meeting.id]=error.localizedDescription }
    }
    func exportElsewhere() { chooseDestination(); guard var meeting = current, let destination else { return }; meeting.destination = destination.path; meeting.exported = false; current = meeting; exportCurrent(); reloadWithoutRecovery() }
    func open(_ meeting: Meeting) {
        guard !navigationLocked else { return }
        var updated = recording?.id==meeting.id ? recording! : (meetings.first(where:{$0.id==meeting.id}) ?? meeting)
        exportError=meetingExportErrors[meeting.id]
        updated.repairEchoAuditReferences()
        learningSummary = ""; speakerAudit = loadSpeakerAudit(updated); refinementDraft = loadRefinement(updated); current = updated; meetingSection = "transcript"; speakersExpanded = false; voiceMatchesExpanded = false; focusedSegmentID = nil; focusNotes = false; title = updated.title; tab = "session"
        if meeting.echoDuplicates?.map(\.systemSegments) != updated.echoDuplicates?.map(\.systemSegments)
            || meeting.echoDuplicates?.map(\.referenceStatus) != updated.echoDuplicates?.map(\.referenceStatus) {
            do { try store.save(updated); exportCurrent() }
            catch { self.error = "Riferimenti eco ricostruiti ma non salvati: \(error.localizedDescription)" }
        }
        if updated.resumeAfterTeams == true {
            if Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil { waitForTeamsEnd(updated.id) }
            else if !workJobs.contains(where:{$0.meetingID==updated.id && $0.kind == .transcription}) { Task { await queueTranscription(updated) } }
        }
    }
    private func waitForTeamsEnd(_ id:UUID) {
        guard var meeting = current,meeting.id == id else { return }
        waitingTranscriptionTask?.cancel()
        if meeting.resumeAfterTeams != true {
            meeting.resumeAfterTeams = true;meeting.exported = false;current = meeting
            do { try store.save(meeting);exportCurrent() } catch { self.error = error.localizedDescription;return }
        }
        waitingTranscriptionID = id
        waitingTranscriptionMessage = "Teams segnala una chiamata in corso. La trascrizione ripartirà automaticamente alla fine della call, quando questa riunione è aperta."
        status = "Audio salvato · attesa della fine della chiamata Teams"
        waitingTranscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.waitingTranscriptionID == id,!self.shuttingDown else { return }
                guard FileManager.default.fileExists(atPath:self.store.workspace(id).appendingPathComponent("meeting.json").path) else {
                    self.waitingTranscriptionID = nil;self.waitingTranscriptionTask = nil;return
                }
                let signal = await self.deferredTeamsProbe()
                guard !Task.isCancelled,self.waitingTranscriptionID == id else { return }
                self.waitingTranscriptionMessage = signal == .unavailable ? "Lo stato di Teams non è verificabile. L’audio è salvato; riprovo automaticamente." : "La trascrizione è in attesa della fine della chiamata Teams. Ripartirà automaticamente quando questa riunione è aperta."
                if signal == .inactive,self.current?.id == id,!self.sessionLocked {
                    self.waitingTranscriptionID = nil;self.waitingTranscriptionTask = nil
                    if let action = self.deferredResumeAction { await action() }
                    else { await self.resume() }
                    return
                }
                try? await Task.sleep(for:.seconds(2))
            }
        }
    }
    func cancelWaitingTranscription() {
        waitingTranscriptionTask?.cancel();waitingTranscriptionTask = nil
        if var meeting = current,meeting.id == waitingTranscriptionID {
            meeting.resumeAfterTeams = false;meeting.exported = false;current = meeting
            do { try store.save(meeting);exportCurrent() } catch { self.error = error.localizedDescription }
        }
        waitingTranscriptionID = nil;waitingTranscriptionMessage = "";status = "Ripresa automatica annullata · audio salvato"
    }
    func resume() async {
        guard let meeting=current,!navigationLocked,!viewingRecording,work(meeting.id,kind:.report)?.state.pending != true else{return}
        if Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil && deferredResumeAction != nil { await resumeLegacy();return }
        error=nil;await queueTranscription(meeting)
    }
    private func resumeLegacy() async {
        guard var meeting = current, !sessionLocked else { return }
        waitingTranscriptionTask?.cancel();waitingTranscriptionTask = nil;waitingTranscriptionID = nil
        error = nil
        busy = true; failedProcessing = false; status = "Ripresa dell'elaborazione…"
        finalizingDeferred = meeting.transcriptionTiming == .afterRecording;pauseDeferredProcessing = false
        let callWatch = watchDeferredCalls()
        defer { callWatch?.cancel();finalizingDeferred = false;pauseDeferredProcessing = false }
        await checkDeferredTeamsCall(force:true)
        if pauseDeferredProcessing {
            busy = false;waitForTeamsEnd(meeting.id);return
        }
        do {
            try await loadEngine(); meeting = try store.recover(meeting); meeting.state = .processing;meeting.resumeAfterTeams = false; current = meeting
            try store.save(meeting); await processPending(); if !failedProcessing && !pauseDeferredProcessing { await runAutomaticVoices() }; finishSession()
        } catch { self.error = error.localizedDescription }
        await engine.unload()
        await echoCancellation.unload()
        busy = false
        if pauseDeferredProcessing,let meeting = current { waitForTeamsEnd(meeting.id) }
    }
    @discardableResult func saveReview(_ meeting: Meeting) -> Bool {
        // Callers have already validated the edit. Persist off-main, coalescing
        // successive snapshots; an eventual failure restores the durable version.
        persistVoiceDecision(meeting)
        return true
    }
    func saveNotes(_ notes: String,meetingID:UUID? = nil) {
        guard let id=meetingID ?? current?.id,
              !workJobs.contains(where:{$0.meetingID==id && $0.state.pending}),
              var meeting=(recording?.id==id ? recording : current?.id==id ? current : meetings.first(where:{$0.id==id})) else{return}
        guard meeting.notes != notes || noteDrafts.failures.contains(id) else {if !savingVoiceMeetings.contains(id) {noteDrafts.saved(id,text:notes)};return}
        meeting.notes=notes;meeting.invalidateReport()
        if recording?.id==id {
            // The active capture still owns its checkpoints. Keep this infrequent
            // write on its existing serial main-actor path, avoiding stale audio snapshots.
            installRecording(meeting)
            do {try store.save(meeting);noteDrafts.saved(id,text:notes)}
            catch {noteDrafts.failed(id);self.error="Note non salvate: "+error.localizedDescription}
        } else {persistVoiceDecision(meeting)}
    }
    @discardableResult func rename(_ id: String, to value: String, meetingID: UUID? = nil) async -> Bool {
        let name = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !sessionLocked, !name.isEmpty, var meeting = current, meetingID == nil || meeting.id == meetingID else { return false }
        do { if try !meeting.renameSpeakerPerson(id,to:name) { return true } }
        catch { self.error = error.localizedDescription; return false }
        persistVoiceDecision(meeting)
        discardStaleSpeakerAudit(for:meeting)
        status="Nome dell’interlocutore aggiornato"
        return true
    }

    func focusSpeaker(_ id: String) {
        guard let meeting = current else { return }
        guard let first = meeting.firstSegment(forSpeaker:id) else { return }
        focusRequestID = UUID()
        meetingSection = "transcript"; focusedSegmentID = first.id; focusNotes = false; tab = "session"
    }
    func addMarker(_ kind: MarkerKind) {
        guard isRecording, !busy, var meeting = recording else { return }
        do { try meeting.addMarker(kind, at: elapsed);try store.save(meeting);installRecording(meeting);exportRecording();status = "\(kind.label) segnata · \(timecode(elapsed))" }
        catch { self.error = error.localizedDescription }
    }
    func removeMarker(_ id: UUID) {
        guard !busy, !reportBusy, var meeting = current, !workLocked(meeting.id) else { return }
        meeting.removeMarker(id); saveReview(meeting)
    }
    func correctSegment(meetingID: UUID, segmentID: UUID, text: String, speakerID: String?, newSpeaker: String) -> Bool {
        guard !sessionLocked, var meeting = current, meeting.id == meetingID else { return false }
        let name = newSpeaker.trimmingCharacters(in: .whitespacesAndNewlines)
        var selected = speakerID
        if !name.isEmpty {
            selected = meeting.speakers.first(where: { $0.value == name })?.key ?? "manual-\(UUID().uuidString)"
            meeting.speakers[selected!] = name
        }
        do {
            let previous = current!
            let speakerChanged = previous.segments.first(where: { $0.id == segmentID })?.speakerID != selected
            try meeting.correctSegment(segmentID, text: text, speakerID: selected)
            guard saveReview(meeting) else { return false }
            learnFromSegmentCorrection(segmentID,previous:previous,updated:meeting,speakerConfirmed:speakerChanged)
            return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    func openReportSource(_ url: URL) -> Bool {
        guard let meeting = current, url.scheme == nil else { return false }
        if url.path == "notes.md" { meetingSection = "notes"; focusNotes = true; tab = "session"; return true }
        guard url.path == "transcript.md", let anchor = url.fragment else { return false }
        if let segment = meeting.segments.first(where: { $0.anchor == anchor }) { focusedSegmentID = segment.id }
        else if let marker = meeting.markers.first(where: { $0.anchor == anchor }) {
            focusedSegmentID = meeting.segments.min(by: { abs($0.start - marker.timestamp) < abs($1.start - marker.timestamp) })?.id
        } else { return false }
        meetingSection = "transcript"; focusNotes = false; tab = "session"; return true
    }
    func reveal() { guard let meeting = current else { return }; NSWorkspace.shared.open(URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName)) }
    func canManageMeeting(_ meeting: Meeting) -> Bool {
        !archiveBusy && !workLocked(meeting.id) && !(isRecording && recording?.id==meeting.id) && !(current?.id == meeting.id && (viewingRecording || busy || (working && !isRecording) || reportBusy || voiceEnrollment != nil || auditReviewVisible || refinementVisible))
    }
    func editMeetingTitle(_ meeting: Meeting) { guard canManageMeeting(meeting), pendingRemoval == nil else { return }; error = nil; titleEditing = meeting }
    func delete(_ meeting: Meeting) { guard canManageMeeting(meeting), titleEditing == nil else { return }; error = nil; pendingRemoval = meeting }
    @discardableResult func removeMeeting(_ meeting: Meeting) async -> Bool {
        guard canManageMeeting(meeting) else { return false }
        archiveBusy = true; pendingRemoval = nil; defer { archiveBusy = false }
        let root = store.root
        let previewTrash = (Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") as? String).map { URL(fileURLWithPath:$0).appendingPathComponent("Trash") }
        do {
            try await Task.detached {
                let disk = try SessionStore(root:root)
                _ = try disk.trashWorkspace(meeting.id,testingTrash:previewTrash)
            }.value
            await workQueue.forget(meeting.id)
            acceptWork(await workQueue.snapshot())
            meetings.removeAll{$0.id==meeting.id}
            if current?.id == meeting.id { current = nil; speakerAudit = nil; learningSummary = ""; title = "" }
            return true
        } catch { self.error = "Rimozione non completata: " + error.localizedDescription; return false }
    }
    @discardableResult func renameMeetingTitle(_ meeting: Meeting, to value: String) async -> Bool {
        guard canManageMeeting(meeting) else { return false }
        let root = store.root
        archiveBusy = true; defer { archiveBusy = false }
        do {
            let result = try await Task.detached {
                let disk = try SessionStore(root:root)
                var latest = try disk.read(meeting.id)
                try latest.changeTitle(value); try disk.save(latest)
                var issue: String?
                do { latest = try disk.export(latest,documentsOnly:true) } catch { issue = error.localizedDescription }
                return (latest,issue)
            }.value
            if let i=meetings.firstIndex(where:{$0.id==meeting.id}) {meetings[i]=result.0}
            if current?.id == meeting.id { current = result.0; title = result.0.title; exportError = result.1 }
            titleEditing = nil
            if let issue = result.1 { self.error = "Titolo salvato nell’archivio. Aggiornamento dei file esportati da riprovare: " + issue }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func screenshot() async {
        guard let meeting = recording, isRecording else { return }
        let id = meeting.id, timestamp = elapsed
        let folder = store.workspace(id).appendingPathComponent("screenshots")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = "screenshots/\(UUID().uuidString).png", target = store.workspace(id).appendingPathComponent(filename)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); process.arguments = ["-i", "-o", "-x", target.path]
            try process.run()
            await withCheckedContinuation { continuation in DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() } }
            guard FileManager.default.fileExists(atPath: target.path), var latest = recording, latest.id == id else { return }
            latest.screenshots.append(Screenshot(timestamp: timestamp, filename: filename));installRecording(latest);try store.save(latest);exportRecording()
        } catch { self.error = error.localizedDescription }
    }
    private func gatewayCredential() throws -> String {
        if !gatewayToken.isEmpty { try LocalGateway.validateToken(gatewayToken); return gatewayToken }
        let saved = Keychain.read(account: "gateway-token")
        if !saved.isEmpty { try LocalGateway.validateToken(saved); return saved }
        return try LocalGateway.readToken(project: gatewayProject)
    }
    func importGatewayToken() {
        do { gatewayToken = try LocalGateway.readToken(project: gatewayProject); gatewayStatus = "Token locale importato · premi Verifica e aggiorna modelli" }
        catch { gatewayStatus = error.localizedDescription }
    }
    func checkGateway() async {
        guard !checkingGateway else { return }
        let endpoint = gatewayEndpoint, project = gatewayProject
        checkingGateway = true; gatewayStatus = "Verifica del gateway…"
        defer { checkingGateway = false }
        do {
            let token = try gatewayCredential()
            let available = try await LocalGateway.models(endpoint: endpoint, token: token)
            guard gatewayEndpoint == endpoint, gatewayProject == project else { return }
            try Keychain.save(token, account: "gateway-token")
            gatewayModels = available
            if !available.contains(where: { $0.id == gatewayModel }) { gatewayModel = available.first(where: { $0.id == "claude/haiku" })?.id ?? available[0].id }
            gatewayStatus = "Gateway connesso · \(available.count) modelli configurati. Login e disponibilità del backend vengono verificati alla generazione."
        } catch { if gatewayEndpoint == endpoint, gatewayProject == project { gatewayModels = []; gatewayStatus = error.localizedDescription } }
    }
    func openGatewayFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: gatewayProject, isDirectory: true)) }
    func launchGateway() {
        let script = URL(fileURLWithPath: gatewayProject, isDirectory: true).appendingPathComponent("start-verbale.command")
        guard FileManager.default.isExecutableFile(atPath: script.path) else { gatewayStatus = "Avvio non configurato: manca start-verbale.command nella cartella del gateway. Consulta il README del collegamento."; return }
        if NSWorkspace.shared.open(script) { gatewayStatus = "Avvio richiesto nel Terminale · premi Verifica e aggiorna modelli quando il gateway è pronto." }
        else { gatewayStatus = "Impossibile aprire lo script di avvio. Avvia il gateway dal Terminale." }
    }
    func startReport() {
        guard let meeting=current,!navigationLocked,!viewingRecording,!meeting.segments.isEmpty else{return}
        do {
            let token=try gatewayCredential();try Keychain.save(token,account:"gateway-token")
            let settings=ReportWorkSettings(endpoint:gatewayEndpoint,model:gatewayModel,project:gatewayProject,style:reportStyle.rawValue,token:token)
            meetingSection="report";tab="session";pendingWorkSubmissions.insert(meeting.id)
            Task {
                defer{pendingWorkSubmissions.remove(meeting.id)}
                await flushVoiceSaves()
                guard !voiceSaveFailures.contains(meeting.id),!noteDrafts.contains(meeting.id) else{return}
                _=await workQueue.enqueue(MeetingWorkJob(meetingID:meeting.id,title:meeting.title,kind:.report,report:settings))
                acceptWork(await workQueue.snapshot())
            }
        } catch { self.error=error.localizedDescription }
    }
    func cancelReport() { if let id=current?.id,let job=work(id,kind:.report) { cancelWork(job.id) } }
    func report() async { startReport() }
    private func reloadWithoutRecovery() { meetings = (try? store.list()) ?? [] }
    private func audioURL(_ meeting: Meeting, filename: String) -> URL {
        let local = store.workspace(meeting.id).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName).appendingPathComponent(filename)
    }
}


extension AppModel {
    /// Exercised only by the isolated Preview's self-check; never opens hardware.
    func checkDeferredRecording() async throws -> [String:Bool] {
        guard Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil else { return [:] }
        let saved = current, oldError = error,oldActive = activeRecording
        defer { isRecording = false;activeRecording=oldActive; current = saved; error = oldError; failedProcessing = false; finalizingDeferred = false;pauseDeferredProcessing = false;busy = false }
        var meeting = Meeting(title:"Deferred capture check",sources:[.system],destination:store.root.deletingLastPathComponent(),keepAudio:true)
        meeting.transcriptionTiming = .afterRecording
        try store.save(meeting);current = meeting;activeRecording=meeting;isRecording = true;error = nil
        exportCadence = RecordingExportCadence()
        for i in 0..<3 {
            let chunk = AudioChunk(source:.system,start:Double(i)*0.1,sampleCount:1600,filename:"audio/deferred-\(i).caf")
            try AudioFiles.write([Float](repeating:0,count:1600),to:store.workspace(meeting.id).appendingPathComponent(chunk.filename))
            try store.append(chunk,id:meeting.id)
            receive(chunk,id:meeting.id)
        }
        await Task.yield()
        let pending = try store.read(meeting.id)
        var checks = ["deferred recording persists all chunks without ASR":pending.chunks.count == 3 && pending.chunks.allSatisfy { !$0.processed } && processing == nil && error == nil && !working]
        isRecording = false
        current?.state = .processing
        let late = AudioChunk(source:.system,start:0.3,sampleCount:1600,filename:"audio/deferred-late.caf")
        try AudioFiles.write([Float](repeating:0,count:1600),to:store.workspace(meeting.id).appendingPathComponent(late.filename))
        try store.append(late,id:meeting.id)
        receive(late,id:meeting.id)
        checks["late capture callback cannot start ASR before deferred models load"] = processing == nil && error == nil && current?.chunks.count == 4
        // Simulate a missing model at finalization: the normal failure path must
        // keep every durable file and expose a resumable meeting.
        await processPending();finishSession()
        let failed = try store.read(meeting.id)
        checks["deferred processing failure remains recoverable"] = failed.state == .failed && failed.chunks.count == 4 && failed.chunks.allSatisfy { FileManager.default.fileExists(atPath:store.workspace(meeting.id).appendingPathComponent($0.filename).path) }
        failedProcessing = false;current = failed;current?.state = .processing
        busy = true;finalizingDeferred = true;pauseDeferredProcessing = false
        prioritizeTeamsCall()
        await processPending();finishSession()
        let paused = try store.read(meeting.id)
        checks["Teams call pauses deferred work with every audio chunk recoverable"] = paused.state == .interrupted && paused.chunks.count == 4 && paused.chunks.allSatisfy { !$0.processed && FileManager.default.fileExists(atPath:store.workspace(meeting.id).appendingPathComponent($0.filename).path) }
        return checks
    }
}


extension AppModel {
    /// Mocks only the Teams signal and the eventual expensive inference start.
    /// The real resume/queue/persistence/cancellation paths are exercised.
    func checkWaitingResume() async throws -> [String:Bool] {
        guard Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil else { return [:] }
        let old = current,oldError = error,oldProbe = deferredTeamsProbe,oldStatus = status
        defer {
            waitingTranscriptionTask?.cancel();waitingTranscriptionTask = nil;waitingTranscriptionID = nil
            deferredTeamsProbe = oldProbe;deferredResumeAction = nil
            current = old;error = oldError;status = oldStatus;busy = false
        }
        var meeting = Meeting(title:"Waiting resume check",sources:[.system],destination:store.root.deletingLastPathComponent(),keepAudio:false)
        meeting.state = .interrupted;meeting.transcriptionTiming = .afterRecording
        try store.save(meeting);current = meeting;error = "Errore precedente"
        deferredTeamsProbe = { .active }
        var starts = 0
        deferredResumeAction = { starts += 1 }
        await resume()
        let persistedWaiting = try store.read(meeting.id).resumeAfterTeams
        var checks = ["resume during Teams visibly queues and persists intention without inference":waitingTranscriptionID == meeting.id && !waitingTranscriptionMessage.isEmpty && !busy && error == nil && starts == 0 && persistedWaiting == true]
        deferredTeamsProbe = { .unavailable }
        try await Task.sleep(for:.milliseconds(2200))
        checks["unknown Teams signal never starts waiting inference"] = starts == 0 && waitingTranscriptionID == meeting.id
        deferredTeamsProbe = { .inactive }
        try await Task.sleep(for:.milliseconds(2200))
        checks["waiting resume dispatches once when Teams ends"] = starts == 1 && waitingTranscriptionID == nil
        deferredTeamsProbe = { .active };waitForTeamsEnd(meeting.id)
        cancelWaitingTranscription()
        let persistedCancelled = try store.read(meeting.id).resumeAfterTeams
        checks["cancel waiting clears persisted intention without deleting session"] = waitingTranscriptionID == nil && persistedCancelled == false
        deferredTeamsProbe = { .unavailable }
        await resume()
        checks["explicit resume also waits when Teams status is unknown"] = waitingTranscriptionID == meeting.id && starts == 1
        cancelWaitingTranscription()
        deferredTeamsProbe = { try? await Task.sleep(for:.milliseconds(200));return .inactive }
        waitForTeamsEnd(meeting.id)
        try await Task.sleep(for:.milliseconds(50));cancelWaitingTranscription()
        try await Task.sleep(for:.milliseconds(300))
        checks["cancelled in-flight Teams probe cannot resume late"] = starts == 1 && waitingTranscriptionID == nil
        return checks
    }
}


extension AppModel {
    func checkWorkAlertDismissal() async throws -> [String:Bool] {
        guard Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil else{return [:]}
        let meetingID=UUID()
        // Missing report settings fail before reading any meeting or contacting a backend.
        let job=MeetingWorkJob(meetingID:meetingID,title:"Avviso dimostrativo",kind:.report)
        _=await workQueue.enqueue(job)
        for _ in 0..<300 {
            if await workQueue.snapshot().first(where:{$0.id==job.id})?.state == .failed {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        acceptWork(await workQueue.snapshot())
        var checks=["failed work alert is visible before dismissal":visibleWork.contains{$0.id==job.id}]
        dismissWorkError(job.id)
        for _ in 0..<300 {
            if !visibleWork.contains(where:{$0.id==job.id}) {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        checks["close action hides failed work alert"] = !visibleWork.contains{$0.id==job.id}
        let restored=try MeetingWorkQueue(file:store.root.deletingLastPathComponent().appendingPathComponent("work-queue.json"),execute:{_,_ in})
        let saved=restored.initialSnapshot.first{$0.id==job.id}
        checks["closed work alert stays hidden after queue reload"] = saved?.showsBanner == false && saved?.state == .failed && saved?.error != nil
        let retry=MeetingWorkJob(meetingID:meetingID,title:job.title,kind:.report)
        _=await workQueue.enqueue(retry)
        for _ in 0..<300 {
            if await workQueue.snapshot().first(where:{$0.id==retry.id})?.state == .failed {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        acceptWork(await workQueue.snapshot())
        checks["new failure for same meeting remains visible"] = visibleWork.contains{$0.id==retry.id} && !visibleWork.contains{$0.id==job.id}
        await workQueue.forget(meetingID)
        acceptWork(await workQueue.snapshot())
        return checks
    }

    func checkBackgroundWork(window:NSWindow,root:URL) async throws -> [String:Bool] {
        guard Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil else{return [:]}
        let old=current,oldJobs=workJobs,oldMeetings=meetings,oldTab=tab,oldSection=meetingSection
        let generation=UUID();workPreviewGeneration=generation
        defer { workPreviewGeneration=nil;current=old;workJobs=oldJobs;meetings=oldMeetings;tab=oldTab;meetingSection=oldSection }
        var fixtures:[Meeting]=[]
        for label in ["Trascrizione A","Riunione consultabile","Trascrizione C","Report D"] {
            var meeting=Meeting(title:label,sources:[.system],destination:root,keepAudio:false)
            meeting.state = .interrupted;meeting.notes="Nota da conservare"
            meeting.segments=[Segment(source:.system,start:0,end:1,text:"Test dimostrativo")]
            try store.save(meeting);fixtures.append(meeting)
        }
        let disk=workDisk
        let queue=try MeetingWorkQueue(file:root.appendingPathComponent("ui-queue.json"),probe:{.inactive},execute:{ job,progress in
            await progress("Elaborazione dimostrativa…")
            // Synchronous work deliberately blocks the worker, never MainActor.
            usleep(350000)
            try Task.checkCancellation()
            let original=try await disk.read(job.meetingID)
            var saved=original;saved.state = .complete
            if job.kind == .report {saved.report="Report dimostrativo";saved.reportStatus="Completato"}
            _=try await disk.commit(saved,expected:original,export:false)
        })
        await queue.start(observe:{ [weak self] jobs in Task { @MainActor in
            if self?.workPreviewGeneration==generation {self?.acceptWork(jobs)}
        } })
        for (index,kind) in [(0,MeetingWorkKind.transcription),(2,.transcription),(3,.report),(0,.report)] {
            _=await queue.enqueue(MeetingWorkJob(meetingID:fixtures[index].id,title:fixtures[index].title,kind:kind))
        }
        acceptWork(await queue.snapshot());current=fixtures[0];meetings=fixtures
        var checks=["background job locks edits but permits navigation":sessionLocked && !navigationLocked]
        open(fixtures[1]);tab="session";meetingSection="transcript"
        checks["other meeting opens during background work"] = current?.id==fixtures[1].id
        checks["detail deletion protects queued meeting and permits idle meeting"] = !canManageMeeting(fixtures[0]) && canManageMeeting(fixtures[1])
        let began=ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for:.milliseconds(20))
        checks["background synchronous workload does not stall main actor"] = ProcessInfo.processInfo.systemUptime-began < 0.20
        window.setContentSize(NSSize(width:1000,height:680))
        try await Task.sleep(for:.milliseconds(100))
        if let content=window.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("desktop-background-jobs.png"))
        }
        for _ in 0..<300 {
            if !(await queue.snapshot()).contains(where:{$0.state.pending}) {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        try await Task.sleep(for:.milliseconds(30))
        checks["background completion keeps selected other meeting unchanged"] = current?.id==fixtures[1].id && current?.notes=="Nota da conservare"
        await queue.shutdown()
        return checks
    }
}


extension AppModel {
    /// Simulated callbacks exercise the real recording/document paths. No input
    /// devices, native transcription or screen capture are started.
    func checkRecordingNavigation(window:NSWindow,root:URL) async throws -> [String:Bool] {
        guard Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil else{return [:]}
        let selected=current,oldActive=activeRecording,oldMeetings=meetings,oldTab=tab,oldSection=meetingSection
        let oldStatus=status,oldError=error,oldElapsed=elapsed
        defer {
            previewRecordingHandoff=nil;previewLiveTranscriber=nil;activeRecording=oldActive;isRecording=false;busy=false;working=false
            current=selected;meetings=oldMeetings;tab=oldTab;meetingSection=oldSection
            status=oldStatus;error=oldError;elapsed=oldElapsed;failedProcessing=false
        }
        var live=Meeting(title:"Registrazione attiva · demo",sources:[.system],destination:root,keepAudio:true)
        live.transcriptionTiming = .afterRecording;live.notes="Note della registrazione"
        try store.save(live)
        var history=Meeting(title:"Verbale precedente · demo",sources:[.system],destination:root,keepAudio:false)
        history.state = .complete;history.notes="Note precedenti";history.duration=600
        history.segments=[Segment(source:.system,start:10,end:12,text:"Un passaggio della riunione precedente.")]
        history.report="# Verbale precedente\n\nReport già generato.";history.reportStatus="Completato"
        try store.save(history)
        current=live;activeRecording=live;meetings=[live,history];isRecording=true;elapsed=42
        var checks=["recording permits navigation while keeping active document locked":!navigationLocked && sessionLocked]
        open(history);tab="session";meetingSection="report"
        checks["historical report opens without adopting live duration or state"] = current?.id==history.id && !viewingRecording && current?.duration==600 && recording?.id==live.id
        let link=URL(string:"transcript.md#"+history.segments[0].anchor)!
        checks["historical report references remain navigable during recording"] = openReportSource(link) && focusedSegmentID==history.segments[0].id && recording?.id==live.id
        meetingSection="report"
        let before=try Data(contentsOf:store.workspace(history.id).appendingPathComponent("meeting.json"))
        let chunk=AudioChunk(source:.system,start:0,sampleCount:1600,filename:"audio/navigation-ui.caf")
        try AudioFiles.write([Float](repeating:0,count:1600),to:store.workspace(live.id).appendingPathComponent(chunk.filename))
        try store.append(chunk,id:live.id)
        receive(chunk,id:live.id)
        let savedLive=try store.read(live.id)
        let historyAfter=try Data(contentsOf:store.workspace(history.id).appendingPathComponent("meeting.json"))
        checks["recording callbacks persist to active ID while other meeting is selected"] = savedLive.chunks.count==1 && current?.id==history.id && historyAfter==before
        addMarker(.decision)
        let marked=try store.read(live.id)
        checks["global marker targets active recording not selected history"] = recording?.markers.count==1 && current?.markers.isEmpty==true && marked.markers.count==1
        saveNotes("Note storiche modificate")
        await flushVoiceSaves()
        let noted=try store.read(history.id)
        checks["notes on historical meeting do not overwrite recording notes"] = recording?.notes=="Note della registrazione" && noted.notes=="Note storiche modificate"
        checks["active recording cannot be deleted from archive while browsing elsewhere"] = !canManageMeeting(live)
        let stale=live
        open(stale)
        checks["return to recording uses latest callback snapshot"] = viewingRecording && current?.chunks.count==1 && current?.markers.count==1
        open(history);meetingSection="report";status="Registrazione in corso"
        activeRecording?.transcriptionTiming = .duringRecording
        previewLiveTranscriber={_,source,offset in
            await Task.yield()
            return [Segment(source:source,start:offset,end:offset+0.09,text:"Testo live della registrazione attiva")]
        }
        let second=AudioChunk(source:.system,start:0.1,sampleCount:1600,filename:"audio/navigation-live-ui.caf")
        try AudioFiles.write([Float](repeating:0,count:1600),to:store.workspace(live.id).appendingPathComponent(second.filename))
        try store.append(second,id:live.id);receive(second,id:live.id)
        if let processing {await processing.value}
        let liveText=try store.read(live.id)
        checks["live transcription result stays on recording while historical report is open"] = liveText.segments.contains(where:{$0.text=="Testo live della registrazione attiva"}) && current?.id==history.id && current?.segments.first?.text==history.segments.first?.text
        window.setContentSize(NSSize(width:1000,height:680))
        try await Task.sleep(for:.milliseconds(200))
        if let content=window.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("desktop-recording-browsing.png"))
        }
        var queued:[UUID]=[]
        previewRecordingHandoff={queued.append($0.id)}
        await stop()
        let stopped=try store.read(live.id)
        checks["stop from historical report finalizes and queues only recording ID"] = queued==[live.id] && current?.id==history.id && current?.notes=="Note storiche modificate" && activeRecording == nil && !isRecording && stopped.state == .interrupted
        let historyFinal=try store.read(history.id)
        checks["historical content survives recording stop"] = historyFinal.notes=="Note storiche modificate" && historyFinal.report==history.report && historyFinal.chunks.isEmpty
        return checks
    }
}
