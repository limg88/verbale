import Foundation
import VerbaleCore

@main enum VerbaleCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "check-background-work",args.count == 5,let start=Double(args[3]),let end=Double(args[4]) {
                try await BackgroundWorkCheck.run(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2]),start:start,end:end);return
            }
            if args.first == "publish-report",args.count == 3 {
                try ReportCheck.publish(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2])); return
            }
            if args.first == "generate-report",args.count == 6 || (args.count == 7 && args[6] == "--extended") {
                try await ReportCheck.run(input:URL(fileURLWithPath:args[1]),output:URL(fileURLWithPath:args[2]),endpoint:args[3],model:args[4],project:args[5],style:args.count == 7 ? .detailed:.operational); return
            }
            if args == ["audio-route-status"] {
                let snapshot = try AudioRouteProbe.snapshot()
                for input in [true,false] {
                    let route = try AudioRouteSelection.resolve(AudioRouteSelection.automatic,input:input,snapshot:snapshot)
                    print((input ? "Microfono: ":"Uscita: ")+route.device.name+" · "+route.explanation)
                }
                return
            }
            if args.first == "check-transcript-refinement",args.count == 7 || args.count == 8,let start = Double(args[4]),let end = Double(args[5]) {
                try await RefinementCheck.run(input:URL(fileURLWithPath:args[1]),asr:URL(fileURLWithPath:args[2]),vad:URL(fileURLWithPath:args[3]),output:URL(fileURLWithPath:args[6]),start:start,end:end,source:args.count == 8 ? (AudioSource(rawValue:args[7]) ?? .system):.system)
                return
            }
            if args.first == "check-asr-boundaries", args.count == 7, let start = Double(args[4]), let end = Double(args[5]) {
                try await ASRBoundaryCheck.run(input:URL(fileURLWithPath:args[1]),asr:URL(fileURLWithPath:args[2]),vad:URL(fileURLWithPath:args[3]),start:start,end:end,output:URL(fileURLWithPath:args[6]))
                return
            }
            if args.first == "check-meeting-voices", args.count == 6 || (args.count == 7 && args[6] == "--audit") {
                try await MeetingVoiceCheck.run(input:URL(fileURLWithPath:args[1]),diar:URL(fileURLWithPath:args[2]),voice:URL(fileURLWithPath:args[3]),profilesURL:URL(fileURLWithPath:args[4]),output:URL(fileURLWithPath:args[5]),includeAudit:args.count == 7)
                return
            }
            if args.first == "preview-speaker-learning", args.count >= 5 {
                let input = URL(fileURLWithPath:args[1]), analysisURL = URL(fileURLWithPath:args[2]), voice = URL(fileURLWithPath:args[3]), output = URL(fileURLWithPath:args[4],isDirectory:true)
                guard !FileManager.default.fileExists(atPath:output.path) else { throw VerbaleError.message("La cartella di anteprima esiste già.") }
                let original = try Data(contentsOf:input)
                let meeting = try JSONCoding.decoder().decode(Meeting.self,from:original), audit = try SpeakerAudit.load(from:analysisURL)
                let profiles = args.count > 5 ? try JSONCoding.decoder().decode([VoiceProfile].self,from:Data(contentsOf:URL(fileURLWithPath:args[5]))) : []
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let result = try await VoiceAnalysisEngine().reevaluateSpeakers(meeting:meeting,audit:audit,audio:VoiceAudio(workspace:input.deletingLastPathComponent(),exported:URL(fileURLWithPath:meeting.destination).appendingPathComponent(meeting.folderName)),voice:voice,voiceHash:ModelManager.digest(voice),cacheURL:output.appendingPathComponent("speaker-learning-cache.json"),profiles:profiles,progress: { message in FileHandle.standardError.write(Data((message+"\n").utf8)) })
                guard try Data(contentsOf:input) == original else { throw VerbaleError.message("Il file originale è cambiato durante l’anteprima.") }
                let manifest = output.appendingPathComponent("meeting-preview.json")
                try JSONCoding.encoder().encode(result.meeting).write(to:manifest,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
                try result.audit.save(to:output.appendingPathComponent("speaker-analysis-preview.json"))
                print("Anteprima separata: \(result.referenceCount) riferimenti espliciti, \(result.automaticCount) passaggi automatici, \(result.unresolvedCount) incerti; \(result.computedEmbeddings) embedding calcolati, \(result.cacheHits) riusati. Originale invariato.")
                return
            }
            if args.first == "check-speaker-analysis", args.count == 3 {
                let meeting = try JSONCoding.decoder().decode(Meeting.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
                let analysis = try SpeakerAudit.load(from: URL(fileURLWithPath: args[2]))
                guard analysis.isCurrent(for: meeting) else { throw VerbaleError.message("Le proposte non corrispondono alla riunione attuale.") }
                print("Analisi valida: \(analysis.groups.count) gruppi proposti, nessuna assegnazione applicata automaticamente.")
                let triage = SpeakerAuditTriage(audit: analysis, meeting: meeting)
                print("Revisione rapida: \(triage.cases.count) controlli visibili su \(triage.remainingPeopleCount) nomi da confrontare (\(triage.eligibleCount) candidati interni); \(triage.deferredCount) gruppi rimandati all’analisi completa.")
                for item in triage.cases { print("- \(item.title): \(item.examples.count) estratti") }
                return
            }
            if args.first == "analyze-speakers", args.count >= 5 {
                let input = URL(fileURLWithPath: args[1]), diar = URL(fileURLWithPath: args[2]), voice = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
                guard !FileManager.default.fileExists(atPath: output.path) else { throw VerbaleError.message("L’analisi di destinazione esiste già.") }
                let original = try Data(contentsOf: input)
                let meeting = try JSONCoding.decoder().decode(Meeting.self, from: original)
                let audio = VoiceAudio(workspace: input.deletingLastPathComponent(), exported: URL(fileURLWithPath: meeting.destination).appendingPathComponent(meeting.folderName))
                let analysis = try await VoiceAnalysisEngine().auditSpeakers(meeting: meeting, audio: audio, diarization: diar, voice: voice, voiceHash: ModelManager.digest(voice), library: args.count > 5 ? URL(fileURLWithPath: args[5]) : TranscriptionEngine.defaultLibrary, progress: { message in
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                })
                guard try Data(contentsOf: input) == original else { throw VerbaleError.message("Il file originale è cambiato durante l’analisi.") }
                try analysis.save(to: output)
                print("Analisi separata: \(analysis.groups.count) gruppi proposti; originale invariato. OUTPUT: \(output.path)")
                return
            }
            if args.first == "clean-echo", args.count == 4 {
                let mic = URL(fileURLWithPath: args[1]), ref = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
                guard !FileManager.default.fileExists(atPath: out.path) else { throw VerbaleError.message("L’output esiste già: scegli un nuovo file") }
                let microphone = try AudioFiles.samples(mic), render = try AudioFiles.samples(ref)
                var reference = AudioReference(count: microphone.count)
                reference.place(render, start: 0, windowStart: 0)
                let result = try await EchoCancellation().clean(microphone: microphone, reference: reference)
                try AudioFiles.write(result, to: out)
                print("AEC: \(result.count) campioni, 16000 Hz; originali conservati; output: \(out.path)")
                return
            }
            if args == ["teams-status"] {
                print("Teams: \(TeamsCallProbe.sample().rawValue)")
                return
            }
            guard args.first == "transcribe" || args.first == "transcribe-quality" || args.first == "transcribe-live", args.count >= 5 else {
                print("Uso: verbale-cli transcribe <audio> <asr.gguf> <vad.gguf> <cartella-output> [libreria.dylib]")
                return
            }
            let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[4], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let store = try SessionStore(root: output.appendingPathComponent(".recovery"))
            var meeting = Meeting(title: input.deletingPathExtension().lastPathComponent, sources: [.system], destination: output, keepAudio: false)
            meeting.state = .processing; try store.save(meeting)
            let engine = TranscriptionEngine()
            try await engine.load(asr: URL(fileURLWithPath: args[2]), vad: URL(fileURLWithPath: args[3]), library: args.count > 5 ? URL(fileURLWithPath: args[5]) : TranscriptionEngine.defaultLibrary)
            let started = Date(), samples = try AudioFiles.samples(input)
            let quality = args.first == "transcribe-quality",live = args.first == "transcribe-live"
            let step = (quality ? 25:(live ? 5:20))*16000
            for index in stride(from:0,to:samples.count,by:step) {
                let end = min(samples.count,index+step)
                let begin = quality || live ? max(0,index-5*16000):index
                let until = quality || live ? min(samples.count,end+5*16000):end
                let decoded = try await engine.transcribe(samples:Array(samples[begin..<until]),source:.system,offset:Double(begin)/16000,pass:quality ? .refinement:.live)
                let chunk = AudioChunk(source:.system,start:Double(index)/16000,sampleCount:end-index,filename:"diagnostic")
                meeting.appendTranscription(TranscriptBoundaries.owned(decoded,by:chunk),for:chunk)
            }
            meeting.duration = Double(samples.count) / 16000; meeting.state = .complete; meeting = try store.export(meeting)
            await engine.unload()
            print("\(meeting.segments.map(\.text).joined(separator: " "))\nOUTPUT: \(output.appendingPathComponent(meeting.folderName).path)\nAudio: \(meeting.duration)s; elaborazione: \(Date().timeIntervalSince(started))s")
        } catch { FileHandle.standardError.write(Data("Errore: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
