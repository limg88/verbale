import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Minimal diagnostics for failures the core deliberately tolerates (a skipped file, a refused
/// keychain read). Messages must never contain transcript text, tokens or user paths.
public enum CoreLog {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "io.verbale.core", category: "diagnostics")
    #endif
    public static func warning(_ message: String) {
        #if canImport(OSLog)
        logger.warning("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data(("verbale: " + message + "\n").utf8))
        #endif
    }
}
