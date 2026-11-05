import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    var recorder: CoreAudioRecorder?
    var mixedAudioWriter: MixedAudioWriter?
    private var systemAudioCapture: SystemAudioCapture?
    private var captureSessionID: UUID?
    private var captureFailure: Error?
    private var recordingHasStarted = false
    @Published private(set) var isCapturingSystemAudio = false
    var onCaptureFailure: ((Error) -> Void)?
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    let deviceManager = AudioDeviceManager.shared
    private var lifecycleCancellable: AnyCancellable?
    var recordingDeviceChangeObserver: NSObjectProtocol?
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    /// Dedicated serial queue for hardware setup.
    let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private let recordingAudioActionDelayNanoseconds: UInt64 = 220_000_000
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet {
            recorder?.onAudioChunk = onAudioChunk
            mixedAudioWriter?.setAudioChunkCallback(onAudioChunk)
        }
    }

    enum RecorderError: Error {
        case couldNotStartRecording
        case noUsableMicrophone(internalMicrophoneBlockedByClosedLid: Bool)
    }

    override init() {
        super.init()
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.audioDeviceChanged, .systemWillSleep, .systemDidWake]
        ).sink { [weak self] _ in
            Task { @MainActor in
                self?.invalidatePreparedAudioUnit()
            }
        }
        setupRecordingDeviceChangeObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    func startRecording(toOutputFile url: URL) async throws {
        var resolution = deviceManager.resolveCurrentRecordingDevice()
        guard var deviceID = resolution.deviceID else {
            onAudioChunk = nil
            throw RecorderError.noUsableMicrophone(
                internalMicrophoneBlockedByClosedLid: resolution.internalMicrophoneBlockedByClosedLid
            )
        }

        deviceManager.beginRecordingSetup(deviceID: deviceID)

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        let sessionID = UUID()
        captureSessionID = sessionID
        captureFailure = nil
        recordingHasStarted = false
        let policy = RecordingAudioPolicy(includesSystemAudio: AudioCaptureSettings.includesSystemAudio())
        if policy.allowsMutingAndPausing {
            pauseMedia()
            muteSystemAudio()
        } else {
            await mediaController.unmuteSystemAudio(immediately: true)
            await playbackController.resumeMedia(immediately: true)
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        do {
            guard captureSessionID == sessionID else { throw CancellationError() }
            try Task.checkCancellation()
            if policy.includesSystemAudio {
                let failureHandler: (Error) -> Void = { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.captureSessionID == sessionID, self.captureFailure == nil else { return }
                        self.captureFailure = error
                        if self.recordingHasStarted { self.onCaptureFailure?(error) }
                    }
                }
                let writer = try MixedAudioWriter(url: url, onAudioChunk: onAudioChunk, onFailure: failureHandler)
                mixedAudioWriter = writer
                let capture = SystemAudioCapture(writer: writer, onFailure: failureHandler)
                systemAudioCapture = capture
                try await capture.start()
                guard captureSessionID == sessionID else {
                    await capture.stop()
                    throw CancellationError()
                }
                try Task.checkCancellation()
                writer.begin()
            }
            do {
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: deviceID)
            } catch {
                let retryResolution = deviceManager.resolveCurrentRecordingDevice(excluding: deviceID)
                guard deviceManager.isClamshellClosed,
                    deviceManager.isInternalMicrophone(deviceID),
                    let fallbackDeviceID = retryResolution.deviceID
                else {
                    throw error
                }

                deviceID = fallbackDeviceID
                resolution = retryResolution
                deviceManager.beginRecordingSetup(deviceID: fallbackDeviceID)
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: fallbackDeviceID)
            }

            guard captureSessionID == sessionID else { throw CancellationError() }
            if let captureFailure { throw captureFailure }
            recordingHasStarted = true
            isCapturingSystemAudio = policy.includesSystemAudio

            deviceManager.recordingDidStart(deviceID: deviceID)
            showRecordingDeviceNotification(for: deviceID, resolution: resolution)
            UserDefaults.standard.set(String(deviceID), forKey: "lastUsedMicrophoneDeviceID")
            resetAudioMeter()
        } catch {
            logger.error(
                "Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
            )
            if captureSessionID == sessionID { await stopRecording() }
            if policy.includesSystemAudio { throw error }
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        let stopTime = MixedAudioWriter.hostTime
        captureSessionID = nil
        recordingHasStarted = false
        isCapturingSystemAudio = false
        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder
        let currentCapture = systemAudioCapture
        let currentWriter = mixedAudioWriter
        systemAudioCapture = nil
        mixedAudioWriter = nil

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }
        await currentCapture?.stop()
        // Both source queues are drained; finalize and deliver the remaining mixed tail.
        if let currentWriter {
            await withCheckedContinuation { continuation in
                audioSetupQueue.async {
                    currentWriter.finish(at: stopTime)
                    continuation.resume()
                }
            }
        }
        onAudioChunk = nil

        resetAudioMeter()

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
        deviceManager.recordingDidStop()
    }

    private func muteSystemAudio() {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.recordingAudioActionDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    private func pauseMedia() {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia()
        }
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID)
            } catch {
                logger.warning(
                    "Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    private func invalidatePreparedAudioUnit() {
        guard let coreAudioRecorder = recorder else { return }
        audioSetupQueue.async {
            coreAudioRecorder.invalidatePreparation()
        }
    }

    func audioMeterSnapshot() -> AudioMeter {
        guard let recorder else {
            return AudioMeter(averagePower: 0, peakPower: 0)
        }

        // Sample audio levels (thread-safe read)
        let averagePower = mixedAudioWriter?.averagePower ?? recorder.averagePower
        let peakPower = mixedAudioWriter?.peakPower ?? recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let audioMeter = AudioMeter(
            averagePower: Double(smoothedAverage),
            peakPower: Double(smoothedPeak)
        )
        smoothedValuesLock.unlock()

        return audioMeter
    }

    private func resetAudioMeter() {
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()
    }

    // MARK: - Cleanup

    deinit {
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioRestorationTask?.cancel()
        if let observer = recordingDeviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder?.teardown()
        let capture = systemAudioCapture
        let writer = mixedAudioWriter
        if capture != nil || writer != nil {
            Task {
                await capture?.stop()
                writer?.finish(at: MixedAudioWriter.hostTime)
            }
        }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
