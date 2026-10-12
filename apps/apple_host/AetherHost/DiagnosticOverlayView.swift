import SwiftUI

/// Live performance overlay drawn over the running game.
///
/// The text stays English technical output like the Godot shell's debug
/// overlay, refreshes twice a second, and never takes pointer/key input.
struct DiagnosticOverlayView: View {
    @ObservedObject var engine: EngineController

    var body: some View {
        let lines = self.lines
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: 720, alignment: .leading)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
        .allowsHitTesting(false)
    }

    /// The snapshot is throttled by the tick loop; the mode comes from the live
    /// setting so toggling it takes effect on the next redraw.
    private var lines: [String] {
        var snapshot = engine.overlaySnapshot
        snapshot.mode = engine.debugOverlayMode
        return DiagnosticOverlay.lines(snapshot)
    }
}
