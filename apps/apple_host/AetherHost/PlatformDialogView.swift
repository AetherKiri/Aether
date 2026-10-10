import SwiftUI

struct PlatformDialogView: View {
    let dialog: PlatformDialog
    let language: ShellLanguage
    let complete: (Int32, String) -> Void
    var responseFailure: String? = nil
    var initialText: String? = nil
    var didEdit: (String) -> Void = { _ in }
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(dialog.automaticCancellation ? language.text("invalidTextRequest") : dialog.title).font(.title2.bold())
            ScrollView { Text(dialog.message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 240)
            if dialog.textField {
                TextField(language.text("enterText"), text: $text).textFieldStyle(.roundedBorder).focused($focused)
                    .onChange(of: text) { value in text = dialog.limitedText(value); didEdit(text) }
                    .onSubmit { complete(dialog.choices.first?.id ?? 1, text) }
            }
            if let responseFailure { Text(responseFailure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if dialog.choices.isEmpty {
                    Button(language.text("cancel")) { complete(0, text) }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                if !dialog.choices.isEmpty {
                    ForEach(dialog.choices) { choice in
                        if choice.id == 0 {
                            Button(choice.label) { complete(choice.id, text) }.keyboardShortcut(.cancelAction)
                        } else {
                            Button(choice.label) { complete(choice.id, text) }
                        }
                    }
                } else {
                    if dialog.yesNo { Button(language.text("dialogNo")) { complete(0, text) } }
                    Button(language.text(dialog.yesNo ? "dialogYes" : "ok")) { complete(1, text) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 500).fixedSize(horizontal: false, vertical: true)
            .onAppear { text = initialText ?? dialog.initialText; focused = dialog.textField }
            .interactiveDismissDisabled()
    }
}

struct PlatformDialogPresentation: ViewModifier {
    @ObservedObject var dialogs: PlatformDialogController
    let language: ShellLanguage
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { dialogs.active }, set: { _ in }), onDismiss: { dialogs.sheetDismissed() }) { dialog in
            PlatformDialogView(dialog: dialog, language: language, complete: { result, text in
                dialogs.complete(id: dialog.id, result: result, text: text)
            }, responseFailure: dialogs.responseFailure, initialText: dialogs.draft(for: dialog), didEdit: { text in
                dialogs.updateDraft(id: dialog.id, text: text)
            })
        }
    }
}
