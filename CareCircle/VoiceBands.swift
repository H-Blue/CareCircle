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

/// Only direct recording requests trigger an action; questions and negations do not.
enum VisitCommand {
    static func isStart(_ text: String) -> Bool {
        var text = text.lowercased().replacingOccurrences(of: "’", with: "'")
        if ["don't", "do not", "not yet", "not ready", "how to", "how do", "how can", "can it", "could it", "would it", "stop recording", "finish recording"].contains(where: text.contains) { return false }
        text = text.replacingOccurrences(of: #"^[\s,]*(?:(?:okay|ok|yes|care circle)[,\s]+)*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?:(?:can|could|would|will) you (?:please )?|please |i (?:want|need|would like)(?: you)? to |let's )"#, with: "", options: .regularExpression)
        let patterns = [#"^(?:please )?(start|begin)\b.{0,25}\b(recording|record|transcribing)\b"#,
                        #"^(?:please )?(record|transcribe)\b.{0,45}\b(visit|appointment|doctor|consultation)\b"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

enum SpokenText {
    static func clean(_ text: String) -> String {
        var value = text
        for (pattern, replacement) in [
            (#"```[\s\S]*?```"#, " "),
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"(?m)^\s*(?:#{1,6}\s*|[-+*]\s+|\d+[.)]\s+)"#, ""),
            (#"[*_`~#|<>]"#, ""),
            (#"!+"#, "."),
            (#"\s+"#, " ")
        ] { value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
