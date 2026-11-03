import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public init(id: AudioDeviceID, name: String) { self.id = id; self.name = name }
}
public enum Devices {
    public static func list(input: Bool) -> [AudioDevice] {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var stream = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &stream, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var name: CFString = "Dispositivo" as CFString
            var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bytes = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, $0) }
            guard status == noErr else { return nil }
            return AudioDevice(id: id, name: name as String)
        }
    }
    public static func defaultDevice(input: Bool) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }
    static func uid(_ device: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString; var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        try check(status, "Leggere il dispositivo")
        return value as String
    }
}
private func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw VerbaleError.message("\(action): errore audio \(status). Verifica i permessi Audio di sistema nelle Impostazioni di macOS.") }
}

/// Copies bounded audio buffers before returning to the realtime callback.
private final class ChunkSink: @unchecked Sendable {
    private static let journalLock = NSLock()
    let queue: DispatchQueue
    private let slots = DispatchSemaphore(value: 16)
    private let source: AudioSource
    private let folder: URL
    private let origin: UInt64
    private let onChunk: (AudioChunk) -> Void
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var beginning: Double = 0
    private var stopped = false
    private var failed = false
    init(source: AudioSource, folder: URL, origin: UInt64, onChunk: @escaping (AudioChunk) -> Void, onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) {
        self.source = source; self.folder = folder; self.origin = origin; self.onChunk = onChunk; self.onLevel = onLevel; self.onError = onError
        queue = DispatchQueue(label: "io.verbale.writer.\(source.rawValue)")
    }
    func receive(_ input: AVAudioPCMBuffer, hostTime: UInt64) {
        guard slots.wait(timeout: .now()) == .success else { onError("Il disco non tiene il passo con l'audio. Registrazione arrestata per evitare perdite silenziose."); return }
        guard let copied = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { slots.signal(); return }
        copied.frameLength = input.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let targetBuffers = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        for (from, to) in zip(sourceBuffers, targetBuffers) { if let a = from.mData, let b = to.mData { memcpy(b, a, Int(from.mDataByteSize)) } }
        let instant = AVAudioTime.seconds(forHostTime: hostTime >= origin ? hostTime - origin : 0)
        queue.async { [self] in
            defer { slots.signal() }
            guard !stopped && !failed else { return }
            do {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                if converter?.inputFormat != copied.format { converter = AVAudioConverter(from: copied.format, to: format) }
                guard let converter else { throw VerbaleError.message("Formato dispositivo non supportato") }
                let capacity = AVAudioFrameCount(Double(copied.frameLength) * 16000 / copied.format.sampleRate) + 256
                let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
                var consumed = false; var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true; status.pointee = .haveData; return copied
                }
                if let error { throw error }
                guard let p = output.floatChannelData?[0], output.frameLength > 0 else { return }
                let values = Array(UnsafeBufferPointer(start: p, count: Int(output.frameLength)))
                let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
                onLevel(min(1, rms * 5))
                if samples.isEmpty { beginning = instant }
                let expected = beginning + Double(samples.count) / 16000
                if abs(instant - expected) > 0.3, !samples.isEmpty {
                    try flush(); beginning = instant
                    onError("Discontinuità rilevata nella sorgente \(source.label). La registrazione è stata interrotta; i blocchi salvati sono recuperabili.")
                    failed = true; return
                }
                samples.append(contentsOf: values)
                if samples.count >= 80000 { try flush() }
            } catch { failed = true; onError(error.localizedDescription) }
        }
    }
    private func flush() throws {
        guard !samples.isEmpty else { return }
        let filename = "audio/\(source.rawValue)_\(UUID().uuidString).caf"
        try AudioFiles.write(samples, to: folder.appendingPathComponent(filename))
        let chunk = AudioChunk(source: source, start: beginning, sampleCount: samples.count, filename: filename)
        Self.journalLock.lock()
        defer { Self.journalLock.unlock() }
        let journal = folder.appendingPathComponent("journal.jsonl")
        if !FileManager.default.fileExists(atPath: journal.path) { FileManager.default.createFile(atPath: journal.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file = try FileHandle(forWritingTo: journal); defer { try? file.close() }
        var data = try JSONEncoder().encode(chunk); data.append(10)
        try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
        beginning += Double(samples.count) / 16000; samples.removeAll(keepingCapacity: true)
        onChunk(chunk)
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do { try flush() } catch { onError(error.localizedDescription) }
                stopped = true; continuation.resume()
            }
        }
    }
}

public final class CaptureService {
    private var engine: AVAudioEngine?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioDeviceID = 0
    private var proc: AudioDeviceIOProcID?
    private var sinks: [ChunkSink] = []
    private let callbackQueue = DispatchQueue(label: "io.verbale.system-audio")
    public init() {}
    public func start(sources: [AudioSource], input: AudioDeviceID, output: AudioDeviceID, folder: URL,
                      onChunk: @escaping (AudioChunk) -> Void, onLevel: @escaping (AudioSource, Float) -> Void,
                      onError: @escaping (String) -> Void) async throws {
        guard engine == nil && aggregate == 0 else { throw VerbaleError.message("Registrazione già avviata") }
        if sources.contains(.microphone) {
            let allowed = await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) } }
            guard allowed else { throw VerbaleError.message("Consenti il microfono in Impostazioni di Sistema → Privacy e sicurezza → Microfono.") }
        }
        let origin = mach_absolute_time()
        do {
            if sources.contains(.microphone) {
                let e = AVAudioEngine(); engine = e
                let node = e.inputNode
                if input != 0, let unit = node.audioUnit {
                    var device = input
                    try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), "Selezionare il microfono")
                }
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0 && format.channelCount > 0 else { throw VerbaleError.message("Microfono non disponibile") }
                let sink = ChunkSink(source: .microphone, folder: folder, origin: origin, onChunk: onChunk, onLevel: { onLevel(.microphone, $0) }, onError: onError)
                sinks.append(sink)
                node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in sink.receive(buffer, hostTime: time.hostTime) }
                try e.start()
            }
            if sources.contains(.system) {
                let sink = ChunkSink(source: .system, folder: folder, origin: origin, onChunk: onChunk, onLevel: { onLevel(.system, $0) }, onError: onError)
                sinks.append(sink)
                try startSystem(output: output == 0 ? Devices.defaultDevice(input: false) : output, sink: sink)
            }
        } catch { await stop(); throw error }
    }
    private func startSystem(output: AudioDeviceID, sink: ChunkSink) throws {
        let uid = try Devices.uid(output)
        let description = CATapDescription(__excludingProcesses: [], andDeviceUID: uid, withStream: 0)
        description.isPrivate = true; description.isExclusive = true; description.muteBehavior = .unmuted
        description.name = "Verbale — audio di sistema"
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creare il tap audio")
        var property = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: asbd))
        try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &asbd), "Leggere il formato audio")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw VerbaleError.message("Formato del tap non supportato") }
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Verbale Capture", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate), "Creare il dispositivo audio")
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, callbackQueue) { _, input, timestamp, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mDataByteSize > 0, asbd.mBytesPerFrame > 0 else { return }
            let frames = first.mDataByteSize / asbd.mBytesPerFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for (from, to) in zip(buffers, output) { if let a = from.mData, let b = to.mData { memcpy(b, a, min(Int(from.mDataByteSize), Int(to.mDataByteSize))) } }
            sink.receive(buffer, hostTime: timestamp.pointee.mHostTime)
        }, "Collegare l'audio di sistema")
        try check(AudioDeviceStart(aggregate, proc), "Avviare l'audio di sistema")
    }
    public func stop() async {
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop(); self.engine = nil }
        if aggregate != 0 {
            _ = AudioDeviceStop(aggregate, proc)
            if let proc { _ = AudioDeviceDestroyIOProcID(aggregate, proc) }
            self.proc = nil; _ = AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0
        }
        if tap != 0 { _ = AudioHardwareDestroyProcessTap(tap); tap = 0 }
        for sink in sinks { await sink.stop() }; sinks.removeAll()
    }
}
