import Foundation

public enum CaptureOperationError: LocalizedError {
    case timeout, recovering, alreadyRunning
    public var errorDescription: String? {
        switch self {
        case .timeout: return "Il dispositivo audio non ha completato l’operazione in tempo. La finestra resta utilizzabile; è in corso il ripristino dell’audio. Se persiste, chiudi e riapri Verbale."
        case .recovering: return "Il dispositivo audio è ancora in ripristino. Attendi e riprova; se persiste, chiudi e riapri Verbale."
        case .alreadyRunning: return "Un’operazione audio è già in corso."
        }
    }
}
private final class DeadlineReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: CheckedContinuation<Value,Error>?
    private var result: Result<Value,Error>?
    func install(_ reply: CheckedContinuation<Value,Error>) {
        lock.lock()
        if let result { lock.unlock(); reply.resume(with:result) }
        else { self.reply = reply; lock.unlock() }
    }
    func finish(_ result: Result<Value,Error>) {
        lock.lock(); guard self.result == nil else { lock.unlock(); return }
        self.result = result; let reply = self.reply; self.reply = nil; lock.unlock()
        reply?.resume(with:result)
    }
}
/// Unstructured hardware work may block in CoreAudio. A deadline must not wait for that work to finish.
public enum AudioOperationDeadline {
    public static func wait<Value: Sendable>(for operation: Task<Value,Error>, seconds: Double) async throws -> Value {
        let reply = DeadlineReply<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                Task { do { reply.finish(.success(try await operation.value)) } catch { reply.finish(.failure(error)) } }
                DispatchQueue.global().asyncAfter(deadline:.now()+seconds) { reply.finish(.failure(CaptureOperationError.timeout)) }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
    }
}
public actor CaptureOperationGuard {
    private enum State { case idle, starting, running, stopping, recovering }
    private var state = State.idle
    private let startTimeout: Double
    private let stopTimeout: Double
    public init(startTimeout: Double = 20, stopTimeout: Double = 10) { self.startTimeout = startTimeout; self.stopTimeout = stopTimeout }
    public var available: Bool { state == .idle }
    public func start(operation: @escaping @Sendable () async throws -> Date, cleanup: @escaping @Sendable () async -> Void) async throws -> Date {
        guard state == .idle else { throw state == .recovering ? CaptureOperationError.recovering : CaptureOperationError.alreadyRunning }
        state = .starting
        let task = Task { try await operation() }
        do { let date = try await AudioOperationDeadline.wait(for:task,seconds:startTimeout); state = .running; return date }
        catch {
            state = .recovering
            Task { _ = try? await task.value; await cleanup(); self.recovered() }
            throw error
        }
    }
    private func recovered() { state = .idle }
    @discardableResult public func stop(operation: @escaping @Sendable () async -> Void) async -> Bool {
        guard state == .running else { return state == .idle }
        state = .stopping
        let task = Task<Void,Error> { await operation() }
        do { _ = try await AudioOperationDeadline.wait(for:task,seconds:stopTimeout); state = .idle; return true }
        catch { state = .recovering; Task { _ = try? await task.value; self.recovered() }; return false }
    }
}

public enum RecordingReadiness {
    private static let signalWarning = "Audio di sistema molto debole. Se gli altri stanno parlando, verifica l’uscita attiva della call."
    private static let diagnosticPrefix = "Registrazione incompleta:"

    /// Measure the raw recording before echo cancellation or transcription.
    static func audibleSamples(_ samples: [Float]) -> Int {
        var audible = 0
        for start in stride(from: 0, to: samples.count, by: 16000) {
            let window = samples[start..<min(start + 16000, samples.count)]
            let energy = window.reduce(Float.zero) { $0 + $1 * $1 }
            if energy > Float(window.count) * 0.00001 { audible += window.count }
        }
        return audible
    }

    private static func weakSystemSignal(_ chunks: [AudioChunk]) -> Bool {
        var measured = 0
        var audible = 0
        for chunk in chunks where chunk.source == .system {
            guard let count = chunk.audibleSampleCount, (0...max(0, chunk.sampleCount)).contains(count) else { continue }
            measured += chunk.sampleCount
            audible += count
        }
        return measured >= 30 * 16000 && Double(audible) / Double(measured) < 0.15
    }

    public static func liveWarning(_ sources: [AudioSource], chunks: [AudioChunk], elapsed: Double) -> String? {
        for source in sources {
            if stalled(source, chunks: chunks, elapsed: elapsed) {
                return "\(source.label): nessun nuovo blocco audio. Verifica il dispositivo usato nella call."
            }
        }
        if let missing = systemWarning(sources, chunks: chunks, elapsed: elapsed) { return missing }
        if sources.contains(.system),
           weakSystemSignal(chunks.filter { $0.start + $0.duration >= elapsed - 40 }) { return signalWarning }
        return nil
    }

    public static func stalled(_ source: AudioSource, chunks: [AudioChunk], elapsed: Double) -> Bool {
        guard let last = chunks.lazy.filter({ $0.source == source }).map({ $0.start + $0.duration }).max() else { return false }
        return elapsed - last >= 12
    }

    /// Read-only reconstruction also covers old manifests with a reliable sample timeline.
    public static func archiveWarnings(_ meeting: Meeting) -> [String] {
        let warnings = missingSourceWarnings(meeting.sources, chunks: meeting.chunks, segments: meeting.segments)
        let stored = meeting.warnings.filter {
            $0.hasPrefix(diagnosticPrefix) || $0 == signalWarning || $0.hasPrefix("L’uscita registrata")
        }
        var result = stored + warnings.filter { !stored.contains($0) }
        if meeting.captureTimelineVersion ?? 0 >= 2 {
            for source in meeting.sources {
                let chunks = meeting.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
                guard let first = chunks.first else { continue }
                var end = first.start + first.duration
                var largestGap = 0.0
                for chunk in chunks.dropFirst() {
                    largestGap = max(largestGap, chunk.start - end)
                    end = max(end, chunk.start + chunk.duration)
                }
                if max(largestGap, meeting.duration - end) >= 3 {
                    let warning = "\(diagnosticPrefix) la traccia «\(source.label)» ha un’interruzione di almeno 3 secondi."
                    if !result.contains(warning) { result.append(warning) }
                }
            }
        }
        if meeting.sources.contains(.system), weakSystemSignal(meeting.chunks), !result.contains(signalWarning) {
            result.append(signalWarning)
        }
        return result
    }

    public static func systemWarning(_ sources: [AudioSource], chunks: [AudioChunk], elapsed: Double) -> String? {
        guard elapsed >= 30, waitingForSystem(sources,chunks:chunks) else { return nil }
        let continued = sources.contains(.microphone) ? " Il microfono continua a registrare." : ""
        return "Audio di sistema: nessun blocco ricevuto. Se gli altri stanno parlando, verifica l’uscita usata da Teams e il permesso Audio di sistema di macOS." + continued
    }
    public static func missingSourceWarnings(_ sources: [AudioSource], chunks: [AudioChunk], segments: [Segment] = []) -> [String] {
        sources.filter { source in !chunks.contains { $0.source == source } && !segments.contains { $0.source == source } }.map {
            "Registrazione incompleta: nessun audio acquisito da «\($0.label)». Verifica dispositivo e permessi; la trascrizione contiene solo le sorgenti ricevute."
        }
    }

    public static func waitingForSystem(_ sources: [AudioSource], chunks: [AudioChunk]) -> Bool { sources.contains(.system) && !chunks.contains(where: { $0.source == .system }) }
    public static func missingMicrophone(_ sources: [AudioSource], chunks: [AudioChunk], elapsed: Double) -> Bool { elapsed > 12 && sources.contains(.microphone) && !chunks.contains(where: { $0.source == .microphone }) }
}
