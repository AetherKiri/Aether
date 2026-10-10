import SwiftUI

struct DeveloperContentView: View {
    @StateObject private var engine = EngineController()
    @State private var gamePath: String = EngineController.defaultGamePath

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(alignment: .top, spacing: 0) {
                frameArea
                Divider()
                logArea
            }
        }
        .modifier(PlatformDialogPresentation(dialogs: engine.platformDialogs, language: .system))
        .onAppear { engine.autorunIfRequested() }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("① 初始化引擎") { engine.initializeEngine() }
                TextField("游戏路径", text: $gamePath)
                    .textFieldStyle(.roundedBorder)
                Button("② 打开并运行") { engine.openAndRun(gamePath: gamePath) }
                Button("停止") { engine.stopLoop() }
                Button("销毁") { engine.shutdown() }
            }
            HStack {
                Text("状态：\(engine.status)")
                    .font(.callout)
                Toggle("Metal 呈现", isOn: $engine.useMetalPresentation)
                    .disabled(engine.metalPresenter == nil)
                Spacer()
                Text("tick \(engine.tickCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var frameArea: some View { GameSurfaceView(engine: engine) }

    private var logArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(engine.logText.isEmpty ? "（日志）" : engine.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: engine.logText) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

#Preview {
    DeveloperContentView()
}
