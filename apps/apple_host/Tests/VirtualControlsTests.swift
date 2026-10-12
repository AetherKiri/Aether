import CoreGraphics
import Foundation

/// Virtual controls preferences and presentation (`game_virtual_controls.gd`).
enum VirtualControlsTests {
    static func run() {
        opacityNormalization()
        modeNormalization()
        presentationVisibility()
        pointerClamping()
        print("PASS: virtual control opacity snap, mode values, Godot panel/entry visibility matrix and virtual pointer clamping")
    }

    private static func opacityNormalization() {
        precondition(VirtualControlOpacity.minimum == 0.2 && VirtualControlOpacity.maximum == 1.0)
        precondition(VirtualControlOpacity.step == 0.05)
        precondition(VirtualControlOpacity.normalized(0) == 0.2)
        precondition(VirtualControlOpacity.normalized(0.19) == 0.2)
        precondition(VirtualControlOpacity.normalized(1.5) == 1.0)
        precondition(VirtualControlOpacity.normalized(0.62) == 0.6)
        precondition(VirtualControlOpacity.normalized(0.63) == 0.65)
        precondition(abs(VirtualControlOpacity.normalized(0.83) - 0.85) < 0.0001)
        precondition(VirtualControlOpacity.normalized(.nan) == 1.0)
        precondition(VirtualControlOpacity.percent(0.62) == 60)
        precondition(VirtualControlOpacity.percent(0.63) == 65)
        precondition(VirtualControlOpacity.percent(2.0) == 100)
    }

    private static func modeNormalization() {
        precondition(VirtualControlMode.allCases.map(\.rawValue) == ["mouse", "touch"])
        precondition(VirtualControlMode.normalized("mouse") == .mouse)
        precondition(VirtualControlMode.normalized("touch") == .touch)
        precondition(VirtualControlMode.normalized("pad") == nil)
        precondition(VirtualControlMode.mouse.textKey == "virtualMode_mouse")
        precondition(VirtualControlMode.touch.helpKey == "virtualMode_touch_help")
    }

    private static func presentationVisibility() {
        // Master switch off: nothing shows even if the menu entry is allowed.
        var off = VirtualControlsPresentation(enabled: false, entryAllowed: true, panelOpen: true,
                                              mode: .mouse, opacity: 1)
        precondition(!off.showsEntry && !off.showsPanel && !off.showsPointerHandle)
        // Menu entry off: Godot hides the whole overlay (`controls_visible`).
        var hidden = VirtualControlsPresentation(enabled: true, entryAllowed: false, panelOpen: false,
                                                 mode: .mouse, opacity: 1)
        precondition(!hidden.showsEntry && !hidden.showsPanel)
        hidden.togglePanel()
        precondition(!hidden.panelOpen, "the canvas entry cannot open when disabled")
        hidden.panelOpen = true // explicit toolbar action remains available
        precondition(hidden.showsPanel && !hidden.showsEntry)
        // Entry on, pad closed: only the entry button is visible.
        var pad = VirtualControlsPresentation(enabled: true, entryAllowed: true, panelOpen: false,
                                             mode: .mouse, opacity: 0.5)
        precondition(pad.showsEntry && !pad.showsPanel && !pad.showsPointerHandle)
        pad.togglePanel()
        precondition(pad.showsPanel && pad.showsPointerHandle, "mouse mode shows the pointer handle")
        precondition(pad.keyOpacity == 0.5)
        pad.mode = .touch
        precondition(pad.showsPanel && !pad.showsPointerHandle, "touch mode hides the pointer handle")
        pad.closePanel()
        precondition(pad.panelOpen == false && pad.showsEntry)
    }

    private static func pointerClamping() {
        var pointer = VirtualPointer()
        pointer.resetToCenter(of: CGSize(width: 640, height: 480))
        precondition(pointer.position == CGPoint(x: 319.5, y: 239.5))
        // Deltas accumulate into absolute canvas coordinates.
        precondition(pointer.move(dx: 10, dy: -20, frame: CGSize(width: 640, height: 480)) == CGPoint(x: 329.5, y: 219.5))
        // Clamped into the canvas on both axes.
        precondition(pointer.move(dx: 10_000, dy: 10_000, frame: CGSize(width: 640, height: 480)) == CGPoint(x: 639, y: 479))
        precondition(pointer.move(dx: -10_000, dy: -10_000, frame: CGSize(width: 640, height: 480)) == CGPoint(x: 0, y: 0))
        // A frame that is not known yet keeps the pointer at the origin.
        var unknown = VirtualPointer()
        unknown.resetToCenter(of: .zero)
        precondition(unknown.position == .zero)
        precondition(unknown.move(dx: 5, dy: 5, frame: .zero) == .zero)
    }
}
