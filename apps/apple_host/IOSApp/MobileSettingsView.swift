import SwiftUI

struct MobileSettingsView: View {
    @ObservedObject var preferences: MobilePreferencesState
    let language: ShellLanguage
    @Environment(\.shellPalette) private var palette
    var body: some View {
        Form {
            Section(language.text("interfaceSection")) {
                Picker(language.text("language"),selection:$preferences.draft.host.languageMode) {
                    Text(language.text("followSystem")).tag("system")
                    ForEach(ShellLanguage.allCases) {Text($0.name).tag($0.rawValue)}
                }
                Picker(language.text("theme"),selection:$preferences.draft.host.theme) {
                    ForEach(ShellTheme.allCases) {Text(language.text($0.textKey)).tag($0.rawValue)}
                }
                Picker(language.text("mobileInterfaceScale"),selection:$preferences.draft.interfaceScale) {
                    ForEach(["compact","comfortable","standard"],id:\.self) {Text(language.text("mobileScale_"+$0)).tag($0)}
                }
                Toggle(language.text("mobileLandscape"),isOn:$preferences.draft.landscapeLocked).accessibilityIdentifier("mobile.settings.landscape")
                Text(language.text("mobileLandscapeHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                Text(language.text("mobileScaleHelp")).font(.caption).foregroundStyle(palette.secondary.color)
            }.listRowBackground(palette.surface.color)
            Section(language.text("renderer")) {
                Picker(language.text("renderer"),selection:$preferences.draft.host.renderer) {
                    Text("Metal").tag("metal")
                    Text(language.text("software")).tag("software")
                }
                Text(language.text("mobileSettingsNextGame")).font(.caption).foregroundStyle(palette.secondary.color)
                LabeledContent(language.text("outputResolution"),value:language.text("output_"+preferences.draft.host.outputResolution))
                LabeledContent(language.text("samplingAlgorithm"),value:language.text("sampling_"+preferences.draft.host.upscaleAlgorithm))
                LabeledContent(language.text("frameEnhancement"),value:language.text("enhancementKind_"+preferences.draft.host.frameEnhancementKind))
                Text(language.text("mobileRenderPending")).font(.caption).foregroundStyle(palette.secondary.color)
            }.listRowBackground(palette.surface.color)
            Section(language.text("pluginLoadMode")) {
                Picker(language.text("pluginLoadMode"),selection:$preferences.draft.host.pluginLoadMode) {
                    Text(language.text("corePlugins")).tag("krkrsdl3"); Text(language.text("allPlugins")).tag("aether_all")
                }
                Toggle(language.text("mockEnabled"),isOn:$preferences.draft.host.mockEnabled)
                Toggle(language.text("errorDialogLogs"),isOn:$preferences.draft.host.errorDialogLogs)
            }.listRowBackground(palette.surface.color)
            Section {
                Text(language.text("mobileSettingsRemaining")).font(.callout).foregroundStyle(palette.secondary.color)
            }.listRowBackground(palette.surface.color)
        }.disabled(!preferences.writable)
        .scrollContentBackground(.hidden).background(palette.background.color)
        .navigationTitle(language.text("settings"))
        .toolbar {
            ToolbarItem(placement:.cancellationAction) {Button(language.text("discardLeave")) {preferences.discard()}.disabled(!preferences.isDirty)}
            ToolbarItem(placement:.confirmationAction) {Button(language.text("saveSettings")) {preferences.save()}.disabled(!preferences.isDirty || !preferences.writable)}
        }
    }
}
