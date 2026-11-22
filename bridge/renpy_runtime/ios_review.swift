import StoreKit
import UIKit

@_cdecl("AetherRenpyRequestReview")
func requestRenpyReview() {
    DispatchQueue.main.async {
        let activeScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let keyScenes = activeScenes.filter { $0.windows.contains(where: \.isKeyWindow) }
        if keyScenes.count == 1, let scene = keyScenes.first {
            AppStore.requestReview(in: scene)
        } else if activeScenes.count == 1, let scene = activeScenes.first {
            AppStore.requestReview(in: scene)
        }
    }
}
