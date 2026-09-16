/// Asked in this order. The first feature that handles a click wins.
/// Blank lines between entries keep parallel PRs from conflicting.
@MainActor
func makeFeatures() -> [any Feature] {
    var features: [any Feature] = []
    // slot: feat/approvals

    features.append(TerminalJump())

    // slot: feat/installer

    // slot: feat/usage

    // slot: feat/sounds

    return features
}
