import AppKit
import PeekCore
import SwiftUI

/// Text measurement backing the card flow's width math. NSAttributedString,
/// not SwiftUI, since the height estimate (PingRowMetrics) has to know a
/// pill's width before SwiftUI ever lays anything out.
@MainActor
enum TextMeasure {
    static func width(_ s: String, font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    static func height(_ s: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let bounds = attr.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return bounds.height.rounded(.up)
    }
}

/// Shared width/height math for the expanded card's answer flow: option
/// pills, Other, and (multiSelect) Send. `PingRowMetrics` calls this to
/// estimate the card's height before layout; `FlowLayout` below draws the
/// real thing. Same numbers, so the height AppKit sizes the window to and
/// what SwiftUI actually draws don't drift apart — see FlowMath.
@MainActor
enum CardFlowMetrics {
    static let font = NSFont.systemFont(ofSize: 13)
    static let itemHeight: CGFloat = 30
    static let spacing: CGFloat = 6
    static let lineSpacing: CGFloat = 6
    /// A committed "Other" answer can run to 200 characters (Question.
    /// typedAnswerCap); the pill itself stays readable and the flow sane by
    /// capping how much of that it'll ever reserve width for. The label
    /// still truncates to match, in CardPill.
    static let otherMaxLabelWidth: CGFloat = 140
    static let horizontalPadding: CGFloat = 24   // 12pt each side, pill content
    static let contentWidth = PingStackPanel.width - 24   // footer's own 12pt each side

    static func pillWidth(_ label: String, capLabelWidth: CGFloat? = nil) -> CGFloat {
        var w = TextMeasure.width(label, font: font)
        if let cap = capLabelWidth { w = min(w, cap) }
        return w + horizontalPadding
    }

    /// Widths in the exact order CardPillView draws them for one question:
    /// its options, then Other, then Send when it's multiSelect.
    static func widths(for question: Question, otherLabel: String) -> [CGFloat] {
        var widths = question.options.map { pillWidth($0.label) }
        widths.append(pillWidth(otherLabel, capLabelWidth: otherMaxLabelWidth))
        if question.multiSelect { widths.append(pillWidth("Send")) }
        return widths
    }

    static func flowHeight(for question: Question, otherLabel: String) -> CGFloat {
        FlowMath.layout(
            widths: widths(for: question, otherLabel: otherLabel),
            itemHeight: itemHeight, maxWidth: contentWidth,
            spacing: spacing, lineSpacing: lineSpacing
        ).height
    }
}

/// Lays out its subviews left to right, wrapping to a new line only when the
/// next one doesn't fit — the card's answer pills, packed instead of each
/// getting its own line. Sizing comes straight from FlowMath so this and
/// PingRowMetrics' height estimate can never disagree.
struct FlowLayout: Layout {
    // Layout's own conformance isn't MainActor-isolated, so these can't
    // default from CardFlowMetrics directly -- kept equal to it by hand;
    // every call site here uses the default anyway.
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let itemHeight = sizes.map(\.height).max() ?? 0
        let result = FlowMath.layout(
            widths: sizes.map(\.width), itemHeight: itemHeight,
            maxWidth: maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude,
            spacing: spacing, lineSpacing: lineSpacing
        )
        let width = maxWidth.isFinite ? maxWidth : (sizes.map(\.width).max() ?? 0)
        return CGSize(width: width, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let itemHeight = sizes.map(\.height).max() ?? 0
        let result = FlowMath.layout(
            widths: sizes.map(\.width), itemHeight: itemHeight, maxWidth: bounds.width,
            spacing: spacing, lineSpacing: lineSpacing
        )
        for (i, subview) in subviews.enumerated() {
            let position = result.positions[i]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading, proposal: ProposedViewSize(sizes[i])
            )
        }
    }
}

/// One flow item in the expanded card's answers: a neutral glass capsule
/// with primary-colored text when idle, or a flat green fill with white
/// text when picked/open/committed — same "plain fill skips glass's
/// vibrancy flattening" trick GlassButton uses (see GlassCompat), kept
/// separate from GlassButton so its width stays predictable: explicit
/// padding around a fixed-size font, not whatever `.glassEffect`/
/// `.buttonStyle(.glass)` decides to render, which is what let FlowMath's
/// pure math actually match the drawn pixels.
struct CardPill: View {
    let label: String
    let selected: Bool
    var maxLabelWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxLabelWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(GlassCompat.confirmTint) : AnyShapeStyle(.clear), in: Capsule())
        .glassCapsule()
    }
}

/// Multi-select's Send: the last item in a multiSelect question's flow
/// instead of its own row below every question — see docs/design.md.
struct SendPill: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Send")
                .font(.system(size: 13))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(GlassCompat.confirmTint, in: Capsule())
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}
