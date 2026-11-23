import Foundation

public enum VerbaleError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone, system
    public var id: String { rawValue }
    public var label: String { self == .microphone ? "Microfono" : "Audio di sistema" }
}
public enum SessionState: String, Codable, Sendable { case recording, interrupted, processing, complete, failed }
public struct Word: Codable, Sendable {
    public var w: String
    public var start: Double
    public var end: Double
    public var conf: Double?
    public init(w: String, start: Double, end: Double, conf: Double? = nil) {
        self.w = w; self.start = start; self.end = end; self.conf = conf
    }
}
public struct Segment: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var speakerID: String?
    public var words: [Word]
    public init(source: AudioSource, start: Double, end: Double, text: String, speakerID: String? = nil, words: [Word] = []) {
        self.source = source; self.start = start; self.end = end; self.text = text; self.speakerID = speakerID; self.words = words
    }
}
public struct AudioChunk: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var source: AudioSource
    public var start: Double
    public var sampleCount: Int
    public var filename: String
    public var processed: Bool = false
    /// Optional for older journals; raw `filename` is never replaced.
    public var cleanedFilename: String?
    /// Samples in roughly one-second windows whose RMS exceeded -50 dBFS.
    /// Older recordings and processed copies can omit this measurement.
    public var audibleSampleCount: Int?
    public var duration: Double { Double(sampleCount) / 16000 }
    public init(source: AudioSource, start: Double, sampleCount: Int, filename: String, audibleSampleCount: Int? = nil) {
        self.source = source; self.start = start; self.sampleCount = sampleCount; self.filename = filename
        self.audibleSampleCount = audibleSampleCount
    }
}
public struct Screenshot: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var timestamp: Double
    public var filename: String
    public init(timestamp: Double, filename: String) { self.timestamp = timestamp; self.filename = filename }
}
public struct MeetingParticipant: Codable, Equatable, Sendable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}
public struct Meeting: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id = UUID()
    public var title: String
    public var started = Date()
    public var timezone = TimeZone.current.identifier
    public var state: SessionState = .recording
    public var duration: Double = 0
    public var sources: [AudioSource]
    public var destination: String
    public var folderName: String
    public var keepAudio: Bool
    public var keepRecovery: Bool = false
    public var notes = ""
    public var chunks: [AudioChunk] = []
    public var segments: [Segment] = []
    public var screenshots: [Screenshot] = []
    public var speakers: [String: String] = [:]
    public var calendarEventUID: String?
    public var onlineMeetingURL: URL?
    public var participants: [MeetingParticipant]?
    public var modelDigests: [String: String] = [:]
    public var warnings: [String] = []
    public var actionProposals: [ActionProposal]?
    public var report: String?
    public var reportStatus: String = "Non richiesto"
    public var exported = false
    public var exportedAt: Date?
    public var exportRevision: Int?
    // Optional for compatibility with sessions saved before review tools existed.
    public var review: MeetingReview?
    public var listeningMode: ListeningMode?
    public var echoDuplicates: [EchoDuplicate]?
    /// v2 keeps a sample-count clock across callbacks/chunks and flushes the converter.
    public var captureTimelineVersion: Int?
    public var echoProcessingVersion: Int?
    public var voiceMatches: [VoiceMatch]?
    public var audioRoute:RecordedAudioRoute?
    public var audioRouteChanges: [RecordedAudioRouteChange]?
    public var latestAudioRoute: RecordedAudioRoute? { audioRouteChanges?.last?.route ?? audioRoute }
    public var transcriptionTiming: TranscriptionTiming?
    public var resumeAfterTeams: Bool?
    /// Original ASR hypotheses retained when overlapping windows duplicate a word.
    public var transcriptBoundaryEdits: [TranscriptBoundaryEdit]?
    public init(title: String, sources: [AudioSource], destination: URL, keepAudio: Bool) {
        self.title = title.isEmpty ? "Riunione" : title
        self.sources = sources; self.destination = destination.path; self.keepAudio = keepAudio
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let safe = self.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        folderName = "\(formatter.string(from: started))_\(safe.prefix(60))_\(id.uuidString.prefix(8))"
    }
    public func speakerName(for segment: Segment) -> String {
        if let id = segment.speakerID { return speakers[id] ?? id }
        return segment.source.label
    }
}
public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
    }
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
public func timecode(_ seconds: Double) -> String {
    let s = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
