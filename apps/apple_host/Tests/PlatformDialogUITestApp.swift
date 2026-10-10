// Standalone UI fixture: uses the production dialog parser, queue and SwiftUI views.
// Responses are acknowledged by this test harness; no private runtime is simulated as real.
import SwiftUI
import Foundation

@main struct PlatformDialogUITestApp: App {
    @StateObject private var dialogs = PlatformDialogController()
    @State private var started = false
    var body: some Scene {
        WindowGroup("Apple Platform Dialog Test") {
            Text("Platform dialog UI fixture\nResponses use a test acknowledgment callback.")
                .padding(30).frame(width: 640, height: 360)
                .modifier(PlatformDialogPresentation(dialogs: dialogs, language: .simplified))
                .onAppear {
                    guard !started else { return }; started = true
                    var failOnce = true
                    dialogs.submit = { response in
                        if failOnce { failOnce = false; throw NSError(domain: "TestHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "TEST response failure — retry"]) }
                        FileHandle.standardOutput.write(Data(("ACK " + response + "\n").utf8))
                    }
                    dialogs.log = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
                    dialogs.enqueue("title=%E8%BE%93%E5%85%A5%E6%B5%8B%E8%AF%95&message=Unicode+%26+form+escaping&text_field=1&maximum_characters=4&buttons=7%3A%E6%8F%90%E4%BA%A4%7C8%3A%E8%B7%B3%E8%BF%87")
                    dialogs.enqueue("title=%E9%80%89%E6%8B%A9%E6%B5%8B%E8%AF%95&message=Choose+No&yes_no=1")
                    dialogs.enqueue("title=%E5%AE%8C%E6%88%90&message=FIFO+complete")
                }
        }
    }
}
