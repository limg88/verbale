import Foundation
import VerbaleCore

enum TranscriptBoundaryChecks {
    static let chunk = AudioChunk(source:.system,start:40.006108874999995,sampleCount:80000,filename:"test.caf")
    static func segment(_ word:String,_ start:Double,_ end:Double,source:AudioSource = .system,speaker:String? = nil) -> Segment {
        Segment(source:source,start:start,end:end,text:word,speakerID:speaker,words:[Word(w:word,start:start,end:end,conf:0.9)])
    }
    static func run() -> Int {
        var failures = 0
        let cases:[(String,() throws -> Void)] = [
            ("timestamp jitter across capture boundary", {
                let old = segment("allenarmi",39.666108875,40.226108875), next = segment("allenarmi",39.726108875,40.286108875)
                let first = TranscriptBoundaries.owned([old],by:AudioChunk(source:.system,start:35.006108875,sampleCount:80000,filename:"a.caf"))
                let second = TranscriptBoundaries.owned([next],by:chunk)
                try VoiceChecks.require(first.count == 1 && second.count == 1,"fixture does not reproduce midpoint jitter")
                let result = TranscriptBoundaries.reconcile(second,existing:first,chunk:chunk)
                try VoiceChecks.require(result.segments.isEmpty && result.edits.count == 1,"duplicate event not reconciled")
                try VoiceChecks.require(result.edits[0].original.words[0].w == "allenarmi" && result.edits[0].duplicates[0].retained.start == old.words[0].start,"original hypothesis not recoverable")
            }),
            ("keep following words and stable segment anchor", {
                let old = segment("allenarmi",39.666108875,40.226108875)
                var next = segment("allenarmi",39.726108875,40.286108875)
                next.words += [Word(w:"con",start:40.3,end:40.5),Word(w:"Giuseppe,",start:40.5,end:41)]
                next.text = "allenarmi con Giuseppe,"; next.end = 41
                let r = TranscriptBoundaries.reconcile([next],existing:[old],chunk:chunk)
                try VoiceChecks.require(r.segments.count == 1 && r.segments[0].id == next.id && r.segments[0].text == "con Giuseppe," && r.segments[0].words.count == 2,"following words, punctuation or anchor changed")
            }),
            ("preserve real repetition and short acknowledgements", {
                let a = segment("no",39.8,40), b = segment("no",40.03,40.23)
                let r = TranscriptBoundaries.reconcile([b],existing:[a],chunk:chunk)
                try VoiceChecks.require(r.edits.isEmpty && r.segments.count == 1,"real repetition removed")
                let short = segment("sì",40,40.08), again = segment("sì",40.02,40.10)
                try VoiceChecks.require(TranscriptBoundaries.reconcile([again],existing:[short],chunk:chunk).edits.isEmpty,"uncertain short acknowledgement removed")
            }),
            ("preserve distinct words and partial overlaps", {
                let a = segment("sì",39.7,40.3), b = segment("si",39.75,40.35)
                try VoiceChecks.require(TranscriptBoundaries.reconcile([b],existing:[a],chunk:chunk).edits.isEmpty,"diacritics erased")
                let c = segment("sì",40.1,40.5)
                try VoiceChecks.require(TranscriptBoundaries.reconcile([c],existing:[a],chunk:chunk).edits.isEmpty,"partial overlap removed")
            }),
            ("isolate sources, speakers and manual edits", {
                let old = segment("parola",39.7,40.3,source:.microphone)
                let next = segment("parola",39.72,40.32)
                try VoiceChecks.require(TranscriptBoundaries.reconcile([next],existing:[old],chunk:chunk).edits.isEmpty,"microphone compared to system")
                let a = segment("parola",39.7,40.3,speaker:"A"), b = segment("parola",39.72,40.32,speaker:"B")
                try VoiceChecks.require(TranscriptBoundaries.reconcile([b],existing:[a],chunk:chunk).edits.isEmpty,"distinct speakers conflated")
                try VoiceChecks.require(TranscriptBoundaries.reconcile([next],existing:[segment("parola",39.7,40.3)],chunk:chunk,protected:[next.id]).edits.isEmpty,"manual incoming correction changed")
            }),
            ("reconcile adjacent VAD regions without rewriting one hypothesis", {
                let a = segment("Parola,",42,42.6), b = segment("parola",42.04,42.64)
                let r = TranscriptBoundaries.reconcile([a,b],existing:[],chunk:chunk)
                try VoiceChecks.require(r.segments.count == 1 && r.segments[0].id == a.id,"overlapping VAD hypotheses retained")
                var repeated = a; repeated.words += b.words; repeated.text = "Parola, parola"
                try VoiceChecks.require(TranscriptBoundaries.reconcile([repeated],existing:[],chunk:chunk).edits.isEmpty,"words from a single hypothesis rewritten")
            }),
            ("legacy, invalid timings and distant text", {
                var invalid = segment("parola",40,40.5); invalid.words[0].start = .nan
                let old = segment("parola",40,40.5)
                try VoiceChecks.require(TranscriptBoundaries.reconcile([invalid],existing:[old],chunk:chunk).edits.isEmpty,"invalid times treated as certain match")
                let distant = segment("parola",10,10.5), duplicate = segment("parola",10.03,10.53)
                try VoiceChecks.require(TranscriptBoundaries.reconcile([duplicate],existing:[distant],chunk:chunk).edits.isEmpty,"old unrelated history changed")
                let legacy = Segment(source:.system,start:40,end:41,text:"Nessun allineamento")
                try VoiceChecks.require(TranscriptBoundaries.reconcile([legacy],existing:[old],chunk:chunk).segments.first?.text == legacy.text,"legacy text changed")
            }),
            ("boundary audit survives export and reopening", {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:root) }
                let store = try SessionStore(root:root.appendingPathComponent("sessions"))
                var meeting = Meeting(title:"Boundaries",sources:[.system],destination:root,keepAudio:false)
                let old = segment("parola",39.7,40.3), next = segment("parola",39.75,40.35)
                meeting.segments = [old]; meeting.appendTranscription([next],for:chunk)
                let saved = try store.export(meeting), reopened = try store.read(saved.id)
                try VoiceChecks.require(reopened.segments.count == 1 && reopened.segments[0].id == old.id && reopened.transcriptBoundaryEdits?.count == 1,"committed text or audit changed")
                let audit = root.appendingPathComponent(saved.folderName).appendingPathComponent("transcript-boundaries.json")
                try VoiceChecks.require(try JSONCoding.decoder().decode([TranscriptBoundaryEdit].self,from:Data(contentsOf:audit)).first?.original.id == next.id,"audit export missing")
            })
        ]
        for (name,body) in cases { do { try body();print("PASS ASR boundary \(name)") } catch { failures += 1; print("FAIL ASR boundary \(name): \(error)") } }
        return failures
    }
}
