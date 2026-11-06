import Foundation

public struct BoundaryDuplicateWord: Codable, Sendable {
    public var originalIndex: Int
    public var retained: Word
}
public struct TranscriptBoundaryEdit: Codable, Identifiable, Sendable {
    public var id: UUID { original.id }
    public var chunkID: UUID
    public var original: Segment
    public var duplicates: [BoundaryDuplicateWord]
}
public struct TranscriptBoundaryResult: Sendable {
    public var segments: [Segment]
    public var edits: [TranscriptBoundaryEdit]
}
public enum TranscriptBoundaries {
    /// Keep the same ownership rule for live recording, recovery and diagnostics.
    public static func owned(_ segments:[Segment],by chunk:AudioChunk) -> [Segment] {
        segments.compactMap { input in
            guard input.source == chunk.source else { return nil }
            let words = input.words.filter { word in
                let middle = (word.start+word.end)/2
                return middle >= chunk.start && middle < chunk.start+chunk.duration
            }
            if !words.isEmpty {
                var segment = input; segment.words = words
                segment.start = words.first!.start; segment.end = words.last!.end
                segment.text = words.map(\.w).joined(separator:" "); return segment
            }
            if input.words.isEmpty && input.start >= chunk.start && input.start < chunk.start+chunk.duration { return input }
            return nil
        }
    }
    private static func key(_ word:Word) -> String {
        word.w.trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
            .precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"it_IT"))
    }
    private static func sameEvent(_ a:Word,_ b:Word) -> Bool {
        guard a.start.isFinite,a.end.isFinite,b.start.isFinite,b.end.isFinite else { return false }
        let da = a.end-a.start, db = b.end-b.start
        guard da >= 0.12, db >= 0.12, abs(a.start-b.start) <= 0.12 else { return false }
        let overlap = max(0,min(a.end,b.end)-max(a.start,b.start))
        let union = max(a.end,b.end)-min(a.start,b.start)
        return overlap/min(da,db) >= 0.85 && overlap/union >= 0.72
    }
    /// Reconcile only new hypotheses. Published text and human corrections never change.
    public static func reconcile(_ incoming:[Segment],existing:[Segment],chunk:AudioChunk,protected:Set<UUID> = []) -> TranscriptBoundaryResult {
        struct Candidate { var word:Word; var speaker:String?; var segmentID:UUID }
        var candidates:[String:[Candidate]] = [:]
        func remember(_ word:Word,speaker:String?,segmentID:UUID) {
            let token = key(word); if !token.isEmpty { candidates[token,default:[]].append(Candidate(word:word,speaker:speaker,segmentID:segmentID)) }
        }
        // Older text can only explain a duplicate very near this block's leading edge.
        for segment in existing where segment.source == chunk.source && segment.end >= chunk.start-0.75 && segment.start <= chunk.start+0.75 {
            for word in segment.words where word.end >= chunk.start-0.75 && word.start <= chunk.start+0.75 { remember(word,speaker:segment.speakerID,segmentID:segment.id) }
        }
        var output:[Segment] = [], edits:[TranscriptBoundaryEdit] = []
        for original in incoming.sorted(by: { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }) {
            guard original.source == chunk.source else { output.append(original); continue }
            var retained:[Word] = [], duplicates:[BoundaryDuplicateWord] = []
            for (index,word) in original.words.enumerated() {
                let token = key(word)
                let match = candidates[token]?.first { prior in
                    guard prior.segmentID != original.id else { return false }
                    // Known different speakers may say the same thing simultaneously.
                    if let a = original.speakerID, let b = prior.speaker, a != b { return false }
                    return sameEvent(word,prior.word)
                }
                if !protected.contains(original.id), let match {
                    duplicates.append(BoundaryDuplicateWord(originalIndex:index,retained:match.word))
                } else { retained.append(word); remember(word,speaker:original.speakerID,segmentID:original.id) }
            }
            if duplicates.isEmpty { output.append(original); continue }
            edits.append(TranscriptBoundaryEdit(chunkID:chunk.id,original:original,duplicates:duplicates))
            if !retained.isEmpty {
                var segment = original; segment.words = retained
                segment.start = retained.first!.start; segment.end = retained.last!.end
                segment.text = retained.map(\.w).joined(separator:" "); output.append(segment)
            }
        }
        return TranscriptBoundaryResult(segments:output,edits:edits)
    }
}
public extension Meeting {
    mutating func appendTranscription(_ incoming:[Segment],for chunk:AudioChunk) {
        let result = TranscriptBoundaries.reconcile(incoming,existing:segments,chunk:chunk,protected:voiceProtectedSegments)
        segments.append(contentsOf:result.segments)
        if !result.edits.isEmpty { transcriptBoundaryEdits = (transcriptBoundaryEdits ?? [])+result.edits }
    }
}
