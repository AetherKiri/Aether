import Foundation
import Combine

/// Mobile-only envelope keeps every shared preference, including unsupported
/// output/algorithm choices, without changing the desktop settings schema.
struct MobilePreferences: Codable, Equatable {
    var version = 1
    var host = MobilePreferences.defaultHost
    var interfaceScale = "comfortable"
    static var defaultHost: HostSettings {
        var settings = HostSettings()
        settings.outputResolution = "original"
        settings.frameEnhancementKind = "off"
        return settings
    }
    func validated() throws -> MobilePreferences {
        guard version == 1, ["compact", "comfortable", "standard"].contains(interfaceScale) else {throw HostSettings.Failure.invalidValue}
        var result=self; result.host=try host.validated(); return result
    }
    var verticalPadding: CGFloat {
        switch interfaceScale {case "compact": return 0; case "standard": return 8; default: return 4}
    }
}
struct MobilePreferencesStore {
    let url: URL
    func load() throws -> MobilePreferences {
        guard FileManager.default.fileExists(atPath:url.path) else {return MobilePreferences()}
        let data=try Data(contentsOf:url)
        let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        if object?["host"] != nil {
            var value=try JSONDecoder().decode(MobilePreferences.self,from:data)
            value.host=try value.host.normalizedForLoad()
            return try value.validated()
        }
        // A copied desktop/previous shared file keeps its exact output choices.
        var value=MobilePreferences()
        value.host=try JSONDecoder().decode(HostSettings.self,from:data).normalizedForLoad()
        return try value.validated()
    }
    func save(_ value: MobilePreferences) throws {
        let value=try value.validated()
        let data=try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }
}
@MainActor
final class MobilePreferencesState: ObservableObject {
    @Published private(set) var settings: MobilePreferences
    @Published var draft: MobilePreferences
    @Published var error: String?
    @Published private(set) var writable=true
    let store: MobilePreferencesStore
    init(root: URL) {
        store=MobilePreferencesStore(url:root.appendingPathComponent("settings.json"))
        do {let value=try store.load(); settings=value; draft=value}
        catch {let value=MobilePreferences(); settings=value; draft=value; writable=false; self.error=error.localizedDescription}
    }
    var isDirty: Bool {draft != settings}
    func discard() {draft=settings}
    @discardableResult func save() -> Bool {
        guard writable else {return false}
        do {let value=try draft.validated(); try store.save(value); settings=value; draft=value; return true}
        catch {self.error=error.localizedDescription; return false}
    }
    func quickLanguage(_ language: ShellLanguage) {
        guard writable else {return}
        var value=settings; value.host.languageMode=language.rawValue
        do {
            try store.save(value)
            settings=value; draft.host.languageMode=value.host.languageMode
        } catch {self.error=error.localizedDescription}
    }
}
