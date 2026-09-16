import Foundation
import Testing
@testable import PeekCore

@Suite struct ChirpSoundTests {
    // Matches ChirpSound's own synthesis rate. Not part of the public
    // interface, but fixed enough to check "under ~300ms" against.
    private static let sampleRate = 8000.0

    @Test(arguments: ChirpPreset.allCases)
    func hasValidWavHeader(preset: ChirpPreset) {
        let data = ChirpSound.data(preset)
        #expect(data.count > 44)
        #expect(data.subdata(in: 0..<4) == Data("RIFF".utf8))
        #expect(data.subdata(in: 8..<12) == Data("WAVE".utf8))
        #expect(data.subdata(in: 12..<16) == Data("fmt ".utf8))
        #expect(data.subdata(in: 36..<40) == Data("data".utf8))
        let declared = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(declared == UInt32(data.count - 44))
    }

    @Test func allPresetsAreDistinct() {
        let bytes = Set(ChirpPreset.allCases.map { ChirpSound.data($0) })
        #expect(bytes.count == ChirpPreset.allCases.count)
    }

    @Test(arguments: ChirpPreset.allCases)
    func sameByteEveryCall(preset: ChirpPreset) {
        #expect(ChirpSound.data(preset) == ChirpSound.data(preset))
    }

    @Test(arguments: ChirpPreset.allCases)
    func staysUnderThreeHundredMs(preset: ChirpPreset) {
        let data = ChirpSound.data(preset)
        let seconds = Double(data.count - 44) / Self.sampleRate
        #expect(seconds > 0)
        #expect(seconds < 0.3)
    }

    @Test(arguments: ChirpPreset.allCases)
    func peakStaysGentle(preset: ChirpPreset) {
        let data = ChirpSound.data(preset)
        let samples = data.suffix(from: 44)
        let peakDeviation = samples.map { abs(Int($0) - 128) }.max() ?? 0
        // Audible (not silence) but well short of a full 0/255 swing.
        #expect(peakDeviation > 0)
        #expect(peakDeviation <= 80)
    }
}
