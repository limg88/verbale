import SwiftUI
import AppKit
import VerbaleCore

@main struct VerbaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            Text(model.status)
            if model.isRecording { Text("In registrazione · " + timecode(model.elapsed)) }
            if model.teamsAutoEnabled { Text(model.teamsStatus) }
            if let error = model.exportError ?? model.error {
                Text("Attenzione: " + error)
                Button("Apri dettagli") { model.showMainWindow() }
            }
            Divider()
            Button("Mostra Verbale") { model.showMainWindow() }
            Button(model.isRecording ? "Termina registrazione" : "Avvia registrazione") {
                Task { if model.isRecording { await model.stop() } else { await model.start() } }
            }.disabled(model.busy || model.reportBusy || (!model.isRecording && model.working))
            Toggle("Registrazione automatica Teams", isOn: $model.teamsAutoEnabled)
            Button("Riduci alla barra dei menu") { model.enterQuietMode() }
            Button("Mostra widget") { model.showWidget() }
            Button("Screenshot") { Task { await model.screenshot() } }.disabled(!model.isRecording)
            Divider()
            Button("Esci da Verbale") { NSApp.terminate(nil) }.disabled(model.busy || model.working || model.reportBusy)
        } label: {
            Image(systemName: model.error != nil || model.exportError != nil ? "exclamationmark.square" : model.isRecording ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .accessibilityLabel(model.isRecording ? "Verbale · registrazione in corso" : "Verbale")
                .help(model.isRecording ? "Verbale · registrazione in corso" : "Verbale · " + model.teamsStatus)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Termina riunione" : "Avvia riunione") {
                    Task { if model.isRecording { await model.stop() } else { await model.start() } }
                }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy || model.reportBusy || (!model.isRecording && model.working))
                Button("Mostra widget") { model.showWidget() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Screenshot della riunione") { Task { await model.screenshot() } }.keyboardShortcut("2", modifiers: [.command, .shift]).disabled(!model.isRecording)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Esci da Verbale") { NSApp.terminate(nil) }.keyboardShortcut("q").disabled(model.busy || model.working || model.reportBusy)
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
        if let root = Bundle.main.object(forInfoDictionaryKey: "VerbalePreviewDataRoot") as? String,
           let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: root).appendingPathComponent("background-ui-checks.json"))
        }
        model.enterQuietMode()
        // Leave the validation task before asking AppKit to terminate.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        if terminationPending { return .terminateCancel }
        if model.busy || model.working || model.reportBusy { return .terminateCancel }
        terminationPending = true
        model.prepareToQuit()
        Task {
            if model.isRecording { await model.stop() }
            await model.engine.unload()
            mayTerminate = true
            sender.terminate(nil)
        }
        // Avoid a nested AppKit termination loop holding the main actor while saving.
        return .terminateCancel
    }
}
