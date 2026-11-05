import Foundation

enum AudioCaptureSettings {
    static let includeSystemAudioKey = "includeSystemAudio"

    static func includesSystemAudio(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: includeSystemAudioKey)
    }
}

/// Snapshot once per recording: changing preferences must not mute an active meeting.
struct RecordingAudioPolicy {
    let includesSystemAudio: Bool

    var allowsMutingAndPausing: Bool { !includesSystemAudio }
}
