import Foundation

/// One ordinary WAV per source next to the exported 5-second chunks, so a recording can be played
/// on any system without Verbale. The chunks stay the source of truth for reprocessing.
enum PlayableAudio {
    static let sampleRate = 16000
    static func filename(_ source: AudioSource) -> String { "audio/" + (source == .microphone ? "microfono" : "sistema") + ".wav" }

    /// Writes 16-bit mono PCM, placing every chunk at its recorded time and filling gaps with silence.
    /// Streams chunk by chunk: a two-hour meeting never sits in memory.
    static func write(_ chunks: [AudioChunk], source: AudioSource, folder: URL) throws {
        let ordered = chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return }
        let total = ordered.map { Int(($0.start * Double(sampleRate)).rounded()) + $0.sampleCount }.max() ?? 0
        let bytes = total * 2
        guard total > 0, bytes <= Int(UInt32.max) - 36 else { return }
        let output = folder.appendingPathComponent(filename(source))
        // Exports repeat after each processing step: an up-to-date file is left alone.
        if let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int, size == bytes + 44 { return }
        let partial = output.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: header(dataBytes: bytes)) else { throw VerbaleError.message("File audio non scrivibile") }
        do {
            let file = try FileHandle(forWritingTo: partial)
            defer { try? file.close() }
            try file.seekToEnd()
            var written = 0
            func silence(_ count: Int) throws {
                var remaining = count
                while remaining > 0 { let step = min(remaining, sampleRate * 10); try file.write(contentsOf: Data(count: step * 2)); remaining -= step }
            }
            for chunk in ordered {
                let position = Int((chunk.start * Double(sampleRate)).rounded())
                if position > written { try silence(position - written); written = position }
                let samples = try AudioFiles.samples(folder.appendingPathComponent(chunk.filename))
                let fresh = samples.dropFirst(max(0, written - position))
                var pcm = Data(capacity: fresh.count * 2)
                for sample in fresh {
                    let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
                    pcm.append(UInt8(truncatingIfNeeded: value)); pcm.append(UInt8(truncatingIfNeeded: value >> 8))
                }
                try file.write(contentsOf: pcm); written += fresh.count
            }
            if written < total { try silence(total - written) }
            else if written > total { try file.truncate(atOffset: UInt64(44 + bytes)) }
        } catch { try? FileManager.default.removeItem(at: partial); throw error }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    private static func header(dataBytes: Int) -> Data {
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + dataBytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(sampleRate)); le(UInt32(sampleRate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(dataBytes))
        return data
    }
}
