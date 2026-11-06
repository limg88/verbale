import Foundation
import CryptoKit
import VerbaleCore

private final class ReportTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let file:FileHandle
    init(_ url:URL) throws {
        FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])
        file = try FileHandle(forWritingTo:url)
    }
    deinit { try? file.close() }
    func append(_ metric:ReportMetric) {
        lock.lock(); defer { lock.unlock() }
        if var data = try? JSONEncoder().encode(metric) { data.append(10); try? file.write(contentsOf:data); try? file.synchronize() }
    }
}
enum ReportCheck {
    static func publish(input:URL,output:URL) throws {
        let original = try Data(contentsOf:input)
        let snapshot = try Data(contentsOf:output.appendingPathComponent("meeting-input.json"))
        guard SHA256.hash(data:original) == SHA256.hash(data:snapshot) else { throw VerbaleError.message("La riunione è cambiata: pubblicazione annullata.") }
        var meeting = try JSONCoding.decoder().decode(Meeting.self,from:original)
        guard meeting.state == .complete else { throw VerbaleError.message("La riunione non è completa.") }
        let report = try String(contentsOf:output.appendingPathComponent("report.md"),encoding:.utf8)
        let headings = ["Sintesi per il project manager","Fatti e avanzamenti","Decisioni","Attività e responsabilità","Rischi e problemi aperti","Opportunità","Punti da chiarire"]
        guard report.hasPrefix("# "+meeting.title+"\n"),!report.contains("fonte non verificata"),
              headings.allSatisfy({ report.components(separatedBy:"## "+$0+"\n").count == 2 }) else { throw VerbaleError.message("Il report non supera i controlli di pubblicazione.") }
        let store = try SessionStore(root:input.deletingLastPathComponent().deletingLastPathComponent())
        let backup = output.appendingPathComponent("publication-backup")
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try original.write(to:backup.appendingPathComponent("meeting-before-publication.json"),options:.atomic)
        meeting.report = report; meeting.reportStatus = "Completato"; meeting.exported = false
        _ = try store.export(meeting)
        let saved = try store.read(meeting.id)
        guard saved.report == report && saved.reportStatus == "Completato" else { throw VerbaleError.message("Verifica del report pubblicato non riuscita.") }
        print("PUBLISHED report for \(meeting.id) · \(report.utf8.count) bytes")
    }
    static func run(input:URL,output:URL,endpoint:String,model:String,project:String,style:ReportStyle = .operational) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let original = try Data(contentsOf:input)
        let meeting = try JSONCoding.decoder().decode(Meeting.self,from:original)
        try original.write(to:output.appendingPathComponent("meeting-input.json"),options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.appendingPathComponent("meeting-input.json").path)
        let checkpoints = output.appendingPathComponent("report-jobs")
        let previous = input.deletingLastPathComponent().appendingPathComponent("report-jobs")
        if !fm.fileExists(atPath:checkpoints.path),fm.fileExists(atPath:previous.path) { try fm.copyItem(at:previous,to:checkpoints) }
        let trace = try ReportTrace(output.appendingPathComponent("metrics.jsonl"))
        let key = try LocalGateway.readToken(project:project)
        let started = Date()
        do {
            let report = try await ReportService.generate(meeting:meeting,endpoint:endpoint,model:model,key:key,style:style,checkpointDirectory:checkpoints,
                diagnostics:{ trace.append($0) },progress:{ text in
                    FileHandle.standardError.write(Data((ISO8601DateFormatter().string(from:Date())+" "+text+"\n").utf8))
                })
            guard try SHA256.hash(data:Data(contentsOf:input)) == SHA256.hash(data:original) else { throw VerbaleError.message("La riunione originale è cambiata durante la prova; nessuna pubblicazione automatica.") }
            try report.write(to:output.appendingPathComponent("report.md"),atomically:true,encoding:.utf8)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.appendingPathComponent("report.md").path)
            let transcript = meeting.segments.sorted { $0.start < $1.start }.map { "<a id=\"\($0.anchor)\"></a>\n\n[\(timecode($0.start))] **\(meeting.speakerName(for:$0))**: \($0.text)" }.joined(separator:"\n\n")
            try transcript.write(to:output.appendingPathComponent("transcript.md"),atomically:true,encoding:.utf8)
            try meeting.notes.write(to:output.appendingPathComponent("notes.md"),atomically:true,encoding:.utf8)
            for name in ["transcript.md","notes.md"] { try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.appendingPathComponent(name).path) }
            print("SUCCESS report: \(output.appendingPathComponent("report.md").path); seconds=\(Date().timeIntervalSince(started)); bytes=\(report.utf8.count)")
        } catch {
            let detail:[String:String] = ["kind":(error as? ReportServiceError).map { String(describing:$0.kind) } ?? String(describing:type(of:error)),"message":error.localizedDescription]
            try? JSONSerialization.data(withJSONObject:detail,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("failure.json"),options:.atomic)
            throw error
        }
    }
}
