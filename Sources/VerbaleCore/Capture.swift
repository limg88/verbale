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
    var active: CapturePermit? { lock.lock(); defer { lock.unlock() }; return current }
    func close() { active?.close() }
}

/// Copies bounded audio buffers before returning to the realtime callback.
private final class ChunkSink: @unchecked Sendable {
    private static let journalLock = NSLock()
    let queue: DispatchQueue
    private let slots = DispatchSemaphore(value: 16)
    private let source: AudioSource
    private let folder: URL
    private let epoch: CaptureEpoch
    private let minimumStart: Double
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
    init(source: AudioSource, folder: URL, epoch: CaptureEpoch, minimumStart: Double, permit: CapturePermit, onChunk: @escaping (AudioChunk) -> Void, onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) {
        self.source = source; self.folder = folder; self.epoch = epoch; self.minimumStart = minimumStart
        self.permit = permit; self.onChunk = onChunk; self.onLevel = onLevel; self.onError = onError
        queue = DispatchQueue(label: "io.verbale.writer.\(source.rawValue)")
    }
    func receive(_ input: AVAudioPCMBuffer, hostTime: UInt64) {
        guard permit.allowed, hostTime != 0, input.frameLength > 0 else { return }
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
                if let firstInputTime {
                    let delta = instant - (firstInputTime + inputDuration)
                    guard delta >= -0.3 else { return }
                    if delta > 0.3 || converter?.inputFormat != copied.format {
                        // Keep the preceding span when the device resumes or changes format.
                        if let converter { try append(converter.finish()) }
                        try flush()
                        converter = nil
                        self.firstInputTime = nil
                    }
                }
                if firstInputTime == nil {
                    firstInputTime = instant
                    inputDuration = 0
                    sampleClock = AudioSampleClock(start: max(instant, sampleClock?.nextStart ?? instant))
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
        if let start = sampleClock?.nextStart, start < minimumStart && samples.isEmpty {
            let trim = min(values.count, Int(ceil((minimumStart - start) * 16000)))
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
        let audible = source == .system ? RecordingReadiness.audibleSamples(samples) : nil
        let chunk = AudioChunk(source: source, start: sampleClock!.nextStart, sampleCount: samples.count, filename: filename, audibleSampleCount: audible)
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
    func stop() async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    if !failed, let converter { try append(converter.finish()) }
                    try flush()
                } catch { onError(error.localizedDescription) }
                stopped = true
                continuation.resume(returning: sampleClock?.nextStart)
            }
        }
    }
}

private actor CaptureHardware {
    private struct Session {
        let sources: [AudioSource]
        let folder: URL
        let epoch = CaptureEpoch()
        let permit: CapturePermit
        let onChunk: (AudioChunk) -> Void
        let onLevel: (AudioSource, Float) -> Void
        let onError: (String) -> Void

        func sink(for source: AudioSource, minimumStart: Double) -> ChunkSink {
            ChunkSink(source: source, folder: folder, epoch: epoch, minimumStart: minimumStart, permit: permit,
                      onChunk: onChunk, onLevel: { onLevel(source, $0) }, onError: onError)
        }
    }
    private var session: Session?
    private var changingDevices = false
    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var tap: AudioObjectID = 0
    private var aggregate: AudioDeviceID = 0
    private var proc: AudioDeviceIOProcID?
    private var sinks: [AudioSource: ChunkSink] = [:]
    private var drains: [UUID: Task<Double?, Never>] = [:]
    private let callbackQueue = DispatchQueue(label: "io.verbale.system-audio")
    public init() {}
    func start(sources: [AudioSource], input: AudioDeviceID, output: AudioDeviceID, folder: URL, permit: CapturePermit,
                      onChunk: @escaping (AudioChunk) -> Void, onLevel: @escaping (AudioSource, Float) -> Void,
                      onError: @escaping (String) -> Void) async throws -> Date {
        guard session == nil else { throw VerbaleError.message("Registrazione già avviata") }
        let session = Session(sources: sources, folder: folder, permit: permit, onChunk: onChunk, onLevel: onLevel, onError: onError)
        self.session = session
        do {
            if sources.contains(.microphone) {
                try prepareMicrophone(input: input, session: session)
            }
            if sources.contains(.system) {
                try prepareSystem(output: output == 0 ? Devices.defaultDevice(input: false) : output, session: session)
            }
            // Heavy tap/aggregate creation is complete before choosing the shared epoch.
            let started = Date()
            session.epoch.origin = mach_absolute_time()
            if aggregate != 0 { try check(AudioDeviceStart(aggregate, proc), "Avviare l'audio di sistema") }
            try engine?.start()
            return started
        } catch { permit.close(); await stop(); throw error }
    }
    private func prepareMicrophone(input: AudioDeviceID, session: Session, minimumStart: Double = 0) throws {
        let e = AVAudioEngine()
        engine = e
        let node = e.inputNode
        if input != 0 {
            guard let unit = node.audioUnit else { throw VerbaleError.message("Microfono non disponibile") }
            var device = input
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))), "Selezionare il microfono")
        }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { throw VerbaleError.message("Microfono non disponibile") }
        let sink = session.sink(for: .microphone, minimumStart: minimumStart)
        sinks[.microphone] = sink
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            if time.isHostTimeValid { sink.receive(buffer, hostTime: time.hostTime) }
        }
        microphoneTapInstalled = true
        e.prepare()
    }
    private func prepareSystem(output: AudioDeviceID, session: Session, minimumStart: Double = 0) throws {
        let sink = session.sink(for: .system, minimumStart: minimumStart)
        sinks[.system] = sink
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
            // The selected output is already scoped by the tap. Adding the physical
            // device could place its own input channels ahead of the tap buffers.
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate), "Creare il dispositivo audio")
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, callbackQueue) { _, input, timestamp, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mDataByteSize > 0, asbd.mBytesPerFrame > 0,
                  timestamp.pointee.mFlags.contains(.hostTimeValid) else { return }
            let frames = first.mDataByteSize / asbd.mBytesPerFrame
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard buffers.count == output.count else { return }
            for (from, to) in zip(buffers, output) {
                guard let a = from.mData, let b = to.mData, from.mDataByteSize >= to.mDataByteSize else { return }
                memcpy(b, a, Int(to.mDataByteSize))
            }
            sink.receive(buffer, hostTime: timestamp.pointee.mHostTime)
        }, "Collegare l'audio di sistema")
    }
    private func detach(_ source: AudioSource) -> UUID? {
        if source == .microphone, let engine {
            if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            microphoneTapInstalled = false; engine.stop(); self.engine = nil
        }
        if source == .system, aggregate != 0 {
            _ = AudioDeviceStop(aggregate, proc)
            if let proc { _ = AudioDeviceDestroyIOProcID(aggregate, proc) }
            self.proc = nil; _ = AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0
        }
        if source == .system, tap != 0 { _ = AudioHardwareDestroyProcessTap(tap); tap = 0 }
        guard let sink = sinks.removeValue(forKey: source) else { return nil }
        let id = UUID()
        drains[id] = Task { await sink.stop() }
        return id
    }

    func changeDevices(input: AudioDeviceID?, output: AudioDeviceID?, permit: CapturePermit) async throws -> [AudioSource: String] {
        guard let session, session.permit === permit, permit.allowed else { throw CancellationError() }
        guard !changingDevices else { throw CaptureOperationError.alreadyRunning }
        changingDevices = true
        defer { changingDevices = false }
        var failures: [AudioSource: String] = [:]
        for (source, device) in [(AudioSource.microphone, input), (.system, output)] {
            guard let device else { continue }
            guard session.sources.contains(source) else {
                failures[source] = "Sorgente non selezionata per questa registrazione."
                continue
            }
            guard self.session?.permit === permit, permit.allowed else { throw CancellationError() }
            var minimumStart = 0.0
            if let id = detach(source) {
                minimumStart = await drains[id]?.value ?? 0
                drains.removeValue(forKey: id)
            }
            guard self.session?.permit === permit, permit.allowed else { throw CancellationError() }
            do {
                if source == .microphone {
                    try prepareMicrophone(input: device, session: session, minimumStart: minimumStart)
                    try engine?.start()
                } else {
                    try prepareSystem(output: device, session: session, minimumStart: minimumStart)
                    try check(AudioDeviceStart(aggregate, proc), "Riavviare l’audio di sistema")
                }
            } catch {
                if let id = detach(source) {
                    _ = await drains[id]?.value
                    drains.removeValue(forKey: id)
                }
                failures[source] = error.localizedDescription
            }
        }
        return failures
    }

    public func stop() async {
        session = nil
        for source in AudioSource.allCases { _ = detach(source) }
        let pending = Array(drains.values)
        for task in pending { _ = await task.value }
        drains.removeAll()
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
    /// Updates only the requested sources and keeps the original recording clock.
    public func changeDevices(input: AudioDeviceID?, output: AudioDeviceID?) async throws -> [AudioSource: String] {
        guard let permit = permits.active, permit.allowed else { throw CancellationError() }
        let task = Task { [hardware] in try await hardware.changeDevices(input: input, output: output, permit: permit) }
        return try await AudioOperationDeadline.wait(for: task, seconds: 10)
    }
    @discardableResult public func stop() async -> Bool {
        permits.close()
        return await operations.stop { [hardware] in await hardware.stop() }
    }
}
