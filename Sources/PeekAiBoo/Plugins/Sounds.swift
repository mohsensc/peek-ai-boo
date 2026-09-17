import AppKit
import PeekCore
import SwiftUI

/// Owns the settings window (the only feature that needs one so far) and
/// contributes the sound section to it. Chirp.play already reads
/// SoundSettings on its own, so this feature's job is just the UI to
/// change them.
@MainActor
final class Sounds: NSObject, Feature {
    private var window: NSWindow?

    func menuItems(app: AppModel) -> [NSMenuItem] {
        let item = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = app
        return [item]
    }

    func settingsSections(app: AppModel) -> AnyView? {
        AnyView(SoundSettingsSection())
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppModel else { return }
        showSettings(app: app)
    }

    /// Same as the menu item, for `--open-settings` — a screenshot script
    /// has no menu to click.
    func showSettings(app: AppModel) {
        // LSUIElement means we never otherwise come forward.
        NSApp.activate()
        if window == nil {
            window = SettingsWindow.make(app: app)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// NeedsYou and done each get their own section: a preset picker, a preview
/// button and a mute toggle. One volume slider covers both.
private struct SoundSettingsSection: View {
    @State private var settings = SoundSettings.load()

    @ViewBuilder
    var body: some View {
        eventSection(title: "Needs you", preset: $settings.needsYouPreset, muted: $settings.needsYouMuted)
        eventSection(title: "Done", preset: $settings.donePreset, muted: $settings.doneMuted)
        Section("Volume") {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $settings.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: settings) { _, newValue in newValue.save() }
    }

    private func eventSection(title: String, preset: Binding<ChirpPreset>, muted: Binding<Bool>) -> some View {
        Section(title) {
            HStack {
                Text("Sound")
                Spacer()
                Picker("", selection: preset) {
                    ForEach(ChirpPreset.allCases) { p in
                        Text(p.rawValue.capitalized).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                Button {
                    Chirp.play(preset.wrappedValue, volume: settings.volume)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .buttonBorderShape(.circle)
                .help("Preview")
            }
            Toggle("Mute", isOn: muted)
                .toggleStyle(.switch)
        }
    }
}
