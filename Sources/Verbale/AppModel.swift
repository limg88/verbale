import SwiftUI
import AppKit
import VerbaleCore

@MainActor final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var current: Meeting?
    @Published var title = ""
    @Published var microphone = true
    @Published var system = true
    @Published var keepAudio = RecordingPreferences.keepAudio() {
        didSet { RecordingPreferences.setKeepAudio(keepAudio) }
    }
    @Published var keepRecovery = false
    @Published var inputID: UInt32 = 0
    @Published var outputID: UInt32 = 0
    @Published var inputs = Devices.list(input: true)
    @Published var outputs = Devices.list(input: false)
    @Published var destination: URL?
    @Published var isRecording = false
    @Published var busy = false
    @Published var working = false
    @Published var reportBusy = false
    @Published var status = "Scegli la destinazione e prepara i modelli."
    @Published var exportError: String?
    @Published var error: String?
    @Published var levels: [AudioSource: Float] = [:]
    @Published var installed: Set<String> = []
    @Published var modelWork: String?
    @Published var elapsed: Double = 0
    @Published var tab = "session"
    @Published var widgetVisible = false
    @Published var widgetPinned = true {
        didSet { widgetPanel?.level = widgetPinned ? .floating : .normal }
    }
    @Published var endpoint: String = UserDefaults.standard.string(forKey: "reportEndpoint") ?? "http://localhost:1234/v1"
    @Published var reportModel: String = UserDefaults.standard.string(forKey: "reportModel") ?? ""
    @Published var apiKey = ""
    let store: SessionStore
    let models: ModelManager
    let engine = TranscriptionEngine()
    let capture = CaptureService()
    private var processing: Task<Void, Never>?
    private var timer: Timer?
    private var failedProcessing = false
    private var accessURL: URL?
    private var observers: [NSObjectProtocol] = []
    private var widgetPanel: NSPanel?
    var reopenMainWindow: (() -> Void)?
    var readyToRecord: Bool { installed.isSuperset(of: ["asr", "vad"]) && destination != nil && (microphone || system) && !busy && !working && !reportBusy }
    var sessionLocked: Bool { isRecording || busy || working || reportBusy }
    var audioSavedForDisplay: Bool { isRecording ? (current?.keepAudio ?? keepAudio) : keepAudio }
    func showWidget() {
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
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) { window.makeKeyAndOrderFront(nil) }
        else { reopenMainWindow?() }
    }
    func newMeeting() {
        guard !sessionLocked else { return }
        current = nil; title = ""; tab = "session"; status = "Pronto per una nuova conversazione."
    }
    init() {
        let previewRoot = (Bundle.main.object(forInfoDictionaryKey: "VerbalePreviewDataRoot") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        do { store = try SessionStore(root: previewRoot?.appendingPathComponent("Sessions")); models = try ModelManager(directory: previewRoot?.appendingPathComponent("Models")) }
        catch { fatalError("Impossibile creare la cartella dati Verbale: \(error)") }
        if let data = UserDefaults.standard.data(forKey: "destinationBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                destination = url; if url.startAccessingSecurityScopedResource() { accessURL = url }
                if stale { persistDestination(url) }
            }
        }
        reload()
        Task { await refreshModels() }
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
        try await engine.load(asr: asr, vad: vad, diarization: diar)
    }
    func start() async {
        guard !busy && !isRecording && !reportBusy else { return }
        guard let destination else { chooseDestination(); return }
        let sources = AudioSource.allCases.filter { $0 == .microphone ? microphone : system }
        guard !sources.isEmpty else { error = "Seleziona almeno una sorgente audio."; return }
        busy = true; status = "Preparazione della trascrizione…"; exportError = nil; failedProcessing = false
        do {
            try await loadEngine()
            var meeting = Meeting(title: title, sources: sources, destination: destination, keepAudio: keepAudio)
            meeting.keepRecovery = keepRecovery
            meeting.modelDigests = Dictionary(uniqueKeysWithValues: models.catalog.filter { $0.id != "diarization" }.map { ($0.id, $0.sha256) })
            try store.save(meeting); current = meeting
            // Preflight the selected folder before requesting recording permission.
            current = try store.export(meeting)
            let id = meeting.id
            try await capture.start(sources: sources, input: inputID, output: outputID, folder: store.workspace(id), onChunk: { [weak self] chunk in
                Task { @MainActor in self?.receive(chunk, id: id) }
            }, onLevel: { [weak self] source, level in Task { @MainActor in self?.levels[source] = level } }, onError: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.current?.id == id else { return }
                    self.error = text
                    if self.isRecording { await self.stop() }
                }
            })
            isRecording = true; elapsed = 0; status = "Registrazione in corso"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            reloadWithoutRecovery()
        } catch {
            self.error = error.localizedDescription; status = "Preparazione non riuscita"
            if var meeting = current, meeting.state == .recording { meeting.state = .interrupted; try? store.save(meeting); current = meeting }
        }
        busy = false
    }
    private func tick() {
        guard isRecording, let current else { return }
        elapsed = Date().timeIntervalSince(current.started)
        if elapsed > 12 {
            let absent = current.sources.filter { source in !current.chunks.contains { $0.source == source } }
            if !absent.isEmpty { error = "Nessun buffer ricevuto da: \(absent.map(\.label).joined(separator: ", ")). Verifica dispositivi e permessi."; Task { await stop() } }
        }
    }
    private func receive(_ chunk: AudioChunk, id: UUID) {
        guard var meeting = current, meeting.id == id, !meeting.chunks.contains(where: { $0.id == chunk.id }) else { return }
        meeting.chunks.append(chunk); meeting.duration = max(meeting.duration, chunk.start + chunk.duration); meeting.exported = false
        current = meeting
        do { try store.save(meeting) } catch { self.error = error.localizedDescription; if isRecording { Task { await stop() } } }
        exportCurrent()
        if !failedProcessing { scheduleProcessing() }
    }
    private func scheduleProcessing() {
        guard processing == nil else { return }
        processing = Task { [weak self] in
            await self?.processPending()
            self?.processing = nil
        }
    }
    private func processPending() async {
        working = true; defer { working = false }
        while let meeting = current {
            let eligible = meeting.chunks.filter { !$0.processed }.sorted { $0.start < $1.start }.first { chunk in
                !isRecording || meeting.chunks.contains { $0.source == chunk.source && $0.start > chunk.start }
            }
            guard let chunk = eligible else { break }
            do {
                let siblings = meeting.chunks.filter { $0.source == chunk.source }.sorted { $0.start < $1.start }
                let index = siblings.firstIndex { $0.id == chunk.id }!
                let neighborhood = siblings[max(0, index - 1)...min(index + 1, siblings.count - 1)]
                var audio: [Float] = []; let offset = neighborhood.first!.start
                for item in neighborhood {
                    let start = Int((item.start - offset) * 16000)
                    guard start < 60 * 16000 else { continue }
                    if start > audio.count { audio.append(contentsOf: repeatElement(0, count: start - audio.count)) }
                    let input = try AudioFiles.samples(audioURL(meeting, filename: item.filename))
                    audio.append(contentsOf: input)
                }
                let result = try await engine.transcribe(samples: audio, source: chunk.source, offset: offset)
                let selected = Self.ownedSegments(result, chunk: chunk)
                guard var latest = current, latest.id == meeting.id else { break }
                latest.segments.append(contentsOf: selected)
                if let i = latest.chunks.firstIndex(where: { $0.id == chunk.id }) { latest.chunks[i].processed = true }
                latest.exported = false; current = latest; try store.save(latest); exportCurrent()
            } catch { failedProcessing = true; self.error = "Trascrizione interrotta: \(error.localizedDescription). L'audio resta recuperabile."; break }
        }
    }
    static func ownedSegments(_ segments: [Segment], chunk: AudioChunk) -> [Segment] {
        segments.compactMap { s in
            let words = s.words.filter { let middle = ($0.start + $0.end) / 2; return middle >= chunk.start && middle < chunk.start + chunk.duration }
            if !words.isEmpty { return Segment(source: s.source, start: words.first!.start, end: words.last!.end, text: words.map(\.w).joined(separator: " "), words: words) }
            if s.words.isEmpty && s.start >= chunk.start && s.start < chunk.start + chunk.duration { return s }
            return nil
        }
    }
    func stop() async {
        guard isRecording && !busy else { return }
        busy = true; isRecording = false; timer?.invalidate(); timer = nil; levels = [:]; status = "Finalizzazione…"
        await capture.stop()
        if var meeting = current {
            // Journal replay also accounts for callbacks enqueued just before stop.
            meeting = (try? store.recover(meeting)) ?? meeting
            meeting.state = .processing; current = meeting; try? store.save(meeting)
        }
        if let processing { await processing.value }
        if !failedProcessing { await processPending() }
        finishSession(); busy = false
    }
    private func finishSession() {
        guard var meeting = current else { return }
        meeting.state = failedProcessing ? .failed : .complete
        meeting.exported = false; current = meeting
        do { try store.save(meeting); exportCurrent() } catch { self.error = error.localizedDescription }
        status = failedProcessing ? "Audio salvato · trascrizione da riprendere" : "Riunione completata"
        if let saved = current, saved.exported && !saved.keepRecovery {
            do { try store.cleanupAudio(saved) } catch { self.error = "Output salvato. Non è stato possibile rimuovere l'audio temporaneo: \(error.localizedDescription)" }
        }
        reloadWithoutRecovery()
    }
    func exportCurrent() {
        guard let meeting = current else { return }
        do {
            let saved = try store.export(meeting); current = saved; exportError = nil
            if saved.state == .complete && !saved.keepRecovery { try store.cleanupAudio(saved) }
        }
        catch { exportError = error.localizedDescription }
    }
    func exportElsewhere() { chooseDestination(); guard var meeting = current, let destination else { return }; meeting.destination = destination.path; meeting.exported = false; current = meeting; exportCurrent(); reloadWithoutRecovery() }
    func open(_ meeting: Meeting) { guard !busy && !isRecording && !working else { return }; current = meeting; title = meeting.title; tab = "session" }
    func resume() async {
        guard var meeting = current, !busy && !isRecording else { return }
        busy = true; failedProcessing = false; status = "Ripresa dell'elaborazione…"
        do {
            try await loadEngine(); meeting = try store.recover(meeting); meeting.state = .processing; current = meeting
            try store.save(meeting); await processPending(); finishSession()
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    func saveNotes(_ notes: String) { guard var meeting = current else { return }; meeting.notes = notes; meeting.exported = false; current = meeting; try? store.save(meeting); exportCurrent() }
    func rename(_ id: String, to name: String) { guard var meeting = current else { return }; meeting.speakers[id] = name; current = meeting; try? store.save(meeting); exportCurrent() }
    func reveal() { guard let meeting = current else { return }; NSWorkspace.shared.open(URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName)) }
    func delete(_ meeting: Meeting) {
        guard !isRecording && !busy && !working else { return }
        let alert = NSAlert(); alert.messageText = "Rimuovere la copia temporanea di questa riunione?"
        alert.informativeText = meeting.exported ? "I file nella cartella di destinazione restano sul disco. La rielaborazione richiede l'audio conservato." : "Questa sessione non risulta esportata: rimuovendola potresti perdere l'unica copia. Aprila ed esportala prima di procedere."
        alert.addButton(withTitle: "Rimuovi"); alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.deleteWorkspace(meeting.id); if current?.id == meeting.id { current = nil }; reloadWithoutRecovery() } catch { self.error = error.localizedDescription }
    }
    func screenshot() async {
        guard let meeting = current, isRecording else { return }
        let id = meeting.id, timestamp = elapsed
        let folder = store.workspace(id).appendingPathComponent("screenshots")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = "screenshots/\(UUID().uuidString).png", target = store.workspace(id).appendingPathComponent(filename)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); process.arguments = ["-i", "-o", "-x", target.path]
            try process.run()
            await withCheckedContinuation { continuation in DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() } }
            guard FileManager.default.fileExists(atPath: target.path), var latest = current, latest.id == id else { return }
            latest.screenshots.append(Screenshot(timestamp: timestamp, filename: filename)); current = latest; try store.save(latest); exportCurrent()
        } catch { self.error = error.localizedDescription }
    }
    func report() async {
        guard let meeting = current, !reportBusy && !isRecording && !busy else { return }
        do { if !apiKey.isEmpty { try Keychain.save(apiKey) } } catch { self.error = error.localizedDescription; return }
        UserDefaults.standard.set(endpoint, forKey: "reportEndpoint"); UserDefaults.standard.set(reportModel, forKey: "reportModel")
        reportBusy = true; defer { reportBusy = false }
        do {
            let text = try await ReportService.generate(meeting: meeting, endpoint: endpoint, model: reportModel, key: apiKey.isEmpty ? Keychain.read() : apiKey)
            guard var latest = current, latest.id == meeting.id else { return }
            latest.report = text; latest.reportStatus = "Completato"; current = latest; try store.save(latest); exportCurrent()
        } catch { self.error = error.localizedDescription }
    }
    func separateSpeakers() async {
        guard let meeting = current, !busy && !isRecording && !working else { return }
        busy = true; status = "Separazione degli interlocutori…"; defer { busy = false }
        do {
            try await loadEngine(diarization: true)
            let chunks = meeting.chunks.filter { $0.source == .system }.sorted { $0.start < $1.start }
            guard let end = chunks.last.map({ $0.start + $0.duration }), end <= 1800 else { throw VerbaleError.message("Per questa versione la diarizzazione offline è limitata a 30 minuti. La trascrizione resta disponibile.") }
            var samples = [Float](repeating: 0, count: Int(end * 16000) + 1)
            for chunk in chunks {
                let audio = try AudioFiles.samples(audioURL(meeting, filename: chunk.filename))
                let start = Int(chunk.start * 16000); let count = min(audio.count, samples.count - start)
                samples.replaceSubrange(start..<(start + count), with: audio.prefix(count))
            }
            let result = try await engine.diarize(samples: samples, segments: meeting.segments)
            guard var latest = current, latest.id == meeting.id else { return }
            latest.segments = result; latest.modelDigests["diarization"] = models.catalog.first { $0.id == "diarization" }?.sha256
            current = latest; try store.save(latest); exportCurrent(); status = "Interlocutori separati: puoi rinominarli."
        } catch { self.error = error.localizedDescription }
    }
    private func reloadWithoutRecovery() { meetings = (try? store.list()) ?? [] }
    private func audioURL(_ meeting: Meeting, filename: String) -> URL {
        let local = store.workspace(meeting.id).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName).appendingPathComponent(filename)
    }
}
