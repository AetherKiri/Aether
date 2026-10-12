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

    private var draftEnhancementKind: FrameEnhancementKind {
        FrameEnhancementKind(rawValue: (model.settingsDraft?.value ?? model.settings).frameEnhancementKind) ?? .off
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
                    if model.settingsDraft?.value.virtualControls ?? model.settings.virtualControls {
                        Toggle(model.text("virtualControlMenu"), isOn: binding(\.virtualControlMenuEnabled))
                        Text(model.text("virtualControlMenuHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                        HStack {
                            Text(model.text("virtualKeyboardOpacity"))
                            Slider(value: binding(\.virtualControlKeyboardOpacity),
                                   in: VirtualControlOpacity.minimum...VirtualControlOpacity.maximum,
                                   step: VirtualControlOpacity.step)
                            Text("\(VirtualControlOpacity.percent(model.settingsDraft?.value.virtualControlKeyboardOpacity ?? model.settings.virtualControlKeyboardOpacity))%")
                                .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        }
                        Text(model.text("virtualKeyboardOpacityHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                        let mode = VirtualControlMode.normalized(model.settingsDraft?.value.virtualControlMode ?? model.settings.virtualControlMode) ?? .mouse
                        Text(model.text("virtualModeLabel") + " · " + model.text(mode.textKey) + " · " + model.text(mode.helpKey))
                            .font(.caption).foregroundStyle(palette.secondary.color)
                    }
                }.padding(12)
            }
        case "renderSection":
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(model.text("renderer"), selection: binding(\.renderer)) {
                        Text(model.text("software")).tag("software")
                        // Menu items ignore `.disabled` in this SwiftUI picker
                        // style, so an unavailable option must not be listed.
                        if model.capabilities.nativeMetal.available || model.settingsDraft?.value.renderer == "metal" {
                            Text(model.text("metal")).tag("metal")
                        }
                    }
                    Text(model.text("rendererHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Picker(model.text("canvasMode"), selection: binding(\.canvasMode)) {
                        ForEach(CanvasMode.allCases, id: \.rawValue) { mode in Text(model.text("canvas_" + mode.rawValue)).tag(mode.rawValue) }
                    }
                    Text(model.text("canvasModeHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Picker(model.text("outputResolution"), selection: binding(\.outputResolution)) {
                        ForEach(OutputResolution.allCases, id: \.rawValue) { resolution in
                            Text(model.text("output_" + resolution.rawValue)).tag(resolution.rawValue)
                        }
                    }
                    Text(model.text("outputResolutionHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Picker(model.text("samplingAlgorithm"), selection: binding(\.upscaleAlgorithm)) {
                        ForEach(SamplingAlgorithm.allCases, id: \.rawValue) { algorithm in
                            Text(model.text("sampling_" + algorithm.rawValue)).tag(algorithm.rawValue)
                        }
                    }
                    Text(model.text("samplingAlgorithmHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Picker(model.text("frameEnhancement"), selection: binding(\.frameEnhancementKind)) {
                        ForEach(FrameEnhancementKind.allCases) { kind in
                            Text(model.text(kind.textKey)).tag(kind.rawValue)
                        }
                    }
                    if draftEnhancementKind == .preset {
                        Picker(model.text("enhancementMode"), selection: binding(\.frameEnhancementPreset)) {
                            ForEach(EnhancementPreset.all) { preset in
                                Text(model.text(preset.textKey)).tag(preset.id)
                            }
                        }
                    } else if draftEnhancementKind == .custom {
                        EnhancementChainEditor(model: model)
                    }
                    if draftEnhancementKind != .off {
                        HStack {
                            Text(model.text("enhancementAmount"))
                            Slider(value: binding(\.frameEnhancementAmount),
                                   in: FrameEnhancementKernel.amountRange, step: 0.05)
                            Text("\(Int((HostSettings.normalizedEnhancementAmount(model.settingsDraft?.value.frameEnhancementAmount ?? model.settings.frameEnhancementAmount) * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        }
                    }
                    Text(model.text("frameEnhancementHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Text(model.text("enhancementNotMigrated")).font(.caption).foregroundStyle(palette.secondary.color)
                    if let reason = model.capabilities.enhancement.reasonKey {
                        Text(model.text(reason)).font(.caption).foregroundStyle(palette.secondary.color)
                    }
                    Toggle(model.text("fpsLimit"), isOn: binding(\.fpsLimitEnabled))
                    if model.settingsDraft?.value.fpsLimitEnabled ?? model.settings.fpsLimitEnabled {
                        Picker(model.text("targetFPS"), selection: binding(\.targetFPS)) {
                            ForEach(FrameScheduler.supportedTargets, id: \.self) { fps in
                                Text("\(fps) FPS").tag(fps)
                            }
                        }
                    } else {
                        Text(model.text("fpsPacingFollowDisplay")).font(.caption).foregroundStyle(palette.secondary.color)
                    }
                    Text(model.text("fpsLimitHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    if let reason = model.capabilities.nativeMetal.reasonKey {
                        Label(model.text(reason), systemImage: "exclamationmark.triangle").font(.caption)
                        if !model.capabilities.nativeMetal.detail.isEmpty {
                            Text(model.capabilities.nativeMetal.detail).font(.caption).foregroundStyle(palette.secondary.color)
                        }
                    }
                    Text(model.text("nativeRuntimeCheck")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
            if model.engine.renderState.effective != nil {
                GroupBox(model.text("lastRenderSession")) { RenderingStatusView(engine: model.engine, language: model.language).padding(12) }
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
                        if model.translationConfigurationPreview {
                            Text(model.text("translationConfigurationPreview")).font(.caption).foregroundStyle(palette.secondary.color)
                        }
                        HStack {
                            Button(model.text("translationModelSelect")) { model.chooseTranslationModel() }
                            if !(model.settingsDraft?.value.translationModelPath ?? "").isEmpty {
                                Button(model.text("translationModelClear")) { model.clearTranslationModel() }
                            }
                        }
                    } else { Text(model.text(model.capabilities.translation.reasonKey ?? "translationModelUnavailable")).foregroundStyle(palette.secondary.color) }
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
                    // Only profiles with a real sampling source are listed; the
                    // note below names the categories this build cannot sample.
                    let profileValue = model.settingsDraft?.value.diagnosticProfile ?? model.settings.diagnosticProfile
                    Picker(model.text("diagnosticProfile"), selection: binding(\.diagnosticProfile)) {
                        ForEach(DiagnosticProfile.allCases.filter { $0.hasAppleSampling || $0.rawValue == profileValue }) { profile in
                            Text(model.text(profile.textKey)).tag(profile.rawValue)
                        }
                    }
                    Text(model.text("diagnosticProfileHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    if let profile = DiagnosticProfile.normalized(model.settingsDraft?.value.diagnosticProfile ?? model.settings.diagnosticProfile) {
                        Text(model.text(profile.textKey) + " · " + profile.summary)
                            .font(.caption).foregroundStyle(palette.secondary.color)
                    }
                    Text(model.text("diagnosticProfileUnavailable")).font(.caption).foregroundStyle(palette.secondary.color)
                    Picker(model.text("diagnosticOverlay"), selection: binding(\.debugOverlayMode)) {
                        ForEach(DebugOverlayMode.allCases) { mode in
                            Text(model.text(mode.textKey)).tag(mode.rawValue)
                        }
                    }
                    Text(model.text("diagnosticOverlayHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Toggle(model.text("logs"), isOn: binding(\.logs))
                    Toggle(model.text("errorDialogLogs"), isOn: binding(\.errorDialogLogs))
                    Text(model.text("errorDialogLogsHelp")).font(.caption).foregroundStyle(palette.secondary.color)
                    Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }
                }.padding(12)
            }
        case "advancedSection":
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.text("advancedDesc")).font(.caption).foregroundStyle(palette.secondary.color)
                    ForEach(TransientDiagnosticsTools.Option.allCases) { option in
                        Toggle(model.text(option.textKey), isOn: Binding(
                            get: { model.engine.advancedTools.isEnabled(option) },
                            set: { model.engine.setAdvancedTool(option, enabled: $0) }
                        ))
                        Text(model.text(option.descKey)).font(.caption).foregroundStyle(palette.secondary.color)
                    }
                    Text(model.text("advancedScenePending")).font(.caption).foregroundStyle(palette.secondary.color)
                }.padding(12)
            }
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
/// Godot's custom enhancement chain editor: ordered steps, each with an
/// algorithm picker and a remove button, plus an add action. Only verified
/// algorithms are offered; the first step may scale the output (EASU), later
/// steps run at the output resolution.
private struct EnhancementChainEditor: View {
    @Environment(\.shellPalette) private var palette
    @ObservedObject var model: ShellModel

    private var chain: [String] { (model.settingsDraft?.value ?? model.settings).frameEnhancementChain }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chain.isEmpty {
                Text(model.text("enhancementCustomEmpty")).font(.caption).foregroundStyle(palette.secondary.color)
            }
            ForEach(Array(chain.enumerated()), id: \.offset) { index, algorithm in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: model.text("enhancementCustomStep"), index + 1)).font(.subheadline)
                        Text(model.text("enhancementDesc_" + algorithm)).font(.caption).foregroundStyle(palette.secondary.color)
                    }
                    Spacer()
                    Picker("", selection: chainBinding(index)) {
                        ForEach(availableSteps(for: index)) { step in
                            Text(model.text(step.textKey)).tag(step.rawValue)
                        }
                    }.labelsHidden().frame(width: 220)
                    Button { removeStep(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.text("enhancementCustomRemove"))
                }
            }
            Button(model.text("enhancementCustomAdd")) { addStep() }
                .disabled(chain.count >= FrameEnhancementChain.maximumSteps)
        }
    }

    private func availableSteps(for index: Int) -> [FrameEnhancement] {
        let steps = FrameEnhancement.allCases.filter { $0.isStep }
        return index == 0 ? steps : steps.filter { !$0.scalesOutput }
    }

    private func chainBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { chain.indices.contains(index) ? chain[index] : FrameEnhancement.fsr1Rcas.rawValue },
            set: { value in
                guard var draft = model.settingsDraft,
                      draft.value.frameEnhancementChain.indices.contains(index) else { return }
                draft.value.frameEnhancementChain[index] = value
                model.settingsDraft = draft
            }
        )
    }

    private func addStep() {
        guard var draft = model.settingsDraft,
              draft.value.frameEnhancementChain.count < FrameEnhancementChain.maximumSteps else { return }
        draft.value.frameEnhancementChain.append(FrameEnhancement.fsr1Rcas.rawValue)
        model.settingsDraft = draft
    }

    private func removeStep(_ index: Int) {
        guard var draft = model.settingsDraft,
              draft.value.frameEnhancementChain.indices.contains(index) else { return }
        draft.value.frameEnhancementChain.remove(at: index)
        model.settingsDraft = draft
    }
}
