import Foundation

/// File names of the bundled native runtimes on each platform.
enum NativeLibrary {
    static func filename(_ base: String) -> String {
        #if os(Windows)
        return base + ".dll"
        #elseif os(Linux)
        return "lib" + base + ".so"
        #else
        return "lib" + base + ".dylib"
        #endif
    }
}
