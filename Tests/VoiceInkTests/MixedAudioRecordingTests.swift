import AVFoundation
import XCTest
@testable import VoiceInk

final class MixedAudioRecordingTests: XCTestCase {
    func testTimestampAlignmentIncludesBothSourcesWithoutConcatenatingThem() {
        var mixer = TimestampedAudioMixer()
        mixer.append([Float](repeating: 0.4, count: 640), startingAt: 0, source: .microphone)
        // A late-delivered system block belongs at frame 320, not at the end of the microphone.
        mixer.append([Float](repeating: 0.6, count: 320), startingAt: 320, source: .system)
        var output: [Int16] = []
        mixer.drain(through: 960) { output += $0 }
        XCTAssertEqual(output.count, 960)
        XCTAssertEqual(output[100], Int16(0.2 * 32767), accuracy: 1)
        XCTAssertEqual(output[400], Int16(0.5 * 32767), accuracy: 1)
        XCTAssertEqual(output[800], 0)
    }

    func testMissingSourceAndLatePacketsNeverBlockOrShiftAudio() {
        var mixer = TimestampedAudioMixer()
        mixer.append([0.8, 0.8], startingAt: 0, source: .system)
        var output: [Int16] = []
        mixer.drain(through: 320) { output += $0 }
        mixer.append([1, 1], startingAt: 0, source: .microphone)
        mixer.append([0.6, 0.6], startingAt: 320, source: .microphone)
        mixer.drain(through: 322) { output += $0 }
        XCTAssertEqual(output.count, 322)
        XCTAssertEqual(output[0], Int16(0.4 * 32767), accuracy: 1)
        XCTAssertEqual(output[100], 0)
        XCTAssertEqual(output[320], Int16(0.3 * 32767), accuracy: 1)
    }

    func testStopFlushesPartialBlockAndClipsSafely() {
        var mixer = TimestampedAudioMixer()
        mixer.append([2, -2, .nan, .infinity], startingAt: 0, source: .microphone)
        mixer.append([2, -2, 0.5, 0.5], startingAt: 0, source: .system)
        var output: [Int16] = []
        mixer.drain(through: 4) { output += $0 }
        XCTAssertEqual(output, [32767, -32768, 8191, 8191])
    }

    func testTimelineMemoryIsBoundedAndDiscardsPreStartAudio() {
        var mixer = TimestampedAudioMixer()
        mixer.append([0.4, 0.8], startingAt: -1, source: .system)
        mixer.append([1], startingAt: 1_000_000_000, source: .microphone)
        XCTAssertEqual(mixer.bufferedBlockCount, 1)
        var output: [Int16] = []
        mixer.drain(through: 320) { output += $0 }
        XCTAssertEqual(output[0], Int16(0.4 * 32767), accuracy: 1)
        XCTAssertEqual(mixer.bufferedBlockCount, 0)
    }

    func testMixedWriterResamplesBothTracksAndStreamsExactlyTheSavedWAV() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = MixedAudioWriter.hostTime
        var streamed = Data()
        var failures: [Error] = []
        let writer = try MixedAudioWriter(url: url, onAudioChunk: { streamed.append($0) },
                                          onFailure: { failures.append($0) })
        writer.begin(at: start)
        let mic = sine(frequency: 220, sampleRate: 44_100, frames: 4410)
        writer.appendMicrophone(mic, sampleRate: 44_100, channels: 1, hostTime: start)
        let systemFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let system = AVAudioPCMBuffer(pcmFormat: systemFormat, frameCapacity: 4800)!
        system.frameLength = 4800
        let remote = sine(frequency: 440, sampleRate: 48_000, frames: 4800)
        for channel in 0..<2 {
            remote.withUnsafeBufferPointer { system.floatChannelData![channel].update(from: $0.baseAddress!, count: $0.count) }
        }
        writer.append(system, hostTime: start, source: .system)
        writer.finish(at: start + 0.1)

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.length, 1600, accuracy: 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let pcm = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        XCTAssertEqual(pcm.withUnsafeBytes { Data($0) }, streamed)
        XCTAssertGreaterThan(toneAmplitude(pcm, frequency: 220), 0.12, "Microphone track must survive mixing")
        XCTAssertGreaterThan(toneAmplitude(pcm, frequency: 440), 0.12, "System track must survive mixing")
    }

    func testMeetingPolicySkipsMutingAndDefaultRemainsMicrophoneOnly() throws {
        let suite = "MixedAudioRecordingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AudioCaptureSettings.includesSystemAudio(defaults: defaults))
        defaults.set(true, forKey: AudioCaptureSettings.includeSystemAudioKey)
        XCTAssertFalse(RecordingAudioPolicy(includesSystemAudio: AudioCaptureSettings.includesSystemAudio(defaults: defaults)).allowsMutingAndPausing)
        XCTAssertTrue(RecordingAudioPolicy(includesSystemAudio: false).allowsMutingAndPausing)
    }

    private func sine(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(0.4 * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func toneAmplitude(_ pcm: [Int16], frequency: Double) -> Double {
        let range = 320..<min(pcm.count, 1280)
        var real = 0.0
        var imaginary = 0.0
        for index in range {
            let angle = 2 * Double.pi * frequency * Double(index) / 16_000
            let value = Double(pcm[index]) / 32768
            real += value * cos(angle)
            imaginary += value * sin(angle)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(range.count)
    }
}
