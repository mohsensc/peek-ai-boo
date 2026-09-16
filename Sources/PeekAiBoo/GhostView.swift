import PeekCore
import SwiftUI

/// Colored placeholder shapes standing in for the pixel-ghost sprites.
/// feat/ghosts swaps this body for real art; the signature stays so nothing
/// else in the app has to change.
struct GhostView: View {
    let client: Client
    let pose: GhostPose
    let phase: Double?

    private var color: Color {
        switch client {
        case .claude: return Color(red: 1.0, green: 0.478, blue: 0.4)    // #FF7A66
        case .codex: return Color(red: 0.373, green: 0.878, blue: 0.690)  // #5FE0B0
        }
    }

    var body: some View {
        let t = phase ?? 0
        let moving = phase != nil
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 16, height: 16)
            .opacity(pose == .done ? 0.4 : 1.0)
            .scaleEffect(pose == .working && moving ? 1 + 0.08 * sin(t * 6) : 1)
            .rotationEffect(.degrees(pose == .needs && moving ? 6 * sin(t * 10) : 0))
            .offset(y: pose == .idle && moving ? CGFloat(sin(t * 2)) : 0)
            .overlay(alignment: .topTrailing) {
                if pose == .needs {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
    }
}
