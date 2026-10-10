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

    init(argument: String) {
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

    func limitedText(_ text: String) -> String {
        // Match Godot's character limit (Unicode scalars), without cutting a surrogate pair.
        maximumCharacters > 0 ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(maximumCharacters))) : text
    }
    func response(result: Int32, text: String) -> String {
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
    var log: (String) -> Void = { _ in }
    var pendingChanged: (Bool) -> Void = { _ in }
    var hasPending: Bool { active != nil || !waiting.isEmpty || completing }

    func enqueue(_ argument: String) {
        // Requests have no correlation ID: preserve FIFO rather than replacing the active dialog.
        waiting.append(PlatformDialog(argument: argument))
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
        active = waiting.removeFirst()
    }
    func complete(id: UUID, result: Int32, text: String) {
        guard !completing, let dialog = active, dialog.id == id else { return }
        completing = true
        // Keep the current sheet identity while completing, then promote after its dismissal.
        do {
            try submit(dialog.response(result: result, text: text))
            responseFailure = nil
            log("platform dialog response sent (result=\(result))")
        } catch {
            responseFailure = error.localizedDescription
            log("platform dialog response failed: \(error.localizedDescription)")
            completing = false
            return
        }
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
        active = nil; waiting.removeAll(); completing = false; responseFailure = nil
        presentationAllowed = true
        pendingChanged(false)
    }
}
