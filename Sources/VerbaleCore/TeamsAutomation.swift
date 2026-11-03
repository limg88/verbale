import Foundation
import AppKit
import IOKit.pwr_mgt

public enum TeamsCallSignal: String, Sendable {
    case active, inactive, unavailable
}

/// Reads only power assertion metadata, never meeting content or Teams logs.
/// The assertion name is a Teams implementation detail, not a Microsoft API contract.
public enum TeamsCallProbe {
    public static func isCallAssertion(name: String, level: Int, bundleIdentifier: String) -> Bool {
        let teams = bundleIdentifier == "com.microsoft.teams2" || bundleIdentifier == "com.microsoft.teams"
            || bundleIdentifier.hasPrefix("com.microsoft.teams2.") || bundleIdentifier.hasPrefix("com.microsoft.teams.")
        return teams && level > 0 && name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Microsoft Teams Call in progress") == .orderedSame
    }

    public static func sample() -> TeamsCallSignal {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let raw else { return .unavailable }
        let assertions = raw.takeRetainedValue() as NSDictionary
        for (key, value) in assertions {
            guard let pid = key as? NSNumber, let entries = value as? [[String: Any]] else { continue }
            let bundle = NSRunningApplication(processIdentifier: pid.int32Value)?.bundleIdentifier ?? ""
            for entry in entries {
                if isCallAssertion(name: entry[kIOPMAssertionNameKey] as? String ?? "",
                                   level: (entry[kIOPMAssertionLevelKey] as? NSNumber)?.intValue ?? 0,
                                   bundleIdentifier: bundle) { return .active }
            }
        }
        return .inactive
    }
}

/// A manual stop suppresses restarts naturally: callBegan is emitted only once per call.
/// Unknown observations never count as evidence that the call ended.
public struct TeamsCallTracker {
    public enum Event: Equatable { case callBegan, callEnded }
    public private(set) var isInCall = false
    private var activeSince: Date?
    private var inactiveSince: Date?
    public init() {}
    public mutating func update(_ signal: TeamsCallSignal, at now: Date) -> Event? {
        switch signal {
        case .active:
            inactiveSince = nil
            guard !isInCall else { return nil }
            if let since = activeSince, now.timeIntervalSince(since) >= 2 {
                isInCall = true; activeSince = nil; return .callBegan
            }
            if activeSince == nil { activeSince = now }
        case .inactive:
            activeSince = nil
            guard isInCall else { return nil }
            if let since = inactiveSince, now.timeIntervalSince(since) >= 20 {
                isInCall = false; inactiveSince = nil; return .callEnded
            }
            if inactiveSince == nil { inactiveSince = now }
        case .unavailable:
            activeSince = nil; inactiveSince = nil
        }
        return nil
    }
}
