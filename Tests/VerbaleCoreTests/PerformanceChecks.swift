import Foundation
import Darwin
import VerbaleCore

/// Offline workload: two hours of one-source 5s chunks. Contains no meeting audio.
enum PerformanceChecks {
    static func benchmarkEngine(asr:URL,vad:URL,audio:URL) async throws {
        func rss() throws -> Int {
            let process = Process(),pipe = Pipe()
            process.executableURL = URL(fileURLWithPath:"/bin/ps")
            process.arguments = ["-o","rss=","-p",String(ProcessInfo.processInfo.processIdentifier)]
            process.standardOutput = pipe; try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return Int(String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) ?? -1
        }
        let engine = TranscriptionEngine(),samples = try AudioFiles.samples(audio)
        var measurements:[[String:Any]] = []
        func record(_ phase:String) throws { measurements.append(["phase":phase,"rssKiB":try rss()]) }
        try record("baseline")
        for cycle in 1...2 {
            try await engine.load(asr:asr,vad:vad)
            try record("loaded-\(cycle)")
            _ = try await engine.transcribe(samples:Array(samples.prefix(15*16000)),source:.system,offset:0)
            try record("transcribed-\(cycle)")
            await engine.unload()
            try await Task.sleep(for:.milliseconds(300))
            try record("unloaded-\(cycle)")
        }
        do {
            try await engine.load(asr:asr,vad:vad.appendingPathExtension("missing"))
            throw NSError(domain:"benchmark",code:1)
        } catch is VerbaleError { try record("failed-vad-rollback") }
        do { _ = try await engine.transcribe(samples:samples,source:.system,offset:0); throw NSError(domain:"engine-still-loaded",code:1) }
        catch is VerbaleError {}
        print(String(data:try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
    static func benchmarkExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verbale-export-benchmark-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store = try SessionStore(root:root.appendingPathComponent("store"))
        var meeting = Meeting(title:"Synthetic 2h",sources:[.system],destination:root,keepAudio:true)
        try store.save(meeting)
        let bytes = Data(repeating:123,count:320000)
        for i in 0..<1440 {
            let chunk = AudioChunk(source:.system,start:Double(i*5),sampleCount:80000,filename:"audio/\(i).caf")
            try bytes.write(to:store.workspace(meeting.id).appendingPathComponent(chunk.filename))
            meeting.chunks.append(chunk)
            meeting.segments.append(Segment(source:.system,start:Double(i*5),end:Double(i*5+4),text:"Stato del progetto, attività e prossimi passi."))
        }
        meeting = try store.export(meeting)
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        func seconds(_ t:timeval)->Double { Double(t.tv_sec)+Double(t.tv_usec)/1e6 }
        let before = seconds(usage.ru_utime)+seconds(usage.ru_stime),started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 { meeting = try store.export(meeting) }
        getrusage(RUSAGE_SELF,&usage)
        let result:[String:Any] = ["chunks":1440,"audioBytes":1440*320000,"repeatedExports":5,
            "wallSeconds":ProcessInfo.processInfo.systemUptime-started,"cpuSeconds":seconds(usage.ru_utime)+seconds(usage.ru_stime)-before]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
