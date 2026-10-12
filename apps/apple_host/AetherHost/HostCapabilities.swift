import Foundation

struct HostCapabilities {
    struct Availability {
        let reasonKey: String?
        let detail: String
        var available: Bool { reasonKey == nil }
        static let ready = Availability(reasonKey: nil, detail: "")
    }
    /// Device and host presenter checked before any game is opened. Runtime
    /// acceptance of the native backend is still checked at engine launch.
    let nativeMetal: Availability
    let translation: Availability
    let enhancement = Availability(reasonKey: "enhancementPending", detail: "")
}

enum HostRenderer: String { case metal, software }
enum HostPresentation: String { case metal, image }

struct RenderSessionState: Equatable {
    struct Fallback: Equatable {
        let reasonKey: String
        let detail: String
    }
    var requested: HostRenderer = .metal
    var effective: HostRenderer?
    var presentation: HostPresentation?
    var fallbacks: [Fallback] = []
    var active = false
    var diagnostics: [String: String] {
        ["rendererRequested": requested.rawValue, "renderer": effective?.rawValue ?? "uninitialized",
         "presentation": presentation?.rawValue ?? "uninitialized",
         "renderFallback": fallbacks.map { $0.reasonKey + ": " + $0.detail }.joined(separator: "\n")]
    }
}
