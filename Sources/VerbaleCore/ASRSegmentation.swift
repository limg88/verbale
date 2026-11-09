import Foundation

public enum ASRPass: String, Codable, Sendable { case live, refinement }
public struct SpeechSpan: Sendable {
    public var start:Double
    public var end:Double
    public init(start:Double,end:Double) { self.start = start;self.end = end }
}
public enum ASRSegmentation {
    public static func spans(_ regions:[SpeechSpan],duration:Double,pass:ASRPass) -> [SpeechSpan] {
        guard duration.isFinite,duration > 0 else { return [] }
        let valid = regions.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.end > 0 && $0.start < duration }.sorted { $0.start < $1.start }
        if pass == .live { return valid.map { SpeechSpan(start:max(0,$0.start-0.15),end:min(duration,$0.end+0.15)) } }
        var merged:[SpeechSpan] = []
        for r in valid {
            let r = SpeechSpan(start:max(0,r.start),end:min(duration,r.end))
            if let last = merged.last, r.start-last.end <= 0.6, max(last.end,r.end)-last.start <= 29.6 {
                merged[merged.count-1].end = max(last.end,r.end)
            } else { merged.append(r) }
        }
        var result = merged.map { SpeechSpan(start:max(0,$0.start-0.2),end:min(duration,$0.end+0.2)) }
        if result.count > 1 { for i in 1..<result.count where result[i].start < result[i-1].end {
            let middle = (merged[i-1].end+merged[i].start)/2
            result[i-1].end = middle;result[i].start = middle
        } }
        return result
    }
}
