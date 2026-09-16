/// Asked in this order. The first feature that handles a click wins.
/// Blank lines between entries keep parallel PRs from conflicting.
@MainActor
func makeFeatures() -> [any Feature] {
    var features: [any Feature] = []
    features.append(Approvals())

    // slot: feat/terminal-jump

    features.append(InstallerFeature())

    // slot: feat/usage

    // slot: feat/sounds

    return features
}
