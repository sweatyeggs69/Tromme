import Foundation

/// Tempo and beat phase from mono PCM, using an onset envelope and its autocorrelation.
enum BeatEstimator {
    private static let hop = 512
    private static let minBPM = 70.0
    private static let maxBPM = 180.0
    private static let minimumConfidence = 1.6

    /// `samples` start at `startTime` in the track and run at `sampleRate`.
    static func estimate(samples: [Float], sampleRate: Double, startTime: TimeInterval) -> BeatGrid? {
        let onsets = onsetEnvelope(samples)
        let frameRate = sampleRate / Double(hop)
        guard onsets.count > Int(frameRate * 8) else { return nil }

        let minLag = Int((60 / maxBPM) * frameRate)
        let maxLag = min(Int((60 / minBPM) * frameRate) + 1, onsets.count / 2)
        guard minLag > 1, maxLag > minLag else { return nil }

        var scores = [Double](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in lag..<onsets.count { sum += Double(onsets[i] * onsets[i - lag]) }
            let bpm = 60 * frameRate / Double(lag)
            // Gentle preference for common dance and pop tempos.
            let prior = exp(-pow(log2(bpm / 120), 2) / (2 * 0.5 * 0.5))
            scores[lag] = sum / Double(onsets.count - lag) * prior
        }

        guard let bestLag = (minLag...maxLag).max(by: { scores[$0] < scores[$1] }) else { return nil }
        let mean = scores[minLag...maxLag].reduce(0, +) / Double(maxLag - minLag + 1)
        guard mean > 0, scores[bestLag] / mean >= minimumConfidence else { return nil }

        // Parabolic interpolation for a fractional lag.
        var lag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let denominator = a - 2 * b + c
            if denominator != 0 { lag += 0.5 * (a - c) / denominator }
        }
        let period = lag / frameRate
        let bpm = 60 / period

        // Beat phase: the offset inside one period where onsets line up best.
        let periodFrames = lag
        var bestPhase = 0.0
        var bestSum = -Double.infinity
        var phase = 0.0
        while phase < periodFrames {
            var sum = 0.0
            var position = phase
            while Int(position) < onsets.count {
                sum += Double(onsets[Int(position)])
                position += periodFrames
            }
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
            phase += 0.5
        }
        return BeatGrid(bpm: bpm, referenceBeat: startTime + bestPhase / frameRate)
    }

    /// Positive change in log energy of the first difference (a crude high-pass), per hop.
    private static func onsetEnvelope(_ samples: [Float]) -> [Float] {
        let frames = samples.count / hop
        guard frames > 2 else { return [] }
        var energies = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            let base = f * hop
            for i in (base + 1)..<(base + hop) {
                let d = samples[i] - samples[i - 1]
                sum += d * d
            }
            energies[f] = log(1 + 1000 * sum / Float(hop))
        }
        var onsets = [Float](repeating: 0, count: frames)
        for f in 1..<frames { onsets[f] = max(0, energies[f] - energies[f - 1]) }
        // Remove the local mean so steady loudness doesn't dominate the correlation.
        let radius = 20
        var cleaned = onsets
        for f in 0..<frames {
            let lower = max(0, f - radius), upper = min(frames - 1, f + radius)
            var sum: Float = 0
            for i in lower...upper { sum += onsets[i] }
            cleaned[f] = max(0, onsets[f] - sum / Float(upper - lower + 1))
        }
        return cleaned
    }
}
