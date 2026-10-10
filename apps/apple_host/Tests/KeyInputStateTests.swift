import Foundation
@main struct KeyInputStateTests {
 static func main() {
  var state = KeyInputState()
  precondition(state.set(.physical, key: 17, pressed: true).count == 1)
  precondition(state.set(.virtual, key: 17, pressed: true).isEmpty)
  precondition(state.set(.physical, key: 17, pressed: false).isEmpty)
  precondition(state.release(.virtual).map(\.pressed) == [false])
  precondition(state.releaseAll().isEmpty)
  precondition(state.set(.physical, key: 65, pressed: true).count == 1)
  precondition(state.set(.physical, key: 65, pressed: true).isEmpty)
  precondition(state.set(.physical, key: 65, pressed: true, modifiers: 0x80).count == 1)
  precondition(state.set(.virtual, key: 13, pressed: true).count == 1)
  precondition(state.releaseAll().map(\.key) == [13, 65])
  precondition(state.set(.physical, key: 65, pressed: false).isEmpty)
  precondition(GameTextInput.scalars("你\r\n好\0A😀e\u{301}") == [0x4F60,0x597D,65,0x1F600,101,0x301])
  precondition(GameTextInput.scalars(String(repeating: "你", count: 3000)).count == 2048)
  print("PASS: shared key ownership, repeats, focus release, Unicode filtering and bound")
 }
}
