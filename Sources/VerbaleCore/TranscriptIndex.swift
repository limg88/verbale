import Foundation

/// Construct once per transcript revision; preserve the first non-rejected match.
public struct TranscriptIndex:Sendable {
    public let segments:[Segment]
    public let matches:[UUID:VoiceMatch]
    public let corrected:Set<UUID>
    public init(_ meeting:Meeting) {
        segments=meeting.segments.sorted{$0.start<$1.start}
        var first:[UUID:VoiceMatch]=[:]
        for match in meeting.voiceMatches ?? [] where match.state != .rejected && first[match.segmentID] == nil {first[match.segmentID]=match}
        matches=first;corrected=Set(meeting.corrections.map(\.segmentID))
    }
}
