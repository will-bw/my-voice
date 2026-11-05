import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// ScreenCaptureKit receives audio digitally, including when playback is routed to headphones.
/// No screen output is registered and no image frames are saved.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @MainActor private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.will.myvoice.systemAudio", qos: .userInitiated)
    private let writer: MixedAudioWriter
    private let onFailure: (Error) -> Void
    private let stateLock = NSLock()
    private var stopping = false

    init(writer: MixedAudioWriter, onFailure: @escaping (Error) -> Void) {
        self.writer = writer
        self.onFailure = onFailure
    }

    @MainActor
    func start() async throws {
        try Task.checkCancellation()
        // ScreenCaptureKit enforces its own authorization. A separate Core Graphics
        // preflight can disagree with an existing grant and must never block capture.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard !stateLock.withLock({ stopping }) else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw MixedAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    @MainActor
    func stop() async {
        stateLock.withLock { stopping = true }
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .audio)
        }
        stream = nil
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
            frameCount: Int32(sampleBuffer.numSamples), into: buffer.mutableAudioBufferList)
        guard status == noErr else { onFailure(MixedAudioError.conversionFailed); return }
        writer.append(buffer, hostTime: sampleBuffer.presentationTimeStamp.seconds, source: .system)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stateLock.withLock({ stopping }) else { return }
        onFailure(error)
    }
}
