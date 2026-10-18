import Foundation

/// Separate low- and high-frequency energy, measured from the real microphone signal.
struct VoiceBands {
    private var bassFilter: Float = 0
    private var highLowPass: Float = 0

    mutating func levels(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> (Float, Float) {
        let bassAlpha = Float(1 - exp(-2 * Double.pi * 250 / sampleRate))
        let trebleAlpha = Float(1 - exp(-2 * Double.pi * 2000 / sampleRate))
        var bassPower: Float = 0
        var treblePower: Float = 0
        for sample in samples {
            bassFilter += bassAlpha * (sample - bassFilter)
            highLowPass += trebleAlpha * (sample - highLowPass)
            let high = sample - highLowPass
            bassPower += bassFilter * bassFilter
            treblePower += high * high
        }
        func normalized(_ power: Float) -> Float {
            let db = 10 * log10(max(power / Float(max(samples.count, 1)), 0.00000001))
            return min(1, max(0, (db + 58) / 42))
        }
        return (normalized(bassPower), normalized(treblePower))
    }
}
