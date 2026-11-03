import AppKit

final class MainWindow: NSWindow {
    override func close() {
        super.close()
        NSApp.setActivationPolicy(.accessory)
    }
}
