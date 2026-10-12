import Foundation

/// Debug scene-test store: Godot's key, round-trip and clearing.
enum SceneTestTests {
    static func run() {
        let suite = "aether-scene-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SceneTestStore(defaults: defaults)
        precondition(store.load() == nil)
        for scene in SceneTestScene.allCases {
            store.save(scene)
            precondition(store.load() == scene)
            precondition(defaults.string(forKey: "aether_kiri/scene_test") == scene.rawValue,
                         "the Godot key must be used")
        }
        store.clear()
        precondition(store.load() == nil)
        // An unknown stored value is treated as no request.
        defaults.set("not-a-scene", forKey: "aether_kiri/scene_test")
        precondition(store.load() == nil)
        print("PASS: scene-test store round-trip, Godot key, clearing and unknown-value handling")
    }
}
