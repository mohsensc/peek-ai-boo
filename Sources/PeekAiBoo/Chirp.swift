import AVFoundation
import PeekCore

/// Plays whichever preset SoundSettings has picked for the given state.
/// The synthesis itself (and the presets) live in PeekCore's ChirpSound.
@MainActor
enum Chirp {
    /// Kept alive while playing; AVAudioPlayer stops if it's deallocated.
    private static var players: [AVAudioPlayer] = []

    static func play(for state: SessionState) {
        let settings = SoundSettings.load()
        switch state {
        case .needsYou:
            guard !settings.needsYouMuted else { return }
            play(settings.needsYouPreset, volume: settings.volume)
        case .done:
            guard !settings.doneMuted else { return }
            play(settings.donePreset, volume: settings.volume)
        default:
            return
        }
    }

    /// What the settings window's preview buttons call directly, bypassing
    /// session state and per-event mute.
    static func play(_ preset: ChirpPreset, volume: Double) {
        // A blocked or missing audio device shouldn't take the app down.
        guard let player = try? AVAudioPlayer(data: ChirpSound.data(preset)) else { return }
        player.volume = Float(volume)
        players.append(player)
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            players.removeAll { !$0.isPlaying }
        }
    }
}
