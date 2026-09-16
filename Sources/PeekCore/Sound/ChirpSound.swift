import Foundation

/// Five presets, picked independently per event in SoundSettings.
public enum ChirpPreset: String, CaseIterable, Sendable, Identifiable {
    case blip, coin, boop, arp, ghost
    public var id: String { rawValue }
}

/// Synthesizes the same 8-bit square-wave chirps Chirp.swift always played,
/// just moved here and given five distinct note sequences. No sound files.
public enum ChirpSound {
    private static let sampleRate = 8000.0
    // A gentler swing than a full 0/255 square wave, so nothing sounds
    // shrill even at full volume.
    private static let high: UInt8 = 168
    private static let low: UInt8 = 88

    /// 8-bit mono PCM WAV, built in memory. Deterministic: same preset,
    /// same bytes, every call.
    public static func data(_ preset: ChirpPreset) -> Data {
        wav(samples: samples(for: preset))
    }

    /// Each under ~150ms and built from a handful of short notes, so the
    /// whole preset stays under the 300ms ceiling.
    private static func notes(for preset: ChirpPreset) -> [(freq: Double, seconds: Double)] {
        switch preset {
        case .blip:
            return [(720, 0.07)]                              // one short high note
        case .coin:
            return [(660, 0.06), (880, 0.08)]                 // two ascending notes
        case .boop:
            return [(300, 0.14)]                              // one low note
        case .arp:
            return [(440, 0.05), (554, 0.05), (659, 0.06)]    // three-note ascending run
        case .ghost:
            return [(700, 0.06), (560, 0.06), (420, 0.07)]    // three descending notes
        }
    }

    private static func samples(for preset: ChirpPreset) -> [UInt8] {
        var samples: [UInt8] = []
        for (freq, seconds) in notes(for: preset) {
            let count = Int(sampleRate * seconds)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                samples.append(sin(2 * .pi * freq * t) >= 0 ? high : low)
            }
        }
        return samples
    }

    /// 8-bit mono PCM in a plain RIFF/WAVE header.
    private static func wav(samples: [UInt8]) -> Data {
        var data = Data()
        func str(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let dataSize = UInt32(samples.count)
        let rate = UInt32(sampleRate)
        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16)
        u16(1)          // PCM
        u16(1)          // mono
        u32(rate)
        u32(rate)       // byte rate: 8-bit mono, so equals sample rate
        u16(1)          // block align
        u16(8)          // bits per sample
        str("data"); u32(dataSize)
        data.append(contentsOf: samples)
        return data
    }
}
