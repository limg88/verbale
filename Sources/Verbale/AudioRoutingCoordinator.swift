import Foundation
import VerbaleCore

extension AppModel {
    var routeInputs:[RouteDevice] { audioRouteSnapshot?.devices.filter(\.input) ?? [] }
    var routeOutputs:[RouteDevice] { audioRouteSnapshot?.devices.filter(\.output) ?? [] }
    func routeChoiceMissing(_ choice:String,input:Bool) -> Bool {
        choice != AudioRouteSelection.automatic && choice != AudioRouteSelection.macDefault && !(input ? routeInputs:routeOutputs).contains { $0.choice == choice }
    }
    func routeDescription(input:Bool) -> String {
        guard let snapshot = audioRouteSnapshot else { return "Rilevamento in corso…" }
        do {
            let route = try AudioRouteSelection.resolve(input ? inputChoice:outputChoice,input:input,snapshot:snapshot)
            return route.device.name+" · "+route.explanation
        } catch { return error.localizedDescription }
    }
    func refreshAudioRouting() async {
        if Bundle.main.object(forInfoDictionaryKey:"VerbalePreviewDataRoot") != nil && CommandLine.arguments.contains("--check-background-ui") { return }
        guard !routingRefreshing else { return }
        routingRefreshing = true;defer { routingRefreshing = false }
        do { installAudioSnapshot(try await readAudioSnapshot());routingStatus = "" }
        catch { routingStatus = error.localizedDescription }
    }
    func readAudioSnapshot() async throws -> AudioRouteSnapshot {
        let includeTeams = system || inputChoice == AudioRouteSelection.automatic || outputChoice == AudioRouteSelection.automatic
        let query = Task.detached(priority:.utility) { try AudioRouteProbe.snapshot(includeTeams:includeTeams) }
        do { return try await AudioOperationDeadline.wait(for:query,seconds:3) }
        catch CaptureOperationError.timeout { throw VerbaleError.message("Rilevamento dei dispositivi non completato. Riprova con Aggiorna rilevamento nelle Impostazioni.") }
    }
    func installAudioSnapshot(_ snapshot:AudioRouteSnapshot) {
        audioRouteSnapshot = snapshot;routingStatus = ""
        if !routingMigrated {
            let defaults = UserDefaults.standard
            inputChoice = AudioRouteSelection.migrated(saved:defaults.string(forKey:"captureInputChoice"),legacyID:UInt32(clamping:defaults.integer(forKey:"captureInput")),devices:snapshot.devices.filter(\.input))
            outputChoice = AudioRouteSelection.migrated(saved:defaults.string(forKey:"captureOutputChoice"),legacyID:UInt32(clamping:defaults.integer(forKey:"captureOutput")),devices:snapshot.devices.filter(\.output))
            routingMigrated = true
        }
    }
}
