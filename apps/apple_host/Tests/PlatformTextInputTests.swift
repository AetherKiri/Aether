import Foundation

@main struct PlatformTextInputTests {
    @MainActor static func main() throws {
        let request = PlatformDialog(textInputArgument: "标题\t提示\t初始\t正文")
        precondition(request.title == "标题" && request.message == "提示" && request.initialText == "初始\t正文")
        precondition(request.operation == "text_input" && request.maximumCharacters == 0 && request.textField)
        precondition(request.response(result: 1, text: "你好😀&=+%\tvalue") == "result=ok\t你好😀&=+%\tvalue")
        precondition(request.response(result: 0, text: "secret") == "result=cancel")
        precondition(request.response(result: 1, text: "") == "result=ok\t")
        precondition(request.response(result: 1, text: "a\0b\nc\rd") == "result=ok\tabcd")
        precondition(PlatformDialog(textInputArgument: "\t\t").initialText.isEmpty)
        for argument in ["", "title\tmessage", "a\tb\tc\0"] {
            let invalid = PlatformDialog(textInputArgument: argument)
            precondition(invalid.automaticCancellation && invalid.response(result: 1, text: "secret") == "result=cancel")
        }
        let controller = PlatformDialogController()
        var replies: [(String, String)] = []
        var logs: [String] = []
        controller.submitRequest = { replies.append(($0, $1)) }
        controller.log = { logs.append($0) }
        controller.setPresentationAllowed(false)
        controller.enqueueTextInput("标题\t提示\t初始")
        controller.enqueue("title=dialog&yes_no=1")
        controller.enqueueTextInput("broken")
        controller.enqueueTextInput("最后\t取消\tsecret")
        precondition(controller.active == nil && controller.hasPending)
        controller.setPresentationAllowed(true)
        let first = controller.active!
        precondition(controller.draft(for: first) == "初始")
        controller.updateDraft(id: first.id, text: "用户正文😀")
        controller.setPresentationAllowed(false); controller.setPresentationAllowed(true)
        precondition(controller.active?.id == first.id && controller.draft(for: first) == "用户正文😀")
        controller.submitRequest = { _, _ in throw CocoaError(.fileWriteUnknown) }
        controller.complete(id: first.id, result: 1, text: "用户正文😀")
        precondition(controller.responseFailure != nil && controller.active?.id == first.id)
        controller.submitRequest = { replies.append(($0, $1)) }
        controller.complete(id: first.id, result: 1, text: "用户正文😀")
        controller.complete(id: first.id, result: 1, text: "duplicate")
        precondition(replies.count == 1 && controller.hasPending)
        controller.sheetDismissed()
        let dialog = controller.active!
        precondition(dialog.operation == "dialog" && controller.responseFailure == nil)
        controller.complete(id: dialog.id, result: 1, text: "")
        controller.sheetDismissed()
        precondition(replies.count == 3 && replies[2].0 == "text_input" && replies[2].1 == "result=cancel")
        let last = controller.active!
        controller.complete(id: last.id, result: 0, text: "secret")
        controller.sheetDismissed()
        precondition(replies.map { $0.0 } == ["text_input", "dialog", "text_input", "text_input"])
        precondition(replies.map { $0.1 } == ["result=ok\t用户正文😀", "result=1&text=", "result=cancel", "result=cancel"])
        precondition(!controller.hasPending && !logs.joined().contains("用户正文"))
        // Failed automatic cancellation stays pending and can be retried from a sheet.
        controller.submitRequest = { _, _ in throw CocoaError(.fileWriteUnknown) }
        controller.enqueueTextInput("broken")
        let malformed = controller.active!
        var cancellationRetries = 0
        controller.submitRequest = { _, _ in cancellationRetries += 1; throw CocoaError(.fileWriteUnknown) }
        controller.setPresentationAllowed(false); controller.setPresentationAllowed(true)
        precondition(cancellationRetries == 0 && controller.responseFailure != nil)
        precondition(malformed.automaticCancellation && controller.responseFailure != nil)
        controller.submitRequest = { replies.append(($0, $1)) }
        controller.complete(id: malformed.id, result: 0, text: "")
        controller.sheetDismissed()
        precondition(!controller.hasPending && replies.last!.1 == "result=cancel")
        controller.enqueueTextInput("old\tmessage\tdraft")
        let stale = controller.active!.id
        controller.updateDraft(id: stale, text: "private")
        controller.reset(); controller.enqueueTextInput("new\tmessage\tnew value")
        let count = replies.count
        controller.complete(id: stale, result: 1, text: "private")
        precondition(replies.count == count && controller.draft(for: controller.active!) == "new value")
        controller.reset()
        print("PASS: TAB protocol, initial/empty/Unicode text, cancel privacy, mixed FIFO, draft deferral, retry, malformed cancellation, duplicate/stale cleanup")
    }
}
