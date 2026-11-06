import Foundation

public struct EchoDuplicate: Codable, Identifiable, Sendable {
    public var id: UUID { original.id }
    public var original: Segment
    public var systemSegments: [UUID]
    public var previousSystemSegments: [UUID]?
    public var referenceStatus: String?
    public init(original: Segment, systemSegments: [UUID]) { self.original = original; self.systemSegments = systemSegments }
}

public extension Meeting {
    /// Legacy 0.5.0 diarization replaced UUIDs without a mapping. Re-run only
    /// the original timestamped phrase match and retain the old references as evidence.
    mutating func repairEchoAuditReferences() {
        guard var audit = echoDuplicates else { return }
        let system = segments.filter { $0.source == .system }
        let valid = Set(system.map(\.id))
        for i in audit.indices where audit[i].systemSegments.contains(where: { !valid.contains($0) }) {
            var probe = self
            probe.segments = system + [audit[i].original]; probe.echoDuplicates = nil
            probe.reconcileEchoTranscript(near: audit[i].original.start, end: audit[i].original.end)
            let rebuilt = probe.echoDuplicates?.first?.systemSegments ?? []
            guard !rebuilt.isEmpty, rebuilt.allSatisfy({ valid.contains($0) }) else {
                audit[i].referenceStatus = "unresolved"; continue
            }
            audit[i].previousSystemSegments = Array(Set((audit[i].previousSystemSegments ?? []) + audit[i].systemSegments)).sorted { $0.uuidString < $1.uuidString }
            audit[i].systemSegments = Array(Set(audit[i].systemSegments.filter { valid.contains($0) } + rebuilt)).sorted { $0.uuidString < $1.uuidString }
            audit[i].referenceStatus = "reconstructed-from-words-and-timestamps"
        }
        echoDuplicates = audit
    }
    /// Supplement AEC only for timestamped phrases; short agreements are never removed.
    /// Originals remain auditable even if all microphone words in a segment are echoes.
    mutating func reconcileEchoTranscript(near start: Double, end: Double) {
        guard usesEchoCancellation else { return }
        func key(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        struct RemoteWord {
            let word: Word
            let key: String
            let segmentID: UUID
        }
        let remote = segments.filter { $0.source == .system && $0.end >= start - 7 && $0.start <= end + 7 }.flatMap { segment in
            segment.words.compactMap { word -> RemoteWord? in
                let text = key(word.w)
                return text.isEmpty ? nil : RemoteWord(word: word, key: text, segmentID: segment.id)
            }
        }.sorted { $0.word.start < $1.word.start }
        guard remote.count >= 5 else { return }
        var kept: [Segment] = []
        for var segment in segments {
            guard segment.source == .microphone, segment.end >= start - 5, segment.start <= end + 5, !segment.words.isEmpty else {
                kept.append(segment); continue
            }
            let original = segment
            let words = segment.words.enumerated().filter { !key($0.element.w).isEmpty }
            var removed = Set<Int>(), references = Set<UUID>()
            var i = 0
            while i < words.count {
                var bestLength = 0, bestRemote = 0
                for j in remote.indices where remote[j].key == key(words[i].element.w) {
                    var length = 0
                    while i + length < words.count && j + length < remote.count {
                        let mic = words[i + length].element, system = remote[j + length].word
                        guard key(mic.w) == remote[j + length].key,
                              abs((mic.start + mic.end) / 2 - (system.start + system.end) / 2) <= 0.8 else { break }
                        length += 1
                    }
                    if length > bestLength { bestLength = length; bestRemote = j }
                }
                if bestLength >= 5 {
                    let run = words[i..<(i + bestLength)]
                    let characters = run.reduce(0) { $0 + key($1.element.w).count }
                    let duration = run.last!.element.end - run.first!.element.start
                    if characters >= 20 && duration >= 1 {
                        for index in i..<(i + bestLength) {
                            removed.insert(words[index].offset)
                            references.insert(remote[bestRemote + index - i].segmentID)
                        }
                        i += bestLength; continue
                    }
                }
                i += 1
            }
            guard !removed.isEmpty else { kept.append(segment); continue }
            if echoDuplicates == nil { echoDuplicates = [] }
            if let index = echoDuplicates?.firstIndex(where: { $0.id == original.id }) {
                let existing = echoDuplicates![index].systemSegments
                echoDuplicates![index].systemSegments = Array(Set(existing).union(references)).sorted { $0.uuidString < $1.uuidString }
            } else {
                echoDuplicates?.append(EchoDuplicate(original: original, systemSegments: references.sorted { $0.uuidString < $1.uuidString }))
            }
            segment.words = segment.words.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
            if segment.words.contains(where: { !key($0.w).isEmpty }), let first = segment.words.first, let last = segment.words.last {
                segment.text = segment.words.map(\.w).joined(separator: " ")
                segment.start = first.start; segment.end = last.end
                kept.append(segment)
            }
        }
        segments = kept
    }
}
