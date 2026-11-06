import Foundation

public enum MarkerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case important, decision, action
    public var id: String { rawValue }
    public var label: String {
        switch self { case .important: return "Punto importante"; case .decision: return "Decisione"; case .action: return "Azione" }
    }
    public var icon: String {
        switch self { case .important: return "flag"; case .decision: return "checkmark.seal"; case .action: return "checklist" }
    }
}

public struct MeetingMarker: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var timestamp: Double
    public var kind: MarkerKind
    public init(timestamp: Double, kind: MarkerKind) { self.timestamp = timestamp; self.kind = kind }
    public var anchor: String { "marker-" + id.uuidString.lowercased() }
}

public struct SegmentCorrection: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var segmentID: UUID
    public var date: Date
    public var previousText: String
    public var previousSpeakerID: String?
    public var previousWords: [Word]
    public var text: String
    public var speakerID: String?
}

public struct MeetingReview: Codable, Sendable {
    public var markers: [MeetingMarker] = []
    public var corrections: [SegmentCorrection] = []
    public var inputRevision = UUID()
    public init() {}
}

public extension Segment {
    var anchor: String { "segment-" + id.uuidString.lowercased() }
}

public extension Meeting {
    var markers: [MeetingMarker] { review?.markers ?? [] }
    var corrections: [SegmentCorrection] { review?.corrections ?? [] }
    var reportInputRevision: UUID? { review?.inputRevision }
    var reportNeedsUpdate: Bool { report != nil && reportStatus != "Completato" }

    mutating func invalidateReport() {
        if review == nil { review = MeetingReview() }
        review?.inputRevision = UUID()
        if report != nil { reportStatus = "Da rigenerare: contenuti modificati" }
        exported = false
    }

    mutating func addMarker(_ kind: MarkerKind, at timestamp: Double) throws {
        guard timestamp.isFinite, timestamp >= 0 else { throw VerbaleError.message("Timestamp del marcatore non valido") }
        invalidateReport()
        review?.markers.append(MeetingMarker(timestamp: timestamp, kind: kind))
    }

    mutating func removeMarker(_ id: UUID) {
        guard markers.contains(where: { $0.id == id }) else { return }
        invalidateReport()
        review?.markers.removeAll { $0.id == id }
    }

    mutating func correctSegment(_ id: UUID, text: String, speakerID: String?, at date: Date = Date()) throws {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { throw VerbaleError.message("Il segmento non è più disponibile") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VerbaleError.message("La trascrizione del segmento non può essere vuota") }
        let previous = segments[index]
        guard text != previous.text || speakerID != previous.speakerID else { return }
        invalidateReport()
        voiceMatches?.removeAll { $0.segmentID == id }
        review?.corrections.append(SegmentCorrection(segmentID: id, date: date, previousText: previous.text,
            previousSpeakerID: previous.speakerID, previousWords: previous.words, text: text, speakerID: speakerID))
        segments[index].text = text
        segments[index].speakerID = speakerID
        // The original word alignment is retained in history; edited text has no forced alignment.
        if text != previous.text { segments[index].words = [] }
    }

    var reportDocument: String? {
        guard let report else { return nil }
        return reportNeedsUpdate ? "> Da rigenerare: note, marcatori o trascrizione sono cambiati dopo questo report.\n\n" + report : report
    }
}
