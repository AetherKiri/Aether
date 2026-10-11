import SwiftUI

struct ShellSettingsView: View {
    @Environment(\.shellPalette) private var palette
    @ObservedObject var model: ShellModel
    @State private var document: SettingsDocument?
    @State private var category = "interfaceSection"
    private let categories = ["interfaceSection", "renderSection", "compatibilitySection", "diagnosticsSection", "advancedSection", "aboutSection"]

    private func binding<Value>(_ key: WritableKeyPath<HostSettings, Value>) -> Binding<Value> {
        Binding(get: { (model.settingsDraft?.value ?? model.settings)[keyPath: key] }, set: { value in
            model.settingsDraft?.value[keyPath: key] = value
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(categories, id: \.self) { key in
                        Button { category = key } label: {
                            Text(model.text(key)).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.buttonStyle(.plain)
                            .background(category == key ? palette.accent.color.opacity(palette.dark ? 0.16 : 0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(width: 160).padding(.top, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(model.text(category)).font(.title2.bold())
                        categoryContent
                    }.frame(maxWidth: 720, alignment: .leading).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24)
            Divider()
            HStack {
                Text(model.text(!model.settingsAvailable ? "settingsLoadFailed" : model.settingsDirty ? "unsavedChanges" : "settingsSaved"))
                    .foregroundStyle(palette.secondary.color)
                Spacer()
                Button(model.text("saveSettings")) { _ = model.saveSettings() }
                    .lumenPrimaryAction().disabled(!model.canSaveSettings)
            }.padding(16)
        }
        .sheet(item: $document) { SettingsDocumentView(document: $0, language: model.language, close: { document = nil }) }
    }

    @ViewBuilder private var categoryContent: some View {
        switch category {
        case "interfaceSection":
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(model.text("language"), selection: binding(\.languageMode)) {
                        Text(model.text("followSystem")).tag("system")
                        ForEach(ShellLanguage.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Picker(model.text("theme"), selection: binding(\.theme)) {
                        ForEach(ShellTheme.allCases) { theme in
                            Text(model.text(theme.textKey)).tag(theme.rawValue)
                        }
                    }
                    Text(model.text("themeHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Toggle(model.text("virtualControls"), isOn: binding(\.virtualControls))
                    Text(model.text("virtualControlsHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
        case "renderSection":
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(model.text("renderer"), selection: binding(\.renderer)) {
                        Text(model.text("software")).tag("software")
                        Text(model.text("metal")).tag("metal")
                    }
                    Text(model.text("rendererHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Text(model.text("renderSettingsPending")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
        case "compatibilitySection":
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(model.text("pluginLoadMode"), selection: binding(\.pluginLoadMode)) {
                        Text(model.text("corePlugins")).tag("krkrsdl3")
                        Text(model.text("allPlugins")).tag("aether_all")
                    }
                    Text(model.text("pluginLoadHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Toggle(model.text("mockEnabled"), isOn: binding(\.mockEnabled))
                    Text(model.text("mockHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Text(model.text("nextLaunch")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
            GroupBox(model.text("translationModel")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text("translationModelHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    if model.translationAvailable {
                        HStack {
                            Button(model.text("translationModelSelect")) { model.chooseTranslationModel() }
                            if !(model.settingsDraft?.value.translationModelPath ?? "").isEmpty {
                                Button(model.text("translationModelClear")) { model.clearTranslationModel() }
                            }
                        }
                    } else { Text(model.text("translationModelUnavailable")).foregroundStyle(palette.secondary.color) }
                    let path = model.settingsDraft?.value.translationModelPath ?? ""
                    if !path.isEmpty {
                        Text(TranslationSettings.displayName(for: path)).textSelection(.enabled)
                        Text(model.text("translationModelClearDesc")).font(.caption).foregroundStyle(palette.secondary.color)
                    }
                    Text(model.text("translationTargetHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Text(model.text("nextLaunch")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
        case "diagnosticsSection":
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(model.text("logs"), isOn: binding(\.logs))
                    Toggle(model.text("errorDialogLogs"), isOn: binding(\.errorDialogLogs))
                    Text(model.text("errorDialogLogsHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }
                    Text(model.text("diagnosticSettingsPending")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
        case "advancedSection":
            Text(model.text("advancedToolsPending")).foregroundStyle(palette.secondary.color)
        default:
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("AetherKiri").font(.headline)
                    Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                         + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—") + ")")
                    Button(model.text("privacyDocument")) { document = .privacy }
                    Menu(model.text("licenses")) {
                        Button("GNU GPLv3") { document = .license }
                        Button(model.text("additionalLicense")) { document = .additionalLicense }
                        Button(model.text("thirdPartyLicenses")) { document = .thirdParty }
                    }.fixedSize()
                    Button(model.text("qqGroup")) { model.openQQGroup() }
                    Text(model.text("storage")).font(.headline)
                    Text(model.repository.root.path).font(.caption).textSelection(.enabled)
                }.padding(12)
            }
        }
    }
}
