import Foundation
import CoreAudio

public struct RouteDevice:Identifiable,Hashable,Sendable {
    public var id:String { uid }
    public var uid:String
    public var runtimeID:UInt32
    public var name:String
    public var input:Bool
    public var output:Bool
    public init(uid:String,runtimeID:UInt32,name:String,input:Bool,output:Bool) { self.uid = uid;self.runtimeID = runtimeID;self.name = name;self.input = input;self.output = output }
    public var choice:String { "device:"+uid }
}
public struct AudioRouteSnapshot:Sendable {
    public var devices:[RouteDevice]
    public var defaultInput:UInt32
    public var defaultOutput:UInt32
    public var teamsInput:Set<UInt32>
    public var teamsOutput:Set<UInt32>
    public var activeTeamsInput:Set<UInt32>
    public var activeTeamsOutput:Set<UInt32>
    public init(devices:[RouteDevice],defaultInput:UInt32,defaultOutput:UInt32,teamsInput:Set<UInt32> = [],teamsOutput:Set<UInt32> = [],activeTeamsInput:Set<UInt32> = [],activeTeamsOutput:Set<UInt32> = []) {
        self.devices = devices;self.defaultInput = defaultInput;self.defaultOutput = defaultOutput;self.teamsInput = teamsInput;self.teamsOutput = teamsOutput;self.activeTeamsInput = activeTeamsInput;self.activeTeamsOutput = activeTeamsOutput
    }
}
public enum RouteOrigin:String,Codable,Sendable { case teams, macDefault, manual }
public struct ResolvedAudioDevice:Sendable {
    public var device:RouteDevice
    public var origin:RouteOrigin
    public var explanation:String
}
public struct RecordedAudioRoute:Codable,Sendable {
    public var inputName:String?
    public var outputName:String?
    public var inputOrigin:RouteOrigin?
    public var outputOrigin:RouteOrigin?
    public init(input:ResolvedAudioDevice?,output:ResolvedAudioDevice?) {
        inputName = input?.device.name;outputName = output?.device.name;inputOrigin = input?.origin;outputOrigin = output?.origin
    }
}
public enum AudioRouteSelection {
    public static let automatic = "automatic"
    public static let macDefault = "mac-default"
    public static func migrated(saved:String?,legacyID:UInt32,devices:[RouteDevice]) -> String {
        if let saved { return saved }
        if legacyID == 0 { return automatic }
        return devices.first { $0.runtimeID == legacyID }?.choice ?? "legacy-id:\(legacyID)"
    }
    public static func resolve(_ choice:String,input:Bool,snapshot:AudioRouteSnapshot) throws -> ResolvedAudioDevice {
        let available = snapshot.devices.filter { input ? $0.input:$0.output }
        let label = input ? "microfono":"uscita audio"
        if choice != automatic && choice != macDefault {
            guard choice.hasPrefix("device:"),let device = available.first(where: { $0.choice == choice }) else {
                throw VerbaleError.message("Il dispositivo scelto manualmente per \(label) non è disponibile. Selezionalo nelle Impostazioni oppure scegli Automatico.")
            }
            return ResolvedAudioDevice(device:device,origin:.manual,explanation:"Scelta manuale")
        }
        var ambiguous = false
        if choice == automatic {
            let all = input ? snapshot.teamsInput:snapshot.teamsOutput
            let active = input ? snapshot.activeTeamsInput:snapshot.activeTeamsOutput
            let activeDevices = available.filter { active.contains($0.runtimeID) }
            let candidates = activeDevices.isEmpty ? available.filter { all.contains($0.runtimeID) }:activeDevices
            if candidates.count == 1 { return ResolvedAudioDevice(device:candidates[0],origin:.teams,explanation:"Rilevato da Teams") }
            ambiguous = candidates.count > 1
        }
        let id = input ? snapshot.defaultInput:snapshot.defaultOutput
        guard let device = available.first(where: { $0.runtimeID == id }) else { throw VerbaleError.message("Nessun dispositivo predefinito disponibile per \(label). Scegli un dispositivo nelle Impostazioni.") }
        return ResolvedAudioDevice(device:device,origin:.macDefault,explanation:choice == macDefault ? "Predefinito del Mac":(ambiguous ? "Più dispositivi Teams: uso il predefinito del Mac":"Teams non espone un dispositivo: uso il predefinito del Mac"))
    }
    public static func outputMismatchWarning(_ output: ResolvedAudioDevice?, snapshot: AudioRouteSnapshot) -> String? {
        guard let output, !snapshot.activeTeamsOutput.isEmpty,
              !snapshot.activeTeamsOutput.contains(output.device.runtimeID) else { return nil }
        return "L’uscita registrata (\(output.device.name)) è diversa dall’uscita attiva di Teams. Seleziona in Verbale la stessa uscita di Teams oppure Automatico; le voci remote potrebbero mancare."
    }
    public static func isTeamsBundle(_ value:String) -> Bool {
        let value = value.lowercased()
        return ["com.microsoft.teams","com.microsoft.teams2"].contains { value == $0 || value.hasPrefix($0+".") }
    }
}
/// Metadata only: never starts an audio engine, tap or microphone permission prompt.
public enum AudioRouteProbe {
    private static func ids(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32] {
        var property = AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain),size:UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object,&property,0,nil,&size) == noErr else { return [] }
        var values = [UInt32](repeating:0,count:Int(size)/MemoryLayout<UInt32>.size)
        guard !values.isEmpty,AudioObjectGetPropertyData(object,&property,0,nil,&size,&values) == noErr else { return [] };return values
    }
    private static func string(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector) -> String {
        var property = AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain),value:CFString = "" as CFString,size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to:&value) { AudioObjectGetPropertyData(object,&property,0,nil,&size,$0) }
        return result == noErr ? value as String:""
    }
    private static func flag(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector) -> Bool {
        ids(object,selector).first == 1
    }
    public static func snapshot(includeTeams:Bool = true) throws -> AudioRouteSnapshot {
        let system = AudioObjectID(kAudioObjectSystemObject),all = ids(system,kAudioHardwarePropertyDevices)
        guard !all.isEmpty else { throw VerbaleError.message("Non riesco a leggere i dispositivi audio del Mac. Riprova da Impostazioni → Dispositivi audio.") }
        let devices:[RouteDevice] = all.compactMap { id in
            guard flag(id,kAudioDevicePropertyDeviceIsAlive) else { return nil }
            let name = string(id,kAudioObjectPropertyName),uid = string(id,kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty,name != "Verbale Capture" else { return nil }
            return RouteDevice(uid:uid,runtimeID:id,name:name.isEmpty ? "Dispositivo audio":name,input:!ids(id,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput).isEmpty,output:!ids(id,kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput).isEmpty)
        }.filter { $0.input || $0.output }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var result = AudioRouteSnapshot(devices:devices,defaultInput:ids(system,kAudioHardwarePropertyDefaultInputDevice).first ?? 0,defaultOutput:ids(system,kAudioHardwarePropertyDefaultOutputDevice).first ?? 0)
        guard includeTeams else { return result }
        for process in ids(system,kAudioHardwarePropertyProcessObjectList) where AudioRouteSelection.isTeamsBundle(string(process,kAudioProcessPropertyBundleID)) {
            let input = Set(ids(process,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeInput)),output = Set(ids(process,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeOutput))
            result.teamsInput.formUnion(input);result.teamsOutput.formUnion(output)
            if flag(process,kAudioProcessPropertyIsRunningInput) { result.activeTeamsInput.formUnion(input) }
            if flag(process,kAudioProcessPropertyIsRunningOutput) { result.activeTeamsOutput.formUnion(output) }
        }
        return result
    }
}
