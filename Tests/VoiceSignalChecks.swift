import Foundation

@main
struct VoiceSignalChecks {
    static func measure(frequency: Double, amplitude: Float) -> (Float, Float) {
        var analyzer = VoiceBands()
        let samples = (0..<4096).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / 48000)) }
        return samples.withUnsafeBufferPointer { analyzer.levels(samples: $0, sampleRate: 48000) }
    }

    static func main() {
        for command in ["Start recording for my doctor's visit", "Can you begin recording?", "Please record my appointment", "Transcribe this doctor visit"] {
            precondition(VisitCommand.isStart(command), "Direct visit command must open recording: \(command)")
        }
        for question in ["Don't start recording", "How do I start recording?", "Do not record my visit", "Can it record a doctor visit?", "Stop recording", "I started recording yesterday"] {
            precondition(!VisitCommand.isStart(question), "Must not record for a negation or question about capabilities: \(question)")
        }
        precondition(SpokenText.clean("**Hello!** [Your notes](https://example.com)\n* Take care!") == "Hello. Your notes Take care.", "Formatting must not be read aloud.")
        precondition(SpokenText.clean("[calm] I’m here to help.") == "I’m here to help.", "Voice direction tags must not appear in displayed replies.")
        let low = measure(frequency: 80, amplitude: 0.1)
        let high = measure(frequency: 6000, amplitude: 0.1)
        let quiet = measure(frequency: 80, amplitude: 0.005)
        let silence = measure(frequency: 80, amplitude: 0)
        precondition(low.0 > low.1 + 0.3, "Bass must drive the center more strongly than the outer ring.")
        precondition(high.1 > high.0 + 0.3, "Treble must drive the outer ring more strongly than the center.")
        precondition(low.0 > quiet.0, "Louder input must produce a larger response.")
        precondition(silence.0 == 0 && silence.1 == 0, "Silence must settle to zero.")
        for amplitude: Float in [0, 0.001, 0.1, 1, 10] {
            let levels = measure(frequency: 250, amplitude: amplitude)
            precondition((0...1).contains(levels.0) && (0...1).contains(levels.1), "Animation energy must stay bounded.")
        }
        print("Voice signal checks passed: bass, treble, loudness, silence, and bounds.")
    }
}
