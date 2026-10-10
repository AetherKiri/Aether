// Uses production views and queue with explicitly synthetic acknowledgments.
import SwiftUI

@main struct PlatformTextInputUITestApp: App {
    @StateObject private var dialogs = PlatformDialogController()
    @State private var started = false
    var body: some Scene {
        WindowGroup("Apple Text Input Test") {
            Text("Generic text_input UI fixture\nTest ACK callback; no real runtime provider.")
                .padding(30).frame(width: 640, height: 360)
                .modifier(PlatformDialogPresentation(dialogs: dialogs, language: .simplified))
                .onAppear {
                    guard !started else { return }; started = true
                    var failOnce = true
                    dialogs.submitRequest = { operation, response in
                        if failOnce { failOnce = false; throw NSError(domain: "TestHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "TEST response failure — retry"]) }
                        let data = try JSONSerialization.data(withJSONObject: ["operation": operation, "response": response], options: [.sortedKeys])
                        FileHandle.standardOutput.write(data + Data("\n".utf8))
                    }
                    dialogs.enqueueTextInput("文字输入测试\t验证初始值、中文与失败重试\t初始文字")
                    dialogs.enqueue("title=dialog+FIFO&message=Confirm+to+continue")
                    dialogs.enqueueTextInput("取消测试\t取消不发送正文\tprivate fixture")
                    dialogs.enqueueTextInput("malformed")
                }
        }
    }
}
