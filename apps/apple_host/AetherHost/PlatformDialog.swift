import Foundation
import Combine

struct PlatformDialog: Identifiable {
    struct Choice: Identifiable, Equatable { let id: Int32; let label: String }
    let id = UUID()
    let title: String
    let message: String
    let textField: Bool
    let maximumCharacters: Int
    let choices: [Choice]
    let yesNo: Bool
    let operation: String
    let initialText: String
    let automaticCancellation: Bool

    init(argument: String) {
        operation = "dialog"; initialText = ""; automaticCancellation = false
        var values: [String: String] = [:]
        for field in argument.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ value: Substring) -> String {
                let spaced = value.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            values[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
        title = values["title"] ?? ""
        message = values["message"] ?? ""
        textField = values["text_field"] == "1"
        maximumCharacters = max(0, Int(values["maximum_characters"] ?? "0") ?? 0)
        yesNo = values["yes_no"] == "1"
        var parsed: [Choice] = []
        for item in (values["buttons"] ?? "").split(separator: "|") {
            let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let id = Int32(parts[0]), !parsed.contains(where: { $0.id == id }) else { continue }
            parsed.append(Choice(id: id, label: String(parts[1])))
        }
        choices = parsed
    }

    init(textInputArgument: String) {
        // Godot splits at most twice: tabs in the initial value are preserved.
        let fields = textInputArgument.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        operation = "text_input"
        automaticCancellation = fields.count != 3 || textInputArgument.contains("\0")
        title = fields.count == 3 ? String(fields[0]) : ""
        message = fields.count == 3 ? String(fields[1]) : ""
        initialText = fields.count == 3 ? String(fields[2]) : ""
        textField = !automaticCancellation
        maximumCharacters = 0; choices = []; yesNo = false
    }

    func limitedText(_ text: String) -> String {
        // Match Godot's character limit (Unicode scalars), without cutting a surrogate pair.
        maximumCharacters > 0 ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(maximumCharacters))) : text
    }
    func response(result: Int32, text: String) -> String {
        if operation == "text_input" {
            guard !automaticCancellation, result != 0 else { return "result=cancel" }
            // LineEdit is single-line. NUL cannot cross the C-string ABI.
            let value = text.unicodeScalars.filter { ![0, 10, 13].contains($0.value) }
            return "result=ok\t" + String(String.UnicodeScalarView(value))
        }
        let value = textField ? limitedText(text) : ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return "result=\(result)&text=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }
}

@MainActor
final class PlatformDialogController: ObservableObject {
    @Published private(set) var active: PlatformDialog?
    @Published private(set) var responseFailure: String?
    private var waiting: [PlatformDialog] = []
    private var presentationAllowed = true
    private var completing = false
    var submit: (String) throws -> Void = { _ in }
    var submitRequest: ((String, String) throws -> Void)?
    private var drafts: [UUID: String] = [:]
    private var responseErrors: [UUID: String] = [:]
    var log: (String) -> Void = { _ in }
    var pendingChanged: (Bool) -> Void = { _ in }
    var hasPending: Bool { active != nil || !waiting.isEmpty || completing }

    func enqueue(_ argument: String) { enqueue(PlatformDialog(argument: argument)) }
    func enqueueTextInput(_ argument: String) { enqueue(PlatformDialog(textInputArgument: argument)) }
    func draft(for dialog: PlatformDialog) -> String { drafts[dialog.id] ?? dialog.initialText }
    func updateDraft(id: UUID, text: String) {
        guard active?.id == id else { return }
        drafts[id] = text
    }
    private func respond(_ dialog: PlatformDialog, result: Int32, text: String) throws {
        let response = dialog.response(result: result, text: text)
        if let submitRequest { try submitRequest(dialog.operation, response) }
        else { try submit(response) }
    }
    private func enqueue(_ dialog: PlatformDialog) {
        // Requests have no correlation ID: preserve FIFO rather than replacing the active dialog.
        waiting.append(dialog)
        log("platform dialog queued (pending=\(waiting.count + (active == nil ? 0 : 1)))")
        promote()
        pendingChanged(hasPending)
    }
    func setPresentationAllowed(_ allowed: Bool) {
        presentationAllowed = allowed
        if !allowed, let dialog = active { waiting.insert(dialog, at: 0); active = nil }
        promote()
    }
    private func promote() {
        guard presentationAllowed, !completing, active == nil, !waiting.isEmpty else { return }
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            responseFailure = responseErrors[next.id]
            if next.automaticCancellation, responseFailure == nil {
                do {
                    try respond(next, result: 0, text: "")
                    log("malformed text_input cancelled")
                    continue
                } catch {
                    responseFailure = error.localizedDescription
                    responseErrors[next.id] = error.localizedDescription
                    log("text_input cancellation failed: \(error.localizedDescription)")
                }
            }
            active = next
            return
        }
    }
    func complete(id: UUID, result: Int32, text: String) {
        guard !completing, let dialog = active, dialog.id == id else { return }
        completing = true
        // Keep the current sheet identity while completing, then promote after its dismissal.
        do {
            try respond(dialog, result: result, text: text)
            responseFailure = nil
            log("platform dialog response sent (result=\(result))")
        } catch {
            responseFailure = error.localizedDescription
            responseErrors[dialog.id] = error.localizedDescription
            log("platform dialog response failed: \(error.localizedDescription)")
            completing = false
            return
        }
        drafts.removeValue(forKey: dialog.id)
        responseErrors.removeValue(forKey: dialog.id)
        active = nil
        pendingChanged(hasPending)
    }
    func sheetDismissed() {
        guard completing else { return }
        completing = false
        promote()
        pendingChanged(hasPending)
    }
    func reset() {
        active = nil; waiting.removeAll(); drafts.removeAll(); responseErrors.removeAll(); completing = false; responseFailure = nil
        presentationAllowed = true
        pendingChanged(false)
    }
}
