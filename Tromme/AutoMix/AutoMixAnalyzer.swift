import AVFoundation

/// Decodes a slice of a track into memory and measures loudness and beats.
enum AutoMixAnalyzer {
    private static let sampleRate = 22_050.0
    private static let frameDuration = 0.05

    /// Returns nil when the asset can't be read (for example an HLS stream).
    static func analyze(url: URL, from start: TimeInterval, length: TimeInterval) async -> AutoMixWindowAnalysis? {
        await Task.detached(priority: .utility) { () -> AutoMixWindowAnalysis? in
            guard let samples = await decode(url: url, from: max(0, start), length: length), !samples.isEmpty else {
                return nil
            }
            return measure(samples, startTime: max(0, start))
        }.value
    }

    /// Length of the audio file, read from the asset header.
    static func assetDuration(of url: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration).seconds,
              duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private static func decode(url: URL, from start: TimeInterval, length: TimeInterval) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples = [Float]()
        samples.reserveCapacity(Int(sampleRate * length))
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
        }
        return reader.status == .completed ? samples : nil
    }

    private static func measure(_ samples: [Float], startTime: TimeInterval) -> AutoMixWindowAnalysis {
        let frameSize = Int(sampleRate * frameDuration)
        let frameCount = samples.count / frameSize
        var levels = [Float]()
        levels.reserveCapacity(frameCount)
        for f in 0..<frameCount {
            var sum: Float = 0
            for i in (f * frameSize)..<((f + 1) * frameSize) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(frameSize)).squareRoot()
            levels.append(20 * log10(max(rms, 1e-6)))
        }
        let beat = BeatEstimator.estimate(samples: samples, sampleRate: sampleRate, startTime: startTime)
        return AutoMixWindowAnalysis(windowStart: startTime, frameDuration: frameDuration, levels: levels, beat: beat)
    }
}
