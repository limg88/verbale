import SwiftUI
import VerbaleCore

/// Meter updates invalidate only the small meter views, never the transcript,
/// archive, or AppModel's observers.
@MainActor final class AudioLevelState: ObservableObject {
    @Published var values:[AudioSource:Float] = [:]
}
struct LiveAudioLevel: View {
    @ObservedObject var state:AudioLevelState
    let source:AudioSource
    var enabled = true
    var compact = false
    var body:some View {
        let level = enabled ? (state.values[source] ?? 0):0
        if compact { AudioMeter(level:level) }
        else { ProgressView(value:min(1,max(0,Double(level)))).frame(width:90) }
    }
}
