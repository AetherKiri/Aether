import Foundation
@main struct PlatformDialogTests {
 @MainActor static func main() throws {
  let parsed = PlatformDialog(argument: "title=%E4%BD%A0%E5%A5%BD+%2B&message=a%26b%3Dc&text_field=1&maximum_characters=3&buttons=7%3A%E7%A1%AE%E8%AE%A4%7C-2%3A%E5%8F%96%E6%B6%88%7Cbad%7C7%3Aduplicate")
  precondition(parsed.title == "你好 +" && parsed.message == "a&b=c")
  precondition(parsed.choices.map(\.id) == [7,-2])
  precondition(parsed.response(result: 7, text: "你😀+&") == "result=7&text=%E4%BD%A0%F0%9F%98%80%2B")
  precondition(PlatformDialog(argument:"message=%ZZ&maximum_characters=-1").message == "%ZZ")
  precondition(PlatformDialog(argument:"text_field=0").response(result:0,text:"secret") == "result=0&text=")
  let controller = PlatformDialogController()
  var responses:[String] = []; var pending:[Bool] = []
  controller.submit = { responses.append($0) }; controller.pendingChanged = { pending.append($0) }
  controller.setPresentationAllowed(false)
  controller.enqueue("title=first&yes_no=1"); controller.enqueue("title=second&text_field=1")
  precondition(controller.active == nil && controller.hasPending)
  controller.setPresentationAllowed(true)
  let first = controller.active!
  precondition(first.title == "first")
  controller.complete(id: UUID(), result:1,text:"")
  precondition(responses.isEmpty)
  controller.complete(id: first.id,result:0,text:"")
  controller.complete(id: first.id,result:1,text:"")
  precondition(responses == ["result=0&text="] && controller.active == nil && controller.hasPending)
  controller.sheetDismissed()
  let second = controller.active!
  precondition(second.title == "second")
  controller.setPresentationAllowed(false); controller.setPresentationAllowed(true)
  precondition(controller.active!.id == second.id)
  controller.submit = { _ in throw CocoaError(.fileWriteUnknown) }
  controller.complete(id:second.id,result:1,text:"retry")
  precondition(controller.active?.id == second.id && controller.responseFailure != nil)
  controller.submit = { responses.append($0) }
  controller.complete(id:second.id,result:1,text:"a&b=+ 你好")
  precondition(responses.last == "result=1&text=a%26b%3D%2B%20%E4%BD%A0%E5%A5%BD")
  controller.sheetDismissed()
  precondition(!controller.hasPending && pending.last == false && controller.responseFailure == nil)
  controller.enqueue("title=old"); let stale = controller.active!.id
  controller.reset(); controller.enqueue("title=new")
  controller.complete(id:stale,result:1,text:"")
  precondition(responses.count == 2 && controller.active?.title == "new")
  controller.reset(); controller.sheetDismissed(); precondition(!controller.hasPending)
  print("PASS: form decoding, Unicode limit/escaping, choices, FIFO, modal deferral, duplicate/stale responses, failure retry, session reset")
 }
}
