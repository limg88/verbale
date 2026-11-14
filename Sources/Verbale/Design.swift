import SwiftUI
import AppKit
import VerbaleCore

enum Palette {
    static let ink = Color.primary
    static let accent = Color(red: 0.40, green: 0.34, blue: 0.94)
    static let mint = Color(red: 0.20, green: 0.72, blue: 0.63)
    /// Text colours that keep at least 4.5:1 against the window background in both appearances
    /// (system orange and red reach only about 2.2:1 and 3.5:1 on white).
    static let warning = adaptive(light: (0.60, 0.36, 0.00), dark: (1.00, 0.62, 0.04))
    static let danger = adaptive(light: (0.78, 0.11, 0.11), dark: (1.00, 0.45, 0.42))
    /// Accent for small text: the brand accent is too dark on dark backgrounds.
    static let accentText = adaptive(light: (0.40, 0.34, 0.94), dark: (0.62, 0.58, 1.00))
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let hero = LinearGradient(colors: [Color(red: 0.26, green: 0.22, blue: 0.66), Color(red: 0.35, green: 0.33, blue: 0.83), Color(red: 0.23, green: 0.49, blue: 0.69)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct SoundWaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.05, 0.64))
        path.addCurve(to: point(0.28, 0.40), control1: point(0.14, 0.64), control2: point(0.18, 0.40))
        path.addCurve(to: point(0.48, 0.76), control1: point(0.36, 0.40), control2: point(0.39, 0.76))
        path.addCurve(to: point(0.72, 0.12), control1: point(0.58, 0.76), control2: point(0.60, 0.12))
        path.addCurve(to: point(0.95, 0.64), control1: point(0.82, 0.12), control2: point(0.82, 0.64))
        return path
    }
}

struct Surface<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055)))
    }
}

struct StatePill: View {
    let text: String
    var color: Color = Palette.mint
    var body: some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 6, height: 6); Text(text).font(.system(size: 11, weight: .semibold)) }
            .padding(.horizontal, 10).padding(.vertical, 6).background(color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct AudioMeter: View {
    let level: Float
    var color: Color = Palette.mint
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule().fill(Double(index) / 18 < Double(level) ? color : color.opacity(0.15))
                        .frame(width: max(2, (geometry.size.width - 51) / 18), height: CGFloat(7 + (index * 7 % 17)))
                }
            }.frame(height: geometry.size.height)
        }.frame(height: 25).accessibilityLabel("Livello audio").accessibilityValue("\(Int(level * 100)) per cento")
    }
}

struct SourceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var enabled: Bool
    let level: Float
    var locked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(enabled ? Palette.accent : .secondary)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 3)
                Toggle(title, isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(locked)
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            AudioMeter(level: enabled ? level : 0, color: enabled ? Palette.mint : .secondary)
        }.padding(15).background(enabled ? Palette.accent.opacity(0.055) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(enabled ? Palette.accent.opacity(0.18) : .clear))
    }
}

func stateTitle(_ state: SessionState) -> String {
    switch state {
    case .recording: return "Registrazione"
    case .processing: return "In elaborazione"
    case .interrupted: return "Da riprendere"
    case .complete: return "Completata"
    case .failed: return "Da verificare"
    }
}
