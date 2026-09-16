import Foundation
import Testing
@testable import PeekCore

@Suite struct SoundSettingsTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func loadOnEmptyStoreReturnsDocumentedDefaults() {
        let defaults = freshDefaults("SoundSettingsTests.empty")
        let settings = SoundSettings.load(defaults)
        #expect(settings.needsYouPreset == .coin)
        #expect(settings.donePreset == .boop)
        #expect(settings.needsYouMuted == false)
        #expect(settings.doneMuted == false)
        #expect(settings.volume == 1)
    }

    @Test func saveThenLoadRoundTripsEveryField() {
        let defaults = freshDefaults("SoundSettingsTests.roundtrip")
        var settings = SoundSettings()
        settings.needsYouPreset = .arp
        settings.donePreset = .ghost
        settings.needsYouMuted = true
        settings.doneMuted = true
        settings.volume = 0.4
        settings.save(defaults)

        #expect(SoundSettings.load(defaults) == settings)
    }

    @Test func volumeClampsAboveOne() {
        var settings = SoundSettings()
        settings.volume = 5
        #expect(settings.volume == 1)
    }

    @Test func volumeClampsBelowZero() {
        var settings = SoundSettings()
        settings.volume = -3
        #expect(settings.volume == 0)
    }

    @Test func initClampsOutOfRangeVolumeToo() {
        #expect(SoundSettings(volume: 9).volume == 1)
        #expect(SoundSettings(volume: -9).volume == 0)
    }

    @Test func neverWritesTheMasterMuteKey() {
        let defaults = freshDefaults("SoundSettingsTests.masterMuteWrite")
        defaults.set(true, forKey: "muted")
        var settings = SoundSettings()
        settings.needsYouMuted = true
        settings.doneMuted = true
        settings.save(defaults)
        #expect(defaults.bool(forKey: "muted") == true)
    }

    @Test func neverReadsTheMasterMuteKey() {
        let defaults = freshDefaults("SoundSettingsTests.masterMuteRead")
        defaults.set(true, forKey: "muted")
        let settings = SoundSettings.load(defaults)
        // "muted" being true shouldn't leak into either per-event mute.
        #expect(settings.needsYouMuted == false)
        #expect(settings.doneMuted == false)
    }

    @Test func mutedEventPicksNoPreset() {
        var settings = SoundSettings()
        settings.needsYouMuted = true
        // nil here is what "mute means no playback call" boils down to:
        // Chirp.play(for:) never reaches AVAudioPlayer without a preset.
        #expect(settings.preset(for: .needsYou) == nil)
        #expect(settings.preset(for: .done) == settings.donePreset)
    }

    @Test func unmutedEventPicksItsConfiguredPreset() {
        var settings = SoundSettings()
        settings.needsYouPreset = .ghost
        settings.donePreset = .arp
        #expect(settings.preset(for: .needsYou) == .ghost)
        #expect(settings.preset(for: .done) == .arp)
    }

    @Test func idleAndWorkingNeverChirp() {
        let settings = SoundSettings()
        #expect(settings.preset(for: .idle) == nil)
        #expect(settings.preset(for: .working) == nil)
    }
}
