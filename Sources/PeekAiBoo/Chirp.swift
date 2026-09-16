import AVFoundation
import PeekCore

/// Two tiny square-wave chirps, synthesized in memory. No sound files, no
/// audio engine graph — just enough WAV bytes to hand AVAudioPlayer.
@MainActor
enum Chirp {
    /// Kept alive while playing; AVAudioPlayer stops if it's deallocated.
    private static var players: [AVAudioPlayer] = []

    static func play(for state: SessionState) {
        let data: Data
        switch state {
        case .needsYou:
            data = tone(notes: [(660, 0.08), (880, 0.1)])   // rising two notes
        case .done:
            data = tone(notes: [(520, 0.12)])                // one falling-feel note
        default:
            return
        }
        // A blocked or missing audio device shouldn't take the app down.
        guard let player = try? AVAudioPlayer(data: data) else { return }
        players.append(player)
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            players.removeAll { !$0.isPlaying }
        }
    }

    private static func tone(notes: [(freq: Double, seconds: Double)]) -> Data {
        let sampleRate = 8000.0
        var samples: [UInt8] = []
        for (freq, seconds) in notes {
            let count = Int(sampleRate * seconds)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                samples.append(sin(2 * .pi * freq * t) >= 0 ? 200 : 56)
            }
        }
        return wav(samples: samples, sampleRate: UInt32(sampleRate))
    }

    /// 8-bit mono PCM in a plain RIFF/WAVE header.
    private static func wav(samples: [UInt8], sampleRate: UInt32) -> Data {
        var data = Data()
        func str(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let dataSize = UInt32(samples.count)
        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16)
        u16(1)                 // PCM
        u16(1)                 // mono
        u32(sampleRate)
        u32(sampleRate)        // byte rate: 8-bit mono, so equals sample rate
        u16(1)                 // block align
        u16(8)                 // bits per sample
        str("data"); u32(dataSize)
        data.append(contentsOf: samples)
        return data
    }
}
