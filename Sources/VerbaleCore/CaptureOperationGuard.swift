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
    public static func waitingForSystem(_ sources: [AudioSource], chunks: [AudioChunk]) -> Bool { sources.contains(.system) && !chunks.contains(where: { $0.source == .system }) }
    public static func missingMicrophone(_ sources: [AudioSource], chunks: [AudioChunk], elapsed: Double) -> Bool { elapsed > 12 && sources.contains(.microphone) && !chunks.contains(where: { $0.source == .microphone }) }
}
