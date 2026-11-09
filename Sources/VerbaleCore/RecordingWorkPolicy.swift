import Foundation

public enum TranscriptionTiming: String, Codable, CaseIterable, Identifiable, Sendable {
    case afterRecording, duringRecording
    public var id: String { rawValue }
    public var label: String { self == .afterRecording ? "Al termine · meno consumi durante la call" : "Durante la registrazione" }
    public static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "transcriptionTiming") ?? "") ?? .afterRecording
    }
    public func allowsProcessing(isRecording: Bool) -> Bool { !isRecording || self == .duringRecording }
}

/// Only presentation exports are coalesced. Durable audio/journal writes and the
/// private meeting manifest are never skipped. Completion bypasses the interval.
public struct RecordingExportCadence {
    private var lastSuccess: TimeInterval?
    public let interval: TimeInterval
    public init(interval: TimeInterval = 30) { self.interval = max(1, interval) }
    public func shouldExport(isRecording: Bool, now: TimeInterval) -> Bool {
        !isRecording || (lastSuccess.map { now - $0 >= interval || now < $0 } ?? true)
    }
    public mutating func succeeded(at now: TimeInterval) { lastSuccess = now }
}
