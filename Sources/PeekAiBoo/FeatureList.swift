/// Asked in this order. The first feature that handles a click wins.
@MainActor
func makeFeatures() -> [any Feature] {
    var features: [any Feature] = []
    features.append(Approvals())
    features.append(TerminalJump())
    features.append(InstallerFeature())
    features.append(UsageFeature())
    features.append(Sounds())
    return features
}
