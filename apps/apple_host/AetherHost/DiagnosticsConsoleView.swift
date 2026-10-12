import AppKit
import SwiftUI

/// In-game diagnostics console, mirroring Godot's dockable debug console: it
/// reuses the data the host already collects instead of screenshotting a panel.
/// The text stays close to the technical English Godot surfaces.
struct DiagnosticsConsoleView: View {
    @Environment(\.shellPalette) private var palette
    @ObservedObject var model: ShellModel
    @ObservedObject var engine: EngineController

    @State private var tab = ConsoleTab.overview
    @State private var paused = false
    @State private var filter = ""
    @State private var frozenLog = ""
    @State private var markerType = DiagnosticsConsoleView.markerTypes[0]
    @State private var result: String?

    /// Godot's `DebugConsole.MARKER_TYPES`.
    static let markerTypes = ["user_issue", "slow_frame", "input_issue", "visual_issue", "audio_issue", "loading_issue"]

    enum ConsoleTab: String, CaseIterable, Identifiable {
        case overview, performance, input, plugins, log
        var id: String { rawValue }
        var textKey: String { "consoleTab_" + rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(ConsoleTab.allCases) { entry in
                    Text(model.text(entry.textKey)).tag(entry)
                }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case .overview: overview
                    case .performance: performance
                    case .input: input
                    case .plugins: plugins
                    case .log: log
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Divider()
            actions
        }
        .padding(10)
        .onAppear { frozenLog = engine.logText }
        .onChange(of: engine.logText) { _ in if !paused { frozenLog = engine.logText } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(palette.secondary.color).frame(width: 132, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11, design: .monospaced))
    }

    private var overview: some View {
        Group {
            row("status", engine.status)
            row("rendererRequested", engine.renderState.requested.rawValue)
            row("renderer", engine.renderState.effective?.rawValue ?? "uninitialized")
            row("presentation", engine.renderState.presentation?.rawValue ?? "uninitialized")
            row("frame", "\(Int(engine.frameSize.width))x\(Int(engine.frameSize.height))")
            row("output", "\(Int(engine.outputFrameSize.width))x\(Int(engine.outputFrameSize.height))")
            row("fpsLimit", model.settings.fpsLimitOption)
            row("tick", "\(engine.tickCount)")
            ForEach(Array(engine.renderState.fallbacks.enumerated()), id: \.offset) { _, fallback in
                row("fallback", fallback.reasonKey + ": " + fallback.detail)
            }
            if let failure = engine.failureMessage { row("failure", failure) }
        }
    }

    private var performance: some View {
        var snapshot = engine.overlaySnapshot
        // The console is an explicit diagnostics surface, so always show the
        // full detail lines rather than gating on the overlay setting.
        snapshot.mode = "detail"
        return ForEach(Array(DiagnosticOverlay.lines(snapshot).enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var input: some View {
        Group {
            row("virtualMode", model.settings.virtualControlMode)
            row("virtualPanel", model.virtualPanelVisible ? "visible" : "hidden")
            row("virtualHeld", engine.virtualControlHeld ? "yes" : "no")
            row("pointer", String(format: "%.0f, %.0f", engine.virtualPointerPosition.x, engine.virtualPointerPosition.y))
            row("textEntry", model.showGameTextEntry ? "open" : "closed")
            row("ime", engine.gameTextInput.imeActive ? "active(\(engine.gameTextInput.imeMode))" : "idle")
            row("fullscreen", model.isFullscreen ? "yes" : "no")
            row("movie", engine.runtimeMovieActive ? "playing" : "idle")
            row("inputSuspended", engine.inputSuspended ? "yes" : "no")
        }
    }

    private var plugins: some View {
        Group {
            row("pluginLoad", model.settings.pluginLoadMode)
            row("mock", model.settings.mockEnabled ? "enabled" : "disabled")
            if let game = model.activeGame {
                let inspection = GameRuntimeDetector.inspect(root: model.repository.gameURL(game))
                row("runtime", inspection.runtime.rawValue)
                row("entry", inspection.entryFile.isEmpty ? "(directory)" : inspection.entryFile)
                row("signals", inspection.signals.joined(separator: ", "))
                if let provider = inspection.runtime.providerId {
                    let probe = AetherEngineSession.probeRuntimeProvider(
                        provider, path: model.repository.gameURL(game).path)
                    row("provider", "\(provider) = \(probe)")
                }
            }
            row("translation", model.capabilities.translation.available ? "available" : "unavailable")
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(model.text("consolePause"), isOn: $paused).toggleStyle(.checkbox)
                TextField(model.text("consoleFilter"), text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            Text(filteredLog)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filteredLog: String {
        guard !filter.isEmpty else { return frozenLog }
        return frozenLog.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $markerType) {
                    ForEach(Self.markerTypes, id: \.self) { type in
                        Text(type.replacingOccurrences(of: "_", with: " ")).tag(type)
                    }
                }.labelsHidden().frame(width: 150)
                Button(model.text("consoleMark")) {
                    result = model.markDiagnosticIssue(markerType)
                        ? model.text("consoleMarked") + " \(markerType)"
                        : model.text("consoleMarkerLimit")
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button(model.text("consoleSlowFrame")) {
                    result = model.armSlowFrameCapture() ? model.text("consoleSlowArmed") : model.text("consoleFailed")
                }
                Button(model.text("consoleSnapshot")) { report(model.captureDiagnosticSnapshot()) }
                Button(model.text("consoleScreenshot")) { report(model.captureDiagnosticScreenshot()) }
            }
            HStack(spacing: 10) {
                Button(model.text("consoleSelfCheck")) {
                    result = model.runDiagnosticSelfCheck()
                }
                Button(model.text("consoleCopySummary")) { copySummary() }
                Button(model.text("exportDiagnostics")) { model.exportDiagnostics() }
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(palette.secondary.color)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
    }

    private func report(_ url: URL?) {
        guard let url else { result = model.text("consoleFailed"); return }
        result = model.text("consoleSaved") + " " + url.lastPathComponent
    }

    private func copySummary() {
        let summary = [
            "status: \(engine.status)",
            "renderer: \(engine.renderState.effective?.rawValue ?? "uninitialized")",
            "presentation: \(engine.renderState.presentation?.rawValue ?? "uninitialized")",
            "frame: \(Int(engine.frameSize.width))x\(Int(engine.frameSize.height))",
        ].joined(separator: "\n") + "\n" + DiagnosticOverlay.lines(engine.overlaySnapshot).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        result = model.text("consoleCopied")
    }
}
