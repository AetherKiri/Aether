import Foundation

struct PlatformBrowserRequest {
    let url: URL

    init?(argument: String) {
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let candidate = URL(string: value),
              let scheme = candidate.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              candidate.host != nil else { return nil }
        url = candidate
    }
}
