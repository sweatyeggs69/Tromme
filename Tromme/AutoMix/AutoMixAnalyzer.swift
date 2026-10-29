import AVFoundation

/// Decodes a whole track into memory and measures its loudness, beats and outro.
enum AutoMixAnalyzer {
    private static let sampleRate = 22_050.0

    /// Which end of the window the transition uses.
    enum Edge { case start, end }

    /// Decodes the whole song and builds its profile. Returns nil when the file can't be read.
    static func profile(url: URL) async -> TrackMixProfile? {
        await Task.detached(priority: .utility) { () -> TrackMixProfile? in
            guard let length = await assetDuration(of: url),
                  let samples = await decode(url: url, from: 0, length: length + 1), !samples.isEmpty else {
                return nil
            }
            return makeProfile(samples)
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
        let provider = reader.outputProvider(for: output)
        do { try reader.start() } catch { return nil }

        var samples = [Float]()
        samples.reserveCapacity(Int(sampleRate * length))
        do {
            while let ready = try await provider.next() {
                let chunk: [Float] = ready.withUnsafeSampleBuffer { buffer in
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
                    let byteCount = CMBlockBufferGetDataLength(block)
                    var values = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                    let status = values.withUnsafeMutableBytes { raw in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
                    }
                    return status == kCMBlockBufferNoErr ? values : []
                }
                samples.append(contentsOf: chunk)
            }
        } catch {
            return nil
        }
        return reader.status == .completed ? samples : nil
    }

    private static func makeProfile(_ samples: [Float]) -> TrackMixProfile {
        let duration = Double(samples.count) / sampleRate
        let frameSize = Int(sampleRate * TrackMixProfile.frameDuration)
        var levels = [Int8]()
        levels.reserveCapacity(samples.count / frameSize)
        for f in 0..<(samples.count / frameSize) {
            var sum: Float = 0
            for i in (f * frameSize)..<((f + 1) * frameSize) { sum += samples[i] * samples[i] }
            let decibels = 20 * log10(max((sum / Float(frameSize)).squareRoot(), 1e-6))
            levels.append(Int8(max(-127, min(0, decibels.rounded()))))
        }

        var beats = [TrackMixProfile.WindowBeat]()
        var start: TimeInterval = 0
        while start + TrackMixProfile.beatWindow <= duration {
            let lower = Int(start * sampleRate)
            let upper = min(samples.count, Int((start + TrackMixProfile.beatWindow) * sampleRate))
            let grid = BeatEstimator.estimate(samples: Array(samples[lower..<upper]), sampleRate: sampleRate, startTime: start)
            beats.append(.init(start: start, bpm: grid?.bpm, referenceBeat: grid?.referenceBeat))
            start += TrackMixProfile.beatHop
        }

        return TrackMixProfile(
            version: TrackMixProfile.currentVersion,
            duration: duration,
            levels: levels,
            beats: beats,
            outroStart: outroStart(levels: levels, beats: beats, duration: duration)
        )
    }

    /// The start of a closing run of 5 s blocks that lost the beat (in a song that has one)
    /// or sit at least 6 dB under the song's body, when that run lasts 20 s or more.
    private static func outroStart(levels: [Int8], beats: [TrackMixProfile.WindowBeat], duration: TimeInterval) -> TimeInterval? {
        let block: TimeInterval = 5
        let framesPerBlock = Int(block / TrackMixProfile.frameDuration)
        let blockCount = levels.count / framesPerBlock
        guard blockCount >= 8, !beats.isEmpty else { return nil }

        let blockLevels: [Float] = (0..<blockCount).map { k in
            let audible = levels[(k * framesPerBlock)..<((k + 1) * framesPerBlock)].filter { $0 > -50 }
            guard !audible.isEmpty else { return -100 }
            return Float(audible.reduce(0) { $0 + Int($1) }) / Float(audible.count)
        }
        let loud = blockLevels.filter { $0 > -60 }.sorted()
        guard !loud.isEmpty else { return nil }
        let body = loud[loud.count * 3 / 4]
        let songHasBeat = beats.filter { $0.bpm != nil }.count * 2 >= beats.count

        func hasBeat(_ k: Int) -> Bool {
            beats.last { $0.start <= Double(k) * block + 0.1 }?.bpm != nil
        }
        func isOutroLike(_ k: Int) -> Bool {
            (songHasBeat && !hasBeat(k)) || blockLevels[k] < body - 6
        }

        // Skip the silence at the very end, then walk back through the outro.
        var last = blockCount - 1
        while last > 0, blockLevels[last] < -45 { last -= 1 }
        var k = last
        while k >= 0, isOutroLike(k) { k -= 1 }
        let runStart = k + 1
        guard runStart <= last, runStart > blockCount / 2,
              Double(last - runStart + 1) * block >= 20 else { return nil }
        return Double(runStart) * block
    }
}
