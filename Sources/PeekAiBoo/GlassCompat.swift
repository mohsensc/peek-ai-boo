import AppKit
import SwiftUI

/// The one place that knows about Liquid Glass. Everything else asks for a
/// surface, a button or a container and gets a plain system material below
/// macOS 26 (or with Reduce Transparency on) instead of branching itself.
enum GlassCompat {
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The one color every confirm/selected state uses: Allow, Send, a
    /// picked option, and Other while it's open or committed. Not
    /// `.accentColor` -- tinted glass rendered as flat gray on this Mac's
    /// accent setting (confirmed with a pixel sample), so this is
    /// `NSColor.systemGreen` by name, which still adapts to light/dark on
    /// its own.
    static let confirmTint = Color(nsColor: .systemGreen)
}

private struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tinted = false
    /// Concentric with the panel's own `.containerShape` on macOS 26 (inner
    /// radius = outer minus the gap between them); a fixed radius below
    /// that, since there's nothing to compute it from.
    var concentric = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            let glass: Glass = tinted ? .regular.tint(GlassCompat.confirmTint) : .regular
            if concentric {
                content.glassEffect(glass, in: ConcentricRectangle())
            } else {
                content.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tinted ? AnyShapeStyle(GlassCompat.confirmTint.opacity(0.85)) : AnyShapeStyle(.regularMaterial))
            )
        }
    }
}

private struct GlassCapsuleSurface: ViewModifier {
    var tinted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(tinted ? .regular.tint(GlassCompat.confirmTint) : .regular, in: .capsule)
        } else {
            content.background(
                Capsule().fill(tinted ? AnyShapeStyle(GlassCompat.confirmTint.opacity(0.85)) : AnyShapeStyle(.regularMaterial))
            )
        }
    }
}

private struct GlassCircleSurface: ViewModifier {
    var tinted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(tinted ? .regular.tint(GlassCompat.confirmTint) : .regular, in: .circle)
        } else {
            content.background(
                Circle().fill(tinted ? AnyShapeStyle(GlassCompat.confirmTint.opacity(0.85)) : AnyShapeStyle(.regularMaterial))
            )
        }
    }
}

extension View {
    /// The panel and its cards: regular Liquid Glass on macOS 26, a plain
    /// system material everywhere else. `concentric` asks for the panel's
    /// own corner math instead of a fixed radius (macOS 26 only).
    func glassSurface(cornerRadius: CGFloat, tinted: Bool = false, concentric: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tinted: tinted, concentric: concentric))
    }

    /// Question options, the Other field, session-row hover: same material,
    /// capsule-shaped.
    func glassCapsule(tinted: Bool = false) -> some View {
        modifier(GlassCapsuleSurface(tinted: tinted))
    }

    /// The small round icon buttons on a ping capsule (terminal, deny,
    /// allow): same material, circle-shaped.
    func glassCircle(tinted: Bool = false) -> some View {
        modifier(GlassCircleSurface(tinted: tinted))
    }
}

/// Groups glass shapes on the panel so they sample and morph together
/// instead of each drawing its own isolated blur. A no-op below macOS 26.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

/// Allow/Deny/Send and the rest: `.glassProminent`/`.glass` on macOS 26, a
/// filled or outlined capsule below that. One generic label so call sites
/// don't have to know which path they're on.
struct GlassButton<Label: View>: View {
    var prominent = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 26, *), prominent {
            Button(action: action, label: label)
                .buttonStyle(.glassProminent)
                // .glassProminent draws from the system accent, not from a
                // Glass value's own .tint -- without this it rendered as
                // flat gray on this Mac's accent setting. See GlassCompat.confirmTint.
                .tint(GlassCompat.confirmTint)
        } else if #available(macOS 26, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
        } else {
            Button(action: action) {
                label()
                    .foregroundStyle(prominent ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(prominent ? GlassCompat.confirmTint : Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }
}

/// The terminal/deny/allow buttons on a ping capsule: one SF Symbol in a
/// small circular glass button. Same macOS-26-or-fallback split as
/// GlassButton, just circular and icon-only. `size` defaults to the panel's
/// row height (24); the two-line ping row asks for something smaller so the
/// buttons stay sized to row 1 instead of setting it.
struct GlassIconButton: View {
    var systemName: String
    var tinted = false
    var help: String?
    var size: CGFloat = 24
    var action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26, *), tinted {
                Button(action: action) { icon }
                    .buttonStyle(.glassProminent)
            } else if #available(macOS 26, *) {
                Button(action: action) { icon }
                    .buttonStyle(.glass)
            } else {
                Button(action: action) {
                    icon
                        .foregroundStyle(tinted ? Color.white : Color.primary)
                        .frame(width: size, height: size)
                        .glassCircle(tinted: tinted)
                }
                .buttonStyle(.plain)
            }
        }
        .help(help ?? "")
    }

    private var icon: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 11 / 24, weight: .semibold))
            .frame(width: size, height: size)
    }
}
