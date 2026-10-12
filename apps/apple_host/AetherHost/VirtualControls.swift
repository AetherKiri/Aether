import CoreGraphics
import Foundation

/// Godot `game_virtual_controls.gd` input modes: a virtual mouse pad with a
/// cursor handle, or direct touch input.
enum VirtualControlMode: String, CaseIterable, Identifiable {
    case mouse, touch

    var id: String { rawValue }
    var textKey: String { "virtualMode_" + rawValue }
    var helpKey: String { "virtualMode_" + rawValue + "_help" }
    static func normalized(_ raw: String) -> VirtualControlMode? { VirtualControlMode(rawValue: raw) }
}

/// Godot `GAME_VIRTUAL_KEYBOARD_OPACITY_*`: 0.2…1.0 snapped to 0.05.
enum VirtualControlOpacity {
    static let minimum = 0.2
    static let maximum = 1.0
    static let step = 0.05

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return maximum }
        let clamped = min(maximum, max(minimum, value))
        // Snap to the step and re-round to a clean decimal so callers can
        // compare against literal percentages (0.6, 0.65, …).
        let steps = (clamped / step).rounded()
        return (steps * step * 1000).rounded() / 1000
    }

    static func percent(_ value: Double) -> Int {
        Int((normalized(value) * 100).rounded())
    }
}

/// Godot `_sync_visibility()` semantics: the overlay exists only when virtual
/// controls are enabled and the in-game menu entry is allowed; the pad itself
/// is shown once the user opened it. The key caps dim with the configured
/// opacity while the pointer handle stays fully opaque.
struct VirtualControlsPresentation: Equatable {
    var enabled: Bool
    var entryAllowed: Bool
    var panelOpen: Bool
    var mode: VirtualControlMode
    var opacity: Double

    var showsEntry: Bool { enabled && entryAllowed }
    var showsPanel: Bool { showsEntry && panelOpen }
    var showsPointerHandle: Bool { showsPanel && mode == .mouse }
    var keyOpacity: Double { VirtualControlOpacity.normalized(opacity) }

    mutating func togglePanel() {
        guard showsEntry else {
            panelOpen = false
            return
        }
        panelOpen.toggle()
    }

    mutating func closePanel() { panelOpen = false }
}

/// Virtual pointer position for the mouse-mode cursor handle. The engine takes
/// absolute surface coordinates, so the handle integrates drag deltas and
/// clamps them into the logical game canvas.
struct VirtualPointer: Equatable {
    private(set) var position: CGPoint = .zero

    mutating func reset(to point: CGPoint) { position = point }

    mutating func move(dx: Double, dy: Double, frame: CGSize) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        position.x = min(width - 1, max(0, position.x + dx))
        position.y = min(height - 1, max(0, position.y + dy))
        return position
    }

    mutating func resetToCenter(of frame: CGSize) {
        guard frame.width > 0, frame.height > 0 else { return }
        position = CGPoint(x: (frame.width - 1) / 2, y: (frame.height - 1) / 2)
    }
}
