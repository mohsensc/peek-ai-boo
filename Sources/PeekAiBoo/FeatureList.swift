/// Asked in this order. The first feature that handles a click wins.
/// Blank lines between entries keep parallel PRs from conflicting.
@MainActor
func makeFeatures() -> [any Feature] {
    var features: [any Feature] = []
    features.append(Approvals())

    features.append(TerminalJump())

    features.append(InstallerFeature())

    features.append(UsageFeature())

    // slot: feat/sounds

    return features
}
