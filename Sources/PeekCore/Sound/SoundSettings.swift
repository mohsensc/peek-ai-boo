import Foundation

/// Per-event chirp choice, per-event mute, one master volume. The
/// already-existing "muted" key (AppModel's fast on/off) is a different
/// setting entirely and this type never touches it.
public struct SoundSettings: Sendable, Equatable {
    public var needsYouPreset: ChirpPreset
    public var donePreset: ChirpPreset
    public var needsYouMuted: Bool
    public var doneMuted: Bool
    private var _volume: Double
    public var volume: Double {
        get { _volume }
        set { _volume = min(1, max(0, newValue)) }
    }

    public init(needsYouPreset: ChirpPreset = .coin, donePreset: ChirpPreset = .boop,
                needsYouMuted: Bool = false, doneMuted: Bool = false, volume: Double = 1) {
        self.needsYouPreset = needsYouPreset
        self.donePreset = donePreset
        self.needsYouMuted = needsYouMuted
        self.doneMuted = doneMuted
        self._volume = min(1, max(0, volume))
    }

    private enum Key {
        static let needsYouPreset = "sound.needsYouPreset"
        static let donePreset = "sound.donePreset"
        static let needsYouMuted = "sound.needsYouMuted"
        static let doneMuted = "sound.doneMuted"
        static let volume = "sound.volume"
    }

    /// Reads "sound.*" keys, falling back to the defaults above. Never
    /// touches "muted" — that key stays the master toggle's alone.
    public static func load(_ defaults: UserDefaults = .standard) -> SoundSettings {
        var settings = SoundSettings()
        if let raw = defaults.string(forKey: Key.needsYouPreset), let preset = ChirpPreset(rawValue: raw) {
            settings.needsYouPreset = preset
        }
        if let raw = defaults.string(forKey: Key.donePreset), let preset = ChirpPreset(rawValue: raw) {
            settings.donePreset = preset
        }
        if defaults.object(forKey: Key.needsYouMuted) != nil {
            settings.needsYouMuted = defaults.bool(forKey: Key.needsYouMuted)
        }
        if defaults.object(forKey: Key.doneMuted) != nil {
            settings.doneMuted = defaults.bool(forKey: Key.doneMuted)
        }
        if defaults.object(forKey: Key.volume) != nil {
            settings.volume = defaults.double(forKey: Key.volume)
        }
        return settings
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(needsYouPreset.rawValue, forKey: Key.needsYouPreset)
        defaults.set(donePreset.rawValue, forKey: Key.donePreset)
        defaults.set(needsYouMuted, forKey: Key.needsYouMuted)
        defaults.set(doneMuted, forKey: Key.doneMuted)
        defaults.set(volume, forKey: Key.volume)
    }

    /// The preset to play for a state, or nil when that event is muted or
    /// the state doesn't chirp at all. Keeps the mute decision testable
    /// without going anywhere near AVAudioPlayer.
    public func preset(for state: SessionState) -> ChirpPreset? {
        switch state {
        case .needsYou: return needsYouMuted ? nil : needsYouPreset
        case .done: return doneMuted ? nil : donePreset
        case .idle, .working: return nil
        }
    }
}
