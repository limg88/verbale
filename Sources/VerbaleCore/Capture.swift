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

/// Written once after all hardware is prepared, before either IO callback starts.
private final class CaptureEpoch {
    var origin: UInt64 = 0
}

private final class CapturePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func close() { lock.lock(); open = false; lock.unlock() }
}
private final class CapturePermitSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CapturePermit?
    func install(_ permit: CapturePermit) { lock.lock(); current = permit; lock.unlock() }
    func close() { lock.lock(); let permit = current; lock.unlock(); permit?.close() }
}

/// Copies bounded audio buffers before returning to the realtime callback.
private final class ChunkSink: @unchecked Sendable {
    private static let journalLock = NSLock()
    let queue: DispatchQueue
    private let slots = DispatchSemaphore(value: 16)
    private let source: AudioSource
    private let folder: URL
    private let epoch: CaptureEpoch
    private let permit: CapturePermit
    private let onChunk: (AudioChunk) -> Void
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private var converter: StreamingAudioConverter?
    private var firstInputTime: Double?
    private var inputDuration = 0.0
    private var samples: [Float] = []
    private var sampleClock: AudioSampleClock?
    private var lastMeterTime = -Double.infinity
    private var stopped = false
    private var failed = false
    init(source: AudioSource, folder: URL, epoch: CaptureEpoch, permit: CapturePermit, onChunk: @escaping (AudioChunk) -> Void, onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) {
        self.source = source; self.folder = folder; self.epoch = epoch; self.permit = permit; self.onChunk = onChunk; self.onLevel = onLevel; self.onError = onError
        queue = DispatchQueue(label: "io.verbale.writer.\(source.rawValue)")
    }
    func receive(_ input: AVAudioPCMBuffer, hostTime: UInt64) {
        guard permit.allowed else { return }
        let origin = epoch.origin
        guard origin != 0 else { return }
        guard slots.wait(timeout: .now()) == .success else { onError("Il disco non tiene il passo con l'audio. Registrazione arrestata per evitare perdite silenziose."); return }
        guard let copied = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { slots.signal(); return }
        copied.frameLength = input.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let targetBuffers = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        for (from, to) in zip(sourceBuffers, targetBuffers) { if let a = from.mData, let b = to.mData { memcpy(b, a, Int(from.mDataByteSize)) } }
        let instant = hostTime >= origin ? AVAudioTime.seconds(forHostTime: hostTime - origin) : -AVAudioTime.seconds(forHostTime: origin - hostTime)
        queue.async { [self] in
            defer { slots.signal() }
            guard !stopped && !failed else { return }
            do {
                if firstInputTime == nil { firstInputTime = instant; sampleClock = AudioSampleClock(start: instant) }
                if abs(instant - (firstInputTime! + inputDuration)) > 0.3 {
                    try flush()
                    onError("Discontinuità rilevata nella sorgente \(source.label). La registrazione è stata interrotta; i blocchi salvati sono recuperabili.")
                    failed = true; return
                }
                inputDuration += Double(copied.frameLength) / copied.format.sampleRate
                if converter == nil { converter = try StreamingAudioConverter(format: copied.format) }
                try append(converter!.convert(copied))
            } catch { failed = true; onError(error.localizedDescription) }
        }
    }
    private func append(_ input: [Float]) throws {
        guard !input.isEmpty else { return }
        var values = input
        if let start = sampleClock?.nextStart, start < 0 && samples.isEmpty {
            let trim = min(values.count, Int(ceil(-start * 16000)))
            values.removeFirst(trim); sampleClock?.advance(samples: trim)
        }
        guard !values.isEmpty else { return }
        // Hardware buffers may arrive hundreds of times per second. Metering is
        // presentation only; bound its work without dropping any recorded samples.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeterTime >= 0.1 {
            lastMeterTime = now
            let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
            onLevel(min(1, rms * 5))
        }
        samples.append(contentsOf: values)
        // The sample clock never reanchors to a callback after a chunk boundary.
        if samples.count >= 80000 { try flush() }
    }
    private func flush() throws {
        guard !samples.isEmpty else { return }
        let filename = "audio/\(source.rawValue)_\(UUID().uuidString).caf"
        try AudioFiles.write(samples, to: folder.appendingPathComponent(filename))
        let chunk = AudioChunk(source: source, start: sampleClock!.nextStart, sampleCount: samples.count, filename: filename)
        Self.journalLock.lock()
        defer { Self.journalLock.unlock() }
        let journal = folder.appendingPathComponent("journal.jsonl")
        if !FileManager.default.fileExists(atPath: journal.path) { FileManager.default.createFile(atPath: journal.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file = try FileHandle(forWritingTo: journal); defer { try? file.close() }
        var data = try JSONEncoder().encode(chunk); data.append(10)
        try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
        sampleClock?.advance(samples: samples.count); samples.removeAll(keepingCapacity: true)
        onChunk(chunk)
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    if !failed, let converter { try append(converter.finish()) }
                    try flush()
                } catch { onError(error.localizedDescription) }
                stopped = true; continuation.resume()
            }
        }
    }
}

private actor CaptureHardware {
    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var tap: AudioObjectID = 0
    private var aggregate: AudioDeviceID = 0
    private var proc: AudioDeviceIOProcID?
    private var sinks: [ChunkSink] = []
    private let callbackQueue = DispatchQueue(label: "io.verbale.system-audio")
    public init() {}
    func start(sources: [AudioSource], input: AudioDeviceID, output: AudioDeviceID, folder: URL, permit: CapturePermit,
                      onChunk: @escaping (AudioChunk) -> Void, onLevel: @escaping (AudioSource, Float) -> Void,
                      onError: @escaping (String) -> Void) async throws -> Date {
        guard engine == nil && aggregate == 0 else { throw VerbaleError.message("Registrazione già avviata") }
        let epoch = CaptureEpoch()
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
                let sink = ChunkSink(source: .microphone, folder: folder, epoch: epoch, permit: permit, onChunk: onChunk, onLevel: { onLevel(.microphone, $0) }, onError: onError)
                sinks.append(sink)
                node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in sink.receive(buffer, hostTime: time.hostTime) }
                microphoneTapInstalled = true
                e.prepare()
            }
            if sources.contains(.system) {
                let sink = ChunkSink(source: .system, folder: folder, epoch: epoch, permit: permit, onChunk: onChunk, onLevel: { onLevel(.system, $0) }, onError: onError)
                sinks.append(sink)
                try prepareSystem(output: output == 0 ? Devices.defaultDevice(input: false) : output, sink: sink)
            }
            // Heavy tap/aggregate creation is complete before choosing the shared epoch.
            let started = Date()
            epoch.origin = mach_absolute_time()
            if aggregate != 0 { try check(AudioDeviceStart(aggregate, proc), "Avviare l'audio di sistema") }
            try engine?.start()
            return started
        } catch { permit.close(); await stop(); throw error }
    }
    private func prepareSystem(output: AudioDeviceID, sink: ChunkSink) throws {
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
    }
    public func stop() async {
        if let engine {
            if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            microphoneTapInstalled = false; engine.stop(); self.engine = nil
        }
        if aggregate != 0 {
            _ = AudioDeviceStop(aggregate, proc)
            if let proc { _ = AudioDeviceDestroyIOProcID(aggregate, proc) }
            self.proc = nil; _ = AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0
        }
        if tap != 0 { _ = AudioHardwareDestroyProcessTap(tap); tap = 0 }
        for sink in sinks { await sink.stop() }; sinks.removeAll()
    }
}

/// Hardware lifecycle runs on its own actor, with bounded UI waits and serialized late cleanup.
public final class CaptureService: Sendable {
    private let hardware = CaptureHardware()
    private let operations = CaptureOperationGuard()
    private let permits = CapturePermitSlot()
    public init() {}
    public var available: Bool { get async { await operations.available } }
    public func start(sources: [AudioSource], input: AudioDeviceID, output: AudioDeviceID, folder: URL,
                      onChunk: @escaping @Sendable (AudioChunk) -> Void, onLevel: @escaping @Sendable (AudioSource,Float) -> Void,
                      onError: @escaping @Sendable (String) -> Void) async throws -> Date {
        guard await operations.available else { throw CaptureOperationError.recovering }
        if sources.contains(.microphone) {
            let allowed = await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for:.audio) { c.resume(returning:$0) } }
            guard allowed else { throw VerbaleError.message("Consenti il microfono in Impostazioni di Sistema → Privacy e sicurezza → Microfono.") }
        }
        try Task.checkCancellation()
        let permit = CapturePermit()
        do {
            return try await operations.start(operation: { [hardware,permits] in
                permits.install(permit)
                return try await hardware.start(sources:sources,input:input,output:output,folder:folder,permit:permit,onChunk:onChunk,onLevel:onLevel,onError:onError)
            }, cleanup: { [hardware] in permit.close(); await hardware.stop() })
        } catch { permit.close(); throw error }
    }
    @discardableResult public func stop() async -> Bool {
        permits.close()
        return await operations.stop { [hardware] in await hardware.stop() }
    }
}
