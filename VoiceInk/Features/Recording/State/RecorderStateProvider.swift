import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    /// Privacy-safe, ephemeral description of the hints prepared for the current request.
    var recognitionHintSummary: String? { get }
}
