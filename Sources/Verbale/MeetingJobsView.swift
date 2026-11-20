import SwiftUI
import VerbaleCore

struct MeetingJobsView:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        ScrollView {
        VStack(alignment:.leading,spacing:8) {
            ForEach(model.visibleWork) { job in
                HStack(spacing:12) {
                    if job.state == .running { ProgressView().controlSize(.small) }
                    else { Image(systemName:job.state == .failed ? "exclamationmark.triangle":"clock").foregroundStyle(job.state == .failed ? Palette.warning:Color.secondary) }
                    VStack(alignment:.leading,spacing:2) {
                        Text((job.kind == .transcription ? "Trascrizione · ":"Report · ")+job.title).font(.callout).lineLimit(1)
                        Text(job.error ?? job.progress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Button("Apri") { if let meeting=model.meetings.first(where:{$0.id==job.meetingID}) { model.open(meeting) } }.disabled(model.navigationLocked)
                    Button { if job.state.pending { model.cancelWork(job.id) } else { model.dismissWorkError(job.id) } } label:{ Image(systemName:"xmark.circle") }.help(job.state.pending ? "Sospendi attività · conserva i risultati salvati":"Chiudi avviso").accessibilityLabel(job.state.pending ? "Sospendi attività":"Chiudi avviso")
                }
            }
        }.padding(.horizontal,24).padding(.vertical,10)
        }.background(Palette.accent.opacity(0.06))
        .frame(height:min(170,CGFloat(model.visibleWork.count)*64))
    }
}
