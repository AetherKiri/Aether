import Foundation

/// Godot's Debug-only scene preview (`settings.scene_test`). The target is
/// persisted under Godot's key and applied on the next launch, matching the
/// Godot shell's "restart into the scene" behaviour. Only scenes the host can
/// honestly render are listed; Godot's separate default/loading/started state
/// picker is not mirrored because the loading state is transient here.
enum SceneTestScene: String, CaseIterable, Identifiable {
    case home, settings, detail, video, videoPlayer, game
    var id: String { rawValue }
    var textKey: String { "sceneTest_" + rawValue }
}

/// Persists the requested scene under Godot's `aether_kiri/scene_test` key.
struct SceneTestStore {
    static let key = "aether_kiri/scene_test"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SceneTestScene? {
        guard let raw = defaults.string(forKey: Self.key) else { return nil }
        return SceneTestScene(rawValue: raw)
    }

    func save(_ scene: SceneTestScene) { defaults.set(scene.rawValue, forKey: Self.key) }
    func clear() { defaults.removeObject(forKey: Self.key) }
}
