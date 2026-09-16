import AppKit
import PeekCore
import SwiftUI

/// Owns the settings window (this wave's only piece that needs one) and
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
        // LSUIElement means we never otherwise come forward.
        NSApp.activate()
        if window == nil {
            window = SettingsWindow.make(app: app)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// NeedsYou and done each get a preset picker, a preview button and a
/// mute toggle. One volume slider covers both.
private struct SoundSettingsSection: View {
    @State private var settings = SoundSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sounds").font(.headline)
            eventRow(title: "Needs you", preset: $settings.needsYouPreset, muted: $settings.needsYouMuted)
            eventRow(title: "Done", preset: $settings.donePreset, muted: $settings.doneMuted)
            HStack {
                Text("Volume")
                Slider(value: $settings.volume, in: 0...1)
            }
        }
        .onChange(of: settings) { _, newValue in
            newValue.save()
        }
    }

    private func eventRow(title: String, preset: Binding<ChirpPreset>, muted: Binding<Bool>) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Picker("", selection: preset) {
                ForEach(ChirpPreset.allCases) { p in
                    Text(p.rawValue.capitalized).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            Button {
                Chirp.play(preset.wrappedValue, volume: settings.volume)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            Toggle("Mute", isOn: muted)
        }
    }
}
