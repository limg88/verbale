import AppKit

/// A borderless panel needs an explicit key-window policy for keyboard access.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
