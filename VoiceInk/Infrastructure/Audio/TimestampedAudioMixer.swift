import Foundation

/// A bounded, host-clock timeline. Missing input is silence; late input never moves speech in time.
/// Confined to the mixed writer's serial queue.
struct TimestampedAudioMixer {
    enum Source: Hashable { case microphone, system }
    static let sampleRate = 16_000
    static let blockSize = 320
    private static let maximumLookAhead = sampleRate * 5

    private struct Block {
        var microphone = [Float](repeating: 0, count: blockSize)
        var system = [Float](repeating: 0, count: blockSize)
    }

    private var blocks: [Int: Block] = [:]
    private(set) var nextFrame = 0
    var bufferedBlockCount: Int { blocks.count }

    mutating func append(_ samples: [Float], startingAt frame: Int, source: Source) {
        guard !samples.isEmpty, frame < nextFrame + Self.maximumLookAhead,
            frame > -Self.maximumLookAhead else { return }
        let lower = max(0, nextFrame - frame)
        let upper = min(samples.count, nextFrame + Self.maximumLookAhead - frame)
        guard lower < upper else { return }

        for index in lower..<upper {
            let position = frame + index
            let blockID = position / Self.blockSize
            let offset = position % Self.blockSize
            if blocks[blockID] == nil { blocks[blockID] = Block() }
            let value = samples[index].isFinite ? samples[index] : 0
            switch source {
            case .microphone: blocks[blockID]!.microphone[offset] = value
            case .system: blocks[blockID]!.system[offset] = value
            }
        }
    }

    mutating func drain(through endFrame: Int, emit: ([Int16]) throws -> Void) rethrows {
        while nextFrame < endFrame {
            let blockID = nextFrame / Self.blockSize
            let offset = nextFrame % Self.blockSize
            let count = min(Self.blockSize - offset, endFrame - nextFrame)
            let block = blocks[blockID]
            var pcm = [Int16](repeating: 0, count: count)
            if let block {
                for index in 0..<count {
                    // Equal gain leaves headroom when both participants speak at once.
                    let sample = (block.microphone[offset + index] + block.system[offset + index]) * 0.5
                    pcm[index] = Int16(max(-32768, min(32767, sample * 32767)))
                }
            }
            try emit(pcm)
            nextFrame += count
            if nextFrame % Self.blockSize == 0 { blocks.removeValue(forKey: blockID) }
        }
    }
}
