import AVFoundation
import MediaToolbox

/// A low-pass or high-pass filter on one player item's audio, adjustable while it plays.
/// Auto Mix sweeps its cutoff during a transition. Works on file and progressive streams;
/// HLS items can't be tapped.
final class AutoMixFilterTap: @unchecked Sendable {
    enum Mode: Int32 {
        case off, lowPass, highPass
    }

    private struct Control {
        var mode: Int32 = 0
        var cutoff: Float = 1000
    }

    private static let maxChannels = 8
    private static let stagesPerChannel = 2

    // Written from the main thread and read on the audio thread; a stale value for one
    // render pass only moves the sweep by a few milliseconds.
    private let control = UnsafeMutablePointer<Control>.allocate(capacity: 1)
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: maxChannels * stagesPerChannel * 2)

    private var sampleRate: Float = 44_100
    private var isFloat = false
    private var isNonInterleaved = true
    private var appliedMode: Int32 = 0
    private var appliedCutoff: Float = 0
    private var coefficients: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) = (1, 0, 0, 0, 0)

    init() {
        control.initialize(to: Control())
        state.initialize(repeating: 0, count: Self.maxChannels * Self.stagesPerChannel * 2)
    }

    deinit {
        control.deallocate()
        state.deallocate()
    }

    func set(_ mode: Mode, cutoff: Float) {
        control.pointee = Control(mode: mode.rawValue, cutoff: cutoff)
    }

    /// Mix parameters that route the track's audio through this filter.
    func parameters(for track: AVAssetTrack) -> AVMutableAudioMixInputParameters? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<AutoMixFilterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let filter = Unmanaged<AutoMixFilterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                filter.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let filter = Unmanaged<AutoMixFilterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                filter.process(bufferList, frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(self).release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioProcessingTap = tap
        return parameters
    }

    private func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = Float(format.mSampleRate)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        state.update(repeating: 0, count: Self.maxChannels * Self.stagesPerChannel * 2)
        appliedMode = 0
    }

    private func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let mode = control.pointee.mode
        guard isFloat, mode != 0 else {
            if appliedMode != 0 {
                state.update(repeating: 0, count: Self.maxChannels * Self.stagesPerChannel * 2)
                appliedMode = 0
            }
            return
        }
        let cutoff = control.pointee.cutoff
        if mode != appliedMode || abs(cutoff - appliedCutoff) > 0.5 {
            if mode != appliedMode { state.update(repeating: 0, count: Self.maxChannels * Self.stagesPerChannel * 2) }
            updateCoefficients(mode: mode, cutoff: cutoff)
            appliedMode = mode
            appliedCutoff = cutoff
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channelIndex = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = isNonInterleaved ? 1 : Int(buffer.mNumberChannels)
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1)))
            for channel in 0..<channels where channelIndex + channel < Self.maxChannels {
                let base = (channelIndex + channel) * Self.stagesPerChannel * 2
                for stage in 0..<Self.stagesPerChannel {
                    var z1 = state[base + stage * 2]
                    var z2 = state[base + stage * 2 + 1]
                    let c = coefficients
                    var index = channel
                    for _ in 0..<count {
                        let x = data[index]
                        let y = c.b0 * x + z1
                        z1 = c.b1 * x - c.a1 * y + z2
                        z2 = c.b2 * x - c.a2 * y
                        data[index] = y
                        index += channels
                    }
                    state[base + stage * 2] = z1
                    state[base + stage * 2 + 1] = z2
                }
            }
            channelIndex += channels
        }
    }

    /// RBJ biquad with Butterworth Q; two cascaded stages give a 24 dB/octave slope.
    private func updateCoefficients(mode: Int32, cutoff: Float) {
        let frequency = min(max(cutoff, 20), sampleRate * 0.45)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosine = cos(w0)
        let alpha = sin(w0) / (2 * 0.7071)
        let a0 = 1 + alpha
        let (b0, b1, b2): (Float, Float, Float) = mode == Mode.lowPass.rawValue
            ? ((1 - cosine) / 2, 1 - cosine, (1 - cosine) / 2)
            : ((1 + cosine) / 2, -(1 + cosine), (1 + cosine) / 2)
        coefficients = (b0 / a0, b1 / a0, b2 / a0, -2 * cosine / a0, (1 - alpha) / a0)
    }
}
