import Foundation

public struct SpeakerRegion: Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int?
    public init(start: Double, end: Double, speaker: Int?) { self.start = start; self.end = end; self.speaker = speaker }
}

public struct DiarizationResult: Sendable {
    public let segments: [Segment]
    public let replacements: [UUID: [UUID]]
}

public enum SpeakerDiarization {
    public static func split(_ segments: [Segment], regions: [SpeakerRegion], offset: Double = 0, source: AudioSource = .system, protected: Set<UUID> = []) -> DiarizationResult {
        func overlap(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { max(0, min(b, d) - max(a, c)) }
        let sorted = regions.sorted { $0.start < $1.start }
        var maximumEnd: [Double] = []
        for region in sorted { maximumEnd.append(max(maximumEnd.last ?? -.infinity, region.end)) }
        func firstIndex(_ predicate: (Int) -> Bool) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if predicate(mid) { hi = mid } else { lo = mid + 1 } }
            return lo
        }
        var output: [Segment] = [], replacements: [UUID: [UUID]] = [:]
        for segment in segments {
            guard segment.source == source, !protected.contains(segment.id), !segment.words.isEmpty else {
                output.append(segment); replacements[segment.id] = [segment.id]; continue
            }
            var groups: [Segment] = []
            for word in segment.words {
                let begin = word.start - offset, end = word.end - offset
                let lo = firstIndex { maximumEnd[$0] > begin }, hi = firstIndex { sorted[$0].start >= end }
                var known = Set<Int>(), unknown = false
                if lo < hi { for region in sorted[lo..<hi] where overlap(begin, end, region.start, region.end) > 0 {
                    if let speaker = region.speaker { known.insert(speaker) } else { unknown = true }
                } }
                // Overlapping voices are not clean enrollment or recognition material.
                let speaker = known.count == 1 && !unknown ? known.first : nil
                let key = speaker.map { (source == .system ? "Interlocutore " : "Microfono ") + String($0 + 1) }
                if let last = groups.last, last.speakerID == key {
                    groups[groups.count - 1].text += " " + word.w
                    groups[groups.count - 1].end = word.end
                    groups[groups.count - 1].words.append(word)
                } else {
                    var group = Segment(source: source, start: word.start, end: word.end, text: word.w, speakerID: key, words: [word])
                    // Keep the original anchor on the first group and remap references to all splits.
                    if groups.isEmpty { group.id = segment.id }
                    groups.append(group)
                }
            }
            replacements[segment.id] = groups.map(\.id)
            output.append(contentsOf: groups)
        }
        return DiarizationResult(segments: output, replacements: replacements)
    }
}

public extension Meeting {
    mutating func applyDiarization(_ result: DiarizationResult) {
        // Slot numbers are local to one native analysis. They must not inherit names
        // attached to slots from an earlier run merely because the number is reused.
        let protected = voiceProtectedSegments
        let reserved = Set(speakers.keys).union(segments.filter { protected.contains($0.id) }.compactMap(\.speakerID))
        var remapped:[String:String] = [:], used = reserved.union(result.segments.compactMap(\.speakerID))
        segments = result.segments.map { segment in
            var segment = segment
            if !protected.contains(segment.id), let key = segment.speakerID, reserved.contains(key) {
                if remapped[key] == nil {
                    var index = 2, fresh = key + " · analisi 2"
                    while used.contains(fresh) { index += 1; fresh = key + " · analisi \(index)" }
                    remapped[key] = fresh; used.insert(fresh)
                }
                segment.speakerID = remapped[key]
            }
            return segment
        }
        if var audit = echoDuplicates {
            for i in audit.indices {
                audit[i].systemSegments = Array(Set(audit[i].systemSegments.flatMap { result.replacements[$0] ?? [$0] }))
                    .sorted { $0.uuidString < $1.uuidString }
            }
            echoDuplicates = audit
        }
        repairEchoAuditReferences()
        invalidateReport()
    }
}
