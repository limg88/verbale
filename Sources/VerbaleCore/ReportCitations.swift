import Foundation

/// Adjacent citations to nearby transcript fragments become a navigable time
/// range. Original source IDs remain in the generation checkpoints. Distant
/// passages, personal notes, markers and unknown IDs are never conflated.
enum ReportCitations {
    static func compact(_ text:String,meeting:Meeting)->String {
        let segments = meeting.segments.sorted { $0.start < $1.start }
        let run = try! NSRegularExpression(pattern:#"\[\[S[0-9]+\]\](?:[ \t]*(?:,[ \t]*)?\[\[S[0-9]+\]\]){2,}"#)
        let token = try! NSRegularExpression(pattern:#"\[\[S([0-9]+)\]\]"#)
        var output = text
        for match in run.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
            guard let range = Range(match.range,in:text) else { continue }
            let value = String(text[range])
            var indices:[Int] = [],valid = true
            for m in token.matches(in:value,range:NSRange(value.startIndex...,in:value)) {
                guard let r = Range(m.range(at:1),in:value),let index = Int(value[r]),index > 0,index <= segments.count else { valid = false; break }
                if !indices.contains(index-1) { indices.append(index-1) }
            }
            guard valid,!indices.isEmpty else { continue }
            indices.sort { segments[$0].start < segments[$1].start }
            var clusters:[[Int]] = []
            for index in indices {
                if let last = clusters.last,let previous = last.last,
                   segments[index].start-segments[previous].end <= 12,
                   segments[index].end-segments[last[0]].start <= 60 {
                    clusters[clusters.count-1].append(index)
                } else { clusters.append([index]) }
            }
            let citations = clusters.map { cluster -> String in
                guard cluster.count >= 3 else { return cluster.map { "[[S\($0+1)]]" }.joined(separator:" ") }
                let first = segments[cluster[0]],end = cluster.map { segments[$0].end }.max()!
                let names = Set(cluster.map { meeting.speakerName(for:segments[$0]) })
                var label = "\(timecode(first.start))–\(timecode(end))"
                if names.count == 1 { label += " "+meeting.speakerName(for:first) }
                label = label.replacingOccurrences(of:"|",with:"\\|").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]")
                return "[\(label)](transcript.md#\(first.anchor))"
            }.joined(separator:" ")
            if let outRange = Range(match.range,in:output) { output.replaceSubrange(outRange,with:citations) }
        }
        return output
    }
}
