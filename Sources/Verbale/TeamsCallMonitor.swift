import Foundation
import VerbaleCore

/// Serial polling off the main thread; no shell processes, audio scans or AX access.
final class TeamsCallMonitor {
    private var timer: DispatchSourceTimer?
    func start(deliver: @escaping @Sendable (TeamsCallSignal) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.verbale.teams", qos: .utility))
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { deliver(TeamsCallProbe.sample()) }
        self.timer = timer
        timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }
}
