import AVFoundation
import Atomics
import Foundation

/// Both capture paths enqueue here. Only this queue converts, mixes, writes and streams audio.
final class MixedAudioWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.will.myvoice.mixedAudio", qos: .userInitiated)
    private var file: AVAudioFile?
    private var mixer = TimestampedAudioMixer()
    private var startTime: Double?
    private var timer: DispatchSourceTimer?
    private struct Track {
        let converter: AVAudioConverter
        var nextFrame: Int
        var expectedHostTime: Double
    }
    private var tracks: [TimestampedAudioMixer.Source: Track] = [:]
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!
    private let callbackLock = NSLock()
    private var callback: ((Data) -> Void)?
    private let onFailure: (Error) -> Void
    private var failed = false
    private let averageBits = ManagedAtomic<UInt32>(Float(-160).bitPattern)
    private let peakBits = ManagedAtomic<UInt32>(Float(-160).bitPattern)

    var averagePower: Float { Float(bitPattern: averageBits.load(ordering: .relaxed)) }
    var peakPower: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }

    init(url: URL, onAudioChunk: ((Data) -> Void)?, onFailure: @escaping (Error) -> Void) throws {
        callback = onAudioChunk
        self.onFailure = onFailure
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func setAudioChunkCallback(_ callback: ((Data) -> Void)?) {
        callbackLock.lock()
        self.callback = callback
        callbackLock.unlock()
    }

    static var hostTime: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    func begin(at hostTime: Double = MixedAudioWriter.hostTime) {
        queue.sync {
            startTime = hostTime
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self, let startTime = self.startTime else { return }
                // Allow the independently delivered system and microphone callbacks to arrive.
                self.flush(through: Int(max(0, Self.hostTime - startTime - 0.35) * 16_000))
            }
            self.timer = timer
            timer.resume()
        }
    }

    func appendMicrophone(_ samples: [Float], sampleRate: Double, channels: UInt32, hostTime: Double) {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: sampleRate, channels: channels, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                             frameCapacity: AVAudioFrameCount(samples.count / Int(channels))),
              let destination = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                destination.update(from: baseAddress, count: source.count)
            }
        }
        append(buffer, hostTime: hostTime, source: .microphone)
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: Double, source: TimestampedAudioMixer.Source) {
        queue.async { [self] in
            guard file != nil, let startTime, !failed, hostTime.isFinite,
                  abs(hostTime - Self.hostTime) < 5 else { return }
            do {
                let frame = Int(((hostTime - startTime) * 16_000).rounded())
                if let track = tracks[source],
                   track.converter.inputFormat != buffer.format || abs(track.expectedHostTime - hostTime) > 0.05 {
                    try finishConversion(source: source)
                    tracks[source] = nil
                }
                if tracks[source] == nil {
                    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                    guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat)
                    else { throw MixedAudioError.conversionFailed }
                    converter.primeMethod = .none
                    tracks[source] = Track(converter: converter, nextFrame: frame, expectedHostTime: hostTime)
                }
                let samples = try convert(buffer, converter: tracks[source]!.converter)
                mixer.append(samples, startingAt: tracks[source]!.nextFrame, source: source)
                tracks[source]!.nextFrame += samples.count
                tracks[source]!.expectedHostTime = hostTime + Double(buffer.frameLength) / buffer.format.sampleRate
            } catch {
                fail(error)
            }
        }
    }

    /// Call after both capture sources have stopped and drained their delivery queues.
    func finish(at hostTime: Double) {
        queue.sync {
            timer?.cancel()
            timer = nil
            for source in Array(tracks.keys) {
                do { try finishConversion(source: source) } catch { fail(error) }
            }
            if let startTime {
                flush(through: Int(max(0, hostTime - startTime) * 16_000))
            }
            file = nil // Finalize WAV header before transcription opens it.
            startTime = nil
            tracks.removeAll()
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, converter: AVAudioConverter) throws -> [Float] {
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 32)
        else { throw MixedAudioError.conversionFailed }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? MixedAudioError.conversionFailed as NSError }
        guard let samples = output.floatChannelData?[0] else { throw MixedAudioError.conversionFailed }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    private func finishConversion(source: TimestampedAudioMixer.Source) throws {
        guard var track = tracks[source], let startTime else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
        else { throw MixedAudioError.conversionFailed }
        var error: NSError?
        let status = track.converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { throw error ?? MixedAudioError.conversionFailed as NSError }
        let remaining = max(0, Int(((track.expectedHostTime - startTime) * 16_000).rounded()) - track.nextFrame)
        let count = min(Int(output.frameLength), remaining)
        if count > 0, let samples = output.floatChannelData?[0] {
            mixer.append(Array(UnsafeBufferPointer(start: samples, count: count)),
                         startingAt: track.nextFrame, source: source)
            track.nextFrame += count
            tracks[source] = track
        }
    }

    private func flush(through frame: Int) {
        guard let file, !failed else { return }
        do {
            try mixer.drain(through: frame) { [self] samples in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)),
                      let destination = buffer.int16ChannelData?[0] else { throw MixedAudioError.conversionFailed }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!, count: source.count)
                }
                try file.write(from: buffer)
                let normalized = samples.map { Float($0) / 32768 }
                let rms = sqrt(normalized.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                let peak = normalized.reduce(Float(0)) { max($0, abs($1)) }
                averageBits.store((20 * log10(max(rms, 0.000001))).bitPattern, ordering: .relaxed)
                peakBits.store((20 * log10(max(peak, 0.000001))).bitPattern, ordering: .relaxed)
                callbackLock.lock()
                let audioChunk = callback
                callbackLock.unlock()
                let data = samples.withUnsafeBytes { Data($0) }
                audioChunk?(data)
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        timer?.cancel()
        onFailure(error)
    }

    deinit { timer?.cancel() }
}

enum MixedAudioError: LocalizedError {
    case conversionFailed
    case permissionRequired
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .conversionFailed: return String(localized: "System audio could not be processed. Start a new recording.")
        case .permissionRequired: return String(localized: "Allow screen and system audio recording in System Settings, then try again.")
        case .noDisplay: return String(localized: "No display is available for system audio capture.")
        }
    }
}
