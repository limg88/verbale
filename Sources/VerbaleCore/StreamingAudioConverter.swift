import Foundation
import AVFoundation

/// The callback clock detects discontinuities; saved audio advances on its own sample clock.
public struct AudioSampleClock {
    public private(set) var nextStart: Double
    public init(start: Double) { nextStart = start }
    public mutating func advance(samples: Int) {
        precondition(samples >= 0)
        nextStart += Double(samples) / 16000
    }
}

/// Stateful streaming conversion: respect requested input packets, drain every
/// output buffer, and flush the final filter tail. Never discard an unrequested input.
public final class StreamingAudioConverter {
    private let converter: AVAudioConverter
    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var inputFrames: Int64 = 0
    private var emittedFrames = 0
    private var finished = false
    public init(format: AVAudioFormat) throws {
        inputFormat = format
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else { throw VerbaleError.message("Formato dispositivo non supportato") }
        self.converter = converter
    }
    public func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard !finished, input.format == inputFormat else { throw VerbaleError.message("Formato audio cambiato durante l’acquisizione") }
        inputFrames += Int64(input.frameLength)
        return try drain(input: input)
    }
    public func finish() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        return try drain(input: nil)
    }
    private func drain(input: AVAudioPCMBuffer?) throws -> [Float] {
        var offset: AVAudioFrameCount = 0
        var result: [Float] = []
        var loaned: AVAudioPCMBuffer?
        var copyError: Error?
        let limit = max(64, Int(Double(input?.frameLength ?? 0) * 16000 / inputFormat.sampleRate / 4096) + 64)
        for _ in 0..<limit {
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                guard let input else { state.pointee = .endOfStream; return nil }
                guard offset < input.frameLength else { state.pointee = .noDataNow; return nil }
                let count = min(requested, input.frameLength - offset)
                guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: count) else {
                    copyError = VerbaleError.message("Buffer conversione audio non disponibile")
                    state.pointee = .noDataNow; return nil
                }
                buffer.frameLength = count
                let bytesPerFrame = Int(self.inputFormat.streamDescription.pointee.mBytesPerFrame)
                let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
                let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for (a, b) in zip(source, target) {
                    if let src = a.mData, let dst = b.mData { memcpy(dst, src.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame) }
                }
                offset += count; loaned = buffer
                state.pointee = .haveData; return buffer
            }
            _ = loaned // Retain the callback buffer until this conversion call has completed.
            if let conversionError { throw conversionError }
            if let copyError { throw copyError }
            guard status != .error else { throw VerbaleError.message("Conversione audio interrotta") }
            let expected = Int((Double(inputFrames) * 16000 / inputFormat.sampleRate).rounded())
            let count = min(Int(output.frameLength), max(0, expected - emittedFrames))
            if count > 0, let samples = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: samples, count: count)); emittedFrames += count
            }
            if status == .endOfStream || (input != nil && status == .inputRanDry && offset == input!.frameLength) { return result }
        }
        throw VerbaleError.message("Il convertitore audio non ha completato il buffer")
    }
}
