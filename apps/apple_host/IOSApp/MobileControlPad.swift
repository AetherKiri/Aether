import SwiftUI

private struct MobileCursorHandle: UIViewRepresentable {
    let game: MobileGameViewModel
    final class Coordinator {var drag: UUID?}
    func makeCoordinator() -> Coordinator {Coordinator()}
    func makeUIView(context:Context) -> AetherMobilePointerPad {AetherMobilePointerPad()}
    func updateUIView(_ view:AetherMobilePointerPad,context:Context) {
        let coordinator=context.coordinator
        view.began={coordinator.drag=game.beginCursorDrag()}
        view.moved={delta in if let id=coordinator.drag {game.moveCursor(delta,owner:id)}}
        view.ended={if let id=coordinator.drag {game.endCursorDrag(id)}; coordinator.drag=nil}
    }
}
struct MobileControlPad: View {
    @ObservedObject var game: MobileGameViewModel
    let language: ShellLanguage
    @ScaledMetric(relativeTo:.body) private var keyWidth=76.0
    private let keys: [(String,Int32)] = [("enterKey",0x0D),("spaceKey",0x20),("Esc",0x1B),("←",0x25),("↑",0x26),("↓",0x28),("→",0x27),("PgUp",0x21),("PgDn",0x22)]
    var body: some View {
        ScrollView {
            VStack(spacing:8) {
                HStack {
                    ForEach(VirtualControlMode.allCases) {mode in
                        Button(language.text(mode.textKey)) {game.setControlMode(mode)}
                            .frame(maxWidth:.infinity,minHeight:44)
                            .tint(game.controlMode == mode ? .orange : .gray)
                            .accessibilityAddTraits(game.controlMode == mode ? .isSelected : [])
                            .accessibilityIdentifier("mobile.controls.mode."+mode.rawValue)
                    }
                }
                if game.controlMode == .mouse {
                    HStack {
                        Text(language.text("mobilePointerPad")).frame(maxWidth:.infinity,minHeight:44)
                            .background(.white.opacity(0.12),in:RoundedRectangle(cornerRadius:8))
                            .overlay {MobileCursorHandle(game:game)}
                            .accessibilityLabel(language.text("mobilePointerPad"))
                            .accessibilityIdentifier("mobile.controls.pointerPad")
                            .accessibilityAction(named:Text(language.text("mobilePointerLeft"))) {game.nudgeCursor(CGSize(width:-16,height:0))}
                            .accessibilityAction(named:Text(language.text("mobilePointerRight"))) {game.nudgeCursor(CGSize(width:16,height:0))}
                            .accessibilityAction(named:Text(language.text("mobilePointerUp"))) {game.nudgeCursor(CGSize(width:0,height:-16))}
                            .accessibilityAction(named:Text(language.text("mobilePointerDown"))) {game.nudgeCursor(CGSize(width:0,height:16))}
                        Button(language.text("virtualClick")) {game.clickCursor()}.frame(minHeight:44)
                            .accessibilityIdentifier("mobile.controls.click")
                    }
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:keyWidth))],spacing:8) {
                    ForEach(keys,id:\.0) {label,key in
                        Button(language.text(label)) {game.tapKey(key)}.frame(maxWidth:.infinity,minHeight:44)
                            .opacity(game.controlOpacity).accessibilityIdentifier("mobile.controls.key."+String(key))
                    }
                    Button(language.text("holdControl")) {game.setControlHeld(!game.controlHeld)}
                        .frame(maxWidth:.infinity,minHeight:44).tint(game.controlHeld ? .orange : .gray)
                        .opacity(game.controlOpacity).accessibilityAddTraits(game.controlHeld ? .isSelected : [])
                        .accessibilityIdentifier("mobile.controls.ctrl")
                }
            }.padding(8).buttonStyle(.bordered)
        }.disabled(!game.controller.inputAvailable).accessibilityIdentifier("mobile.controls.pad")
    }
}
