import SwiftUI
import VerbaleCore

struct ActiveRecordingBanner:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        if let recording=model.recording {
            HStack(spacing:12) {
                Circle().fill(.red).frame(width:8,height:8)
                VStack(alignment:.leading,spacing:2) {
                    Text((model.isRecording ? "In registrazione · ":"Salvataggio · ")+recording.title).font(.callout).fontWeight(.semibold).lineLimit(1)
                    Text(timecode(model.elapsed)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let warning = model.captureWarning { Label(warning,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth:.infinity,alignment:.leading)
                Button("Termina e salva") {Task{await model.stop()}}.disabled(model.busy)
            }.padding(.horizontal,24).padding(.vertical,10).background(Color.red.opacity(0.07))
        }
    }
}
