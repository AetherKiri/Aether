import UIKit

@MainActor
final class MobileOrientationPolicy {
    typealias GeometryRequest = @MainActor (UIWindowScene, UIInterfaceOrientationMask, @escaping (Error) -> Void) -> Void
    static let shared = MobileOrientationPolicy()
    private weak var scene: UIWindowScene?
    private var token: UUID?
    private var requestID = UUID()
    private var requestedLandscape = false
    private var mask: UIInterfaceOrientationMask = .all
    private var previous: UIInterfaceOrientation = .unknown
    private var disconnect: NSObjectProtocol?
    private let request: GeometryRequest
    init(request: GeometryRequest? = nil) {
        self.request=request ?? {scene,mask,failure in
            scene.requestGeometryUpdate(.iOS(interfaceOrientations:mask),errorHandler:failure)
        }
    }
    static func shellMask(_ scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        scene?.traitCollection.userInterfaceIdiom == .phone ? .allButUpsideDown : .all
    }
    func supportedMask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let candidate=window?.windowScene, candidate === scene, token != nil else {return Self.shellMask(window?.windowScene)}
        return mask
    }
    /// Only one game owns orientation. A duplicate view callback cannot replace it.
    func begin(scene: UIWindowScene, locked: Bool, failure: @escaping () -> Void) -> UUID? {
        guard token == nil else {return nil}
        let id=UUID(); self.scene=scene; token=id; previous=scene.interfaceOrientation
        mask=Self.shellMask(scene); requestedLandscape=false
        disconnect=NotificationCenter.default.addObserver(forName:UIScene.didDisconnectNotification,object:scene,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.end(id) }
        }
        if locked {retry(id,failure:failure)}
        return id
    }
    func retry(_ id: UUID, failure: @escaping () -> Void) {
        guard token == id, let scene else {return}
        let attempt=UUID(); requestID=attempt; requestedLandscape=true
        mask = .landscape; invalidate(scene)
        request(scene,.landscape) { [weak self, weak scene] error in
            Task { @MainActor in
                guard let self, let scene, self.token == id, self.requestID == attempt, self.scene === scene else {return}
                NSLog("IOS orientation denial %@",error.localizedDescription)
                self.requestedLandscape=false; self.mask=Self.shellMask(scene); self.invalidate(scene); failure()
            }
        }
    }
    func end(_ id: UUID) {
        guard token == id else {return}
        let scene=self.scene
        let restore=Self.orientationMask(previous).intersection(Self.shellMask(scene))
        let mustRestore=requestedLandscape || scene?.interfaceOrientation != previous
        token=nil; requestID=UUID(); requestedLandscape=false; self.scene=nil; mask=Self.shellMask(scene)
        if let disconnect {NotificationCenter.default.removeObserver(disconnect)}
        disconnect=nil
        guard let scene else {return}
        invalidate(scene)
        // Restore the shell's original direction if the game changed it; keep
        // its broader policy, so subsequent device rotations remain supported.
        guard scene.activationState != .unattached, !restore.isEmpty,
              mustRestore else {return}
        request(scene,restore) { _ in
            // Returning must remain possible even if the system denies rotation.
            // The shell mask is already restored and no game policy is retained.
        }
    }
    private static func orientationMask(_ orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return []
        }
    }
    private func invalidate(_ scene: UIWindowScene) {
        func update(_ controller: UIViewController) {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller.children.forEach(update)
            if let presented=controller.presentedViewController {update(presented)}
        }
        for window in scene.windows {if let root=window.rootViewController {update(root)}}
    }
}

@MainActor
final class MobileOrientationOwner {
    private let policy: MobileOrientationPolicy
    private var token: UUID?
    private let locked: Bool
    var failure: (() -> Void)?
    init(locked: Bool, policy: MobileOrientationPolicy? = nil) {self.locked=locked; self.policy=policy ?? .shared}
    func begin(scene: UIWindowScene) {
        guard token == nil else {return}
        token=policy.begin(scene:scene,locked:locked) { [weak self] in self?.failure?() }
    }
    func retry() {
        guard locked, let token else {return}
        policy.retry(token) { [weak self] in self?.failure?() }
    }
    func end() {if let token {policy.end(token)}; token=nil}
}

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MobileOrientationPolicy.shared.supportedMask(for:window)
    }
}
