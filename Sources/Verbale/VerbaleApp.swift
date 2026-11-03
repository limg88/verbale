import SwiftUI
import AppKit
import VerbaleCore

@main struct VerbaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Verbale", id: "main") {
            DashboardView().environmentObject(model).frame(minWidth: 1120, minHeight: 760)
                .tint(.indigo)
                .onAppear { delegate.model = model; NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1240, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "Termina riunione" : "Avvia riunione") { Task { if model.isRecording { await model.stop() } else { await model.start() } } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy)
                Button("Mostra widget") { model.showWidget() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Screenshot della riunione") { Task { await model.screenshot() } }.keyboardShortcut("2", modifiers: [.command, .shift]).disabled(!model.isRecording)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Esci da Verbale") {
                    NSApplication.shared.terminate(nil)
                }.keyboardShortcut("q").disabled(model.busy || model.working)
            }
        }
        MenuBarExtra("Verbale", systemImage: model.isRecording ? "record.circle.fill" : "waveform") {
            Text(model.status)
            Button("Mostra Verbale") { model.showMainWindow() }
            Button(model.isRecording ? "Termina registrazione" : "Avvia registrazione") { Task { if model.isRecording { await model.stop() } else { await model.start() } } }.disabled(model.busy)
            Button("Mostra widget") { model.showWidget() }
            Button("Screenshot") { Task { await model.screenshot() } }.disabled(!model.isRecording)
        }
    }
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy || model.working || model.reportBusy { return .terminateCancel }
        Task {
            if model.isRecording { await model.stop() }
            await model.engine.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
