import Foundation

public enum RecordingPreferences {
    public static let keepAudioKey = "saveRecordingAudio"
    public static func keepAudio(in defaults: UserDefaults = .standard) -> Bool {
        // Existing installations have no key: the new default must also apply there.
        defaults.object(forKey: keepAudioKey) as? Bool ?? true
    }
    public static func setKeepAudio(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: keepAudioKey)
    }
}
