import SwiftUI
import VerbaleCore

struct RecordingWidget: View {
    @EnvironmentObject var model: AppModel
    private var actionDisabled: Bool { model.busy || model.reportBusy || (model.working && !model.isRecording) || (!model.isRecording && !model.readyToRecord) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.accent)
                Text("Verbale").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                Button { model.widgetPinned.toggle() } label: { Image(systemName: model.widgetPinned ? "pin.fill" : "pin").foregroundStyle(model.widgetPinned ? Palette.accent : .secondary) }
                    .help(model.widgetPinned ? "Disattiva sempre in primo piano" : "Sempre in primo piano")
                    .accessibilityLabel("Sempre in primo piano").accessibilityValue(model.widgetPinned ? "Attivo" : "Disattivo")
                Button { model.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Apri finestra principale").accessibilityLabel("Apri finestra principale")
                Button { model.hideWidget() } label: { Image(systemName: "xmark") }.help("Chiudi widget").accessibilityLabel("Chiudi widget")
            }.buttonStyle(.plain)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text((model.recording ?? model.current)?.title ?? "Pronto quando vuoi").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    StatePill(text: model.isRecording ? "In registrazione" : model.busy ? "Preparazione / finalizzazione" : model.working ? "Trascrizione" : "Sul tuo Mac", color: model.isRecording ? .red : Palette.mint)
                }
                Spacer()
                Text(timecode(model.isRecording || model.activeRecording != nil ? model.elapsed : (model.current?.duration ?? 0))).font(.system(size: 25, weight: .medium, design: .monospaced)).monospacedDigit()
            }
            HStack(spacing: 14) {
                widgetMeter("mic.fill", .microphone, enabled: model.microphone)
                widgetMeter("speaker.wave.2.fill", .system, enabled: model.system)
            }
            HStack {
                Toggle("Salva audio", isOn: $model.keepAudio).toggleStyle(.checkbox).disabled(model.sessionLocked).font(.system(size: 12))
                Spacer()
                if model.busy || model.working { ProgressView().controlSize(.small) }
                Menu {
                    ForEach(MarkerKind.allCases) { kind in
                        Button { model.addMarker(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                    }
                } label: { Label("\((model.recording ?? model.current)?.markers.count ?? 0)", systemImage: "flag") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(!model.isRecording || model.busy)
                    .help("Segna momento · \((model.recording ?? model.current)?.markers.count ?? 0) marcatori")
                Button { Task { await model.screenshot() } } label: { Image(systemName: "camera") }.disabled(!model.isRecording).help("Screenshot").accessibilityLabel("Screenshot")
            }
            Button {
                Task { if model.isRecording { await model.stop() } else { await model.start() } }
            } label: {
                Label(model.isRecording ? "Termina e salva" : model.busy ? "Attendi…" : "Avvia registrazione", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(model.isRecording ? .red : Palette.accent).disabled(actionDisabled)
            if let error = model.exportError ?? model.error {
                Button { model.showMainWindow() } label: { Label(error, systemImage: "exclamationmark.circle").font(.caption).lineLimit(1) }.buttonStyle(.plain).foregroundStyle(.orange)
            } else if !model.isRecording && !model.readyToRecord && !model.busy && !model.working {
                Button("Completa la preparazione nella finestra principale →") { model.showMainWindow() }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text(model.isRecording ? "Puoi continuare a lavorare: Verbale resta qui." : "Trascina il widget dove preferisci.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 360, height: 286)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.1)))
            .tint(Palette.accent)
    }
    private func widgetMeter(_ icon: String, _ source: AudioSource, enabled: Bool) -> some View {
        HStack(spacing: 7) { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary); LiveAudioLevel(state:model.audioLevels,source:source,enabled:enabled,compact:true) }
            .accessibilityElement(children: .combine).accessibilityLabel(source.label)
    }
}
