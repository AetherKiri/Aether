import Foundation

@main
struct PlatformBrowserTests {
    static func main() {
        let https = PlatformBrowserRequest(argument: "  https://example.com/path?q=1  ")
        precondition(https?.url.absoluteString == "https://example.com/path?q=1")
        let http = PlatformBrowserRequest(argument: "http://localhost:8080/")
        precondition(http?.url.scheme == "http")
        for value in ["", "  ", "file:///tmp/a", "javascript:alert(1)", "/tmp/a", "https://"] {
            precondition(PlatformBrowserRequest(argument: value) == nil, "accepted \(value)")
        }
        print("PASS: browser URL validation")
    }
}
