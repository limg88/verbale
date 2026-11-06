import Foundation
import VerbaleCore

enum RecordingPolicyChecks {
    static func run() -> Int {
        do {
            func check(_ value:Bool,_ label:String) throws { if !value { throw NSError(domain:label,code:1) } }
            let suite = "recording-policy-"+UUID().uuidString,defaults = UserDefaults(suiteName:suite)!
            defer { defaults.removePersistentDomain(forName:suite) }
            try check(TranscriptionTiming.saved(in:defaults) == .afterRecording,"safe default")
            defaults.set("duringRecording",forKey:"transcriptionTiming")
            try check(TranscriptionTiming.saved(in:defaults) == .duringRecording,"explicit live preference")
            var meeting = Meeting(title:"Policy",sources:[.system],destination:FileManager.default.temporaryDirectory,keepAudio:false)
            meeting.transcriptionTiming = .afterRecording;meeting.resumeAfterTeams = true
            let roundTrip = try JSONCoding.decoder().decode(Meeting.self,from:JSONCoding.encoder().encode(meeting))
            try check(roundTrip.transcriptionTiming == .afterRecording && roundTrip.resumeAfterTeams == true,"per-meeting policy persists")
            meeting.transcriptionTiming = nil;meeting.resumeAfterTeams = nil
            let legacy = try JSONCoding.decoder().decode(Meeting.self,from:JSONCoding.encoder().encode(meeting))
            try check(legacy.transcriptionTiming == nil && legacy.resumeAfterTeams == nil,"legacy compatibility")
            try check(!TranscriptionTiming.afterRecording.allowsProcessing(isRecording:true) && TranscriptionTiming.afterRecording.allowsProcessing(isRecording:false) && TranscriptionTiming.duringRecording.allowsProcessing(isRecording:true),"capture and finalization policy")
            print("PASS recording policy defaults to deferred, freezes per meeting and retains explicit live and legacy compatibility")
            var cadence = RecordingExportCadence()
            try check(cadence.shouldExport(isRecording:true,now:0),"initial export")
            cadence.succeeded(at:0)
            var exports = 1
            for second in stride(from:5,through:7200,by:5) {
                if cadence.shouldExport(isRecording:true,now:Double(second)) { exports += 1;cadence.succeeded(at:Double(second)) }
            }
            try check(exports == 241,"two-hour export bound")
            try check(!cadence.shouldExport(isRecording:true,now:7205) && cadence.shouldExport(isRecording:false,now:7205),"final pending audio flush bypasses cadence")
            try check(cadence.shouldExport(isRecording:true,now:0),"clock regression")
            print("PASS recording exports coalesce two-hour workload and always flush at completion")
            return 0
        } catch { print("FAIL recording policy: \(error)");return 1 }
    }
}
