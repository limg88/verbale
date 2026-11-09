import Foundation
import VerbaleCore

enum AudioRoutingChecks {
    static let built = RouteDevice(uid:"builtin",runtimeID:1,name:"Mac",input:true,output:true)
    static let headset = RouteDevice(uid:"headset-stable-uid",runtimeID:2,name:"Cuffie",input:true,output:true)
    static let display = RouteDevice(uid:"display",runtimeID:3,name:"Monitor",input:false,output:true)
    static func run() -> Int {
        var failures = 0
        let cases:[(String,() throws -> Void)] = [
            ("Teams device takes priority over Mac default", {
                let s = AudioRouteSnapshot(devices:[built,headset],defaultInput:1,defaultOutput:1,teamsInput:[2],teamsOutput:[2],activeTeamsInput:[2],activeTeamsOutput:[2])
                let i = try AudioRouteSelection.resolve("automatic",input:true,snapshot:s),o = try AudioRouteSelection.resolve("automatic",input:false,snapshot:s)
                try VoiceChecks.require(i.device.uid == headset.uid && o.device.uid == headset.uid && i.origin == .teams && o.origin == .teams,"call device ignored")
            }),
            ("active call beats inactive Teams routes", {
                let s = AudioRouteSnapshot(devices:[built,headset,display],defaultInput:1,defaultOutput:1,teamsOutput:[2,3],activeTeamsOutput:[2])
                try VoiceChecks.require(try AudioRouteSelection.resolve("automatic",input:false,snapshot:s).device.uid == headset.uid,"inactive helper changed primary route")
            }),
            ("missing or ambiguous Teams route falls back transparently", {
                let none = AudioRouteSnapshot(devices:[built,headset],defaultInput:1,defaultOutput:1)
                try VoiceChecks.require(try AudioRouteSelection.resolve("automatic",input:true,snapshot:none).origin == .macDefault,"no fallback before call starts")
                let ambiguous = AudioRouteSnapshot(devices:[built,headset,display],defaultInput:1,defaultOutput:1,teamsOutput:[2,3],activeTeamsOutput:[2,3])
                let route = try AudioRouteSelection.resolve("automatic",input:false,snapshot:ambiguous)
                try VoiceChecks.require(route.device.uid == built.uid && route.explanation.contains("Più dispositivi"),"ambiguous route guessed silently")
            }),
            ("different active Teams output is visible without overriding manual choice", {
                let s = AudioRouteSnapshot(devices:[built,headset],defaultInput:1,defaultOutput:1,activeTeamsOutput:[2])
                let manual = try AudioRouteSelection.resolve(built.choice,input:false,snapshot:s)
                let correct = try AudioRouteSelection.resolve(headset.choice,input:false,snapshot:s)
                try VoiceChecks.require(AudioRouteSelection.outputMismatchWarning(manual,snapshot:s) != nil,"mismatched output not reported")
                try VoiceChecks.require(AudioRouteSelection.outputMismatchWarning(correct,snapshot:s) == nil,"correct output reported as mismatched")
                var unknown = s; unknown.activeTeamsOutput = []
                try VoiceChecks.require(AudioRouteSelection.outputMismatchWarning(manual,snapshot:unknown) == nil,"unknown route treated as wrong")
            }),
            ("manual and Mac selections override Teams", {
                let s = AudioRouteSnapshot(devices:[built,headset],defaultInput:1,defaultOutput:1,teamsInput:[2],teamsOutput:[2])
                let manual = try AudioRouteSelection.resolve(built.choice,input:true,snapshot:s)
                let mac = try AudioRouteSelection.resolve("mac-default",input:false,snapshot:s)
                try VoiceChecks.require(manual.device.uid == built.uid && manual.origin == .manual && mac.device.uid == built.uid,"automatic selection overrode settings")
                try VoiceChecks.require(AudioRouteSelection.migrated(saved:headset.choice,legacyID:1,devices:[built]) == headset.choice,"saved manual selection was reset")
            }),
            ("manual UID survives changed numeric id and unavailable device is explicit", {
                var reconnected = headset;reconnected.runtimeID = 999
                let s = AudioRouteSnapshot(devices:[built,reconnected,display],defaultInput:1,defaultOutput:1)
                try VoiceChecks.require(try AudioRouteSelection.resolve(headset.choice,input:true,snapshot:s).device.runtimeID == 999,"manual choice tied to old runtime id")
                try VoiceChecks.refuses { _ = try AudioRouteSelection.resolve("device:disconnected",input:true,snapshot:s) }
                try VoiceChecks.refuses { _ = try AudioRouteSelection.resolve(display.choice,input:true,snapshot:s) }
                let invalid = AudioRouteSnapshot(devices:[headset],defaultInput:0,defaultOutput:0)
                try VoiceChecks.refuses { _ = try AudioRouteSelection.resolve("automatic",input:false,snapshot:invalid) }
            }),
            ("legacy manual preference migrates without silent reset", {
                try VoiceChecks.require(AudioRouteSelection.migrated(saved:nil,legacyID:2,devices:[built,headset]) == headset.choice,"legacy manual device not retained")
                try VoiceChecks.require(AudioRouteSelection.migrated(saved:nil,legacyID:0,devices:[built]) == "automatic","new install not automatic")
                let unavailable = AudioRouteSelection.migrated(saved:nil,legacyID:900,devices:[built])
                try VoiceChecks.require(unavailable == "legacy-id:900","missing legacy device silently became auto")
            }),
            ("Teams identity and recorded device metadata", {
                try VoiceChecks.require(AudioRouteSelection.isTeamsBundle("com.microsoft.teams2.helper") && AudioRouteSelection.isTeamsBundle("com.microsoft.teams"),"supported Teams helper excluded")
                try VoiceChecks.require(!AudioRouteSelection.isTeamsBundle("com.microsoft.teams2fake") && !AudioRouteSelection.isTeamsBundle("org.teamspeak"),"unrelated process treated as call")
                // ResolvedAudioDevice is produced by policy, not stored with hardware identifiers.
                let snapshot = AudioRouteSnapshot(devices:[headset],defaultInput:2,defaultOutput:2,teamsInput:[2])
                let route = try AudioRouteSelection.resolve("automatic",input:true,snapshot:snapshot)
                let bytes = try JSONCoding.encoder().encode(RecordedAudioRoute(input:route,output:nil)),text = String(decoding:bytes,as:UTF8.self)
                try VoiceChecks.require(text.contains("Cuffie") && !text.contains(headset.uid),"session metadata exported hardware UID")
            })
        ]
        for (name,body) in cases { do { try body();print("PASS audio routing \(name)") } catch { failures += 1;print("FAIL audio routing \(name): \(error)") } }
        if ProcessInfo.processInfo.environment["VERBALE_TEST_AUDIO_ROUTES"] == "1" {
            do {
                let s = try AudioRouteProbe.snapshot()
                for input in [true,false] {
                    let route = try AudioRouteSelection.resolve("automatic",input:input,snapshot:s)
                    try VoiceChecks.require(s.devices.contains(where: { $0.uid == route.device.uid }),"resolved device absent from actual inventory")
                    print("AUDIO ROUTE \(input ? "input":"output"): \(route.device.name) · \(route.explanation)")
                }
                print("PASS audio routing actual Core Audio metadata without capture")
            } catch { failures += 1;print("FAIL audio routing actual probe: \(error)") }
        }
        return failures
    }
}
