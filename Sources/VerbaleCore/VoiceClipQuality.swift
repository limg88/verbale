import Foundation

public enum VoiceClipGrade: String, Sendable { case recommended, review, unusable }
/// Signal checks only: this does not identify speakers, detect overlap or estimate a true SNR.
public struct VoiceClipQuality: Sendable {
    public let grade: VoiceClipGrade
    public let levelDB: Double
    public let quietFraction: Double
    public let clippedFraction: Double
    public let reasons: [String]
    public var usable: Bool { grade != .unusable }
    public var label: String { grade == .recommended ? "Segnale consigliato" : grade == .review ? "Da verificare all’ascolto" : "Campione non utilizzabile" }
    public var detail: String { reasons.isEmpty ? "Livello regolare, poche pause e nessuna saturazione rilevante" : reasons.joined(separator: " · ") }
    public static func unavailable(_ message: String) -> VoiceClipQuality {
        VoiceClipQuality(grade: .unusable, levelDB: -120, quietFraction: 1, clippedFraction: 0, reasons: [message])
    }
    public static func measure(_ samples: [Float]) -> VoiceClipQuality {
        guard (48000...129600).contains(samples.count), samples.allSatisfy(\.isFinite) else { return .unavailable("Audio incompleto o non valido") }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        let level = max(-120, 20 * log10(max(rms, 1e-6)))
        let clipped = Double(samples.filter { abs($0) >= 0.999 }.count) / Double(samples.count)
        var energies: [Double] = []
        for start in stride(from: 0, to: samples.count, by: 320) {
            let end = min(start + 320, samples.count)
            energies.append(sqrt(samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(end-start)))
        }
        let threshold = max(0.002, (energies.max() ?? 0) * 0.1)
        let quiet = Double(energies.filter { $0 < threshold }.count) / Double(energies.count)
        var reasons: [String] = []
        if rms <= 0.002 { reasons.append("Volume quasi assente") }
        else if rms < 0.01 { reasons.append("Volume basso") }
        if clipped >= 0.02 { reasons.append("Saturazione frequente") }
        else if clipped >= 0.001 { reasons.append("Alcuni picchi saturi") }
        if quiet > 0.35 { reasons.append("Molte pause o tratti a basso livello") }
        if samples.count < 64000 { reasons.append("Passaggio breve: preferisci almeno 4 secondi") }
        return VoiceClipQuality(grade: rms <= 0.002 || clipped >= 0.02 ? .unusable : reasons.isEmpty ? .recommended : .review,
                                levelDB: level, quietFraction: quiet, clippedFraction: clipped, reasons: reasons)
    }
}
