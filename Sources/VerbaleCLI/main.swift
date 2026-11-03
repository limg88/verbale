import Foundation
import VerbaleCore

@main enum VerbaleCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.first == "transcribe", args.count >= 5 else {
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
            for index in stride(from: 0, to: samples.count, by: 20 * 16000) {
                let end = min(samples.count, index + 20 * 16000)
                meeting.segments += try await engine.transcribe(samples: Array(samples[index..<end]), source: .system, offset: Double(index) / 16000)
            }
            meeting.duration = Double(samples.count) / 16000; meeting.state = .complete; meeting = try store.export(meeting)
            await engine.unload()
            print("\(meeting.segments.map(\.text).joined(separator: " "))\nOUTPUT: \(output.appendingPathComponent(meeting.folderName).path)\nAudio: \(meeting.duration)s; elaborazione: \(Date().timeIntervalSince(started))s")
        } catch { FileHandle.standardError.write(Data("Errore: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
