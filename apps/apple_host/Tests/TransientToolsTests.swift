import Foundation

/// Godot `_set_advanced_tool` semantics: session-only options, with a
/// 30-second deadline for the tracing flags.
enum TransientToolsTests {
    static func run() {
        optionCatalog()
        expiryMath()
        snapshotAndReset()
        print("PASS: advanced tool catalog, 30 s trace expiry, non-expiring console/export and diagnostics snapshot")
    }

    private static func optionCatalog() {
        precondition(TransientDiagnosticsTools.Option.allCases.map(\.rawValue)
            == ["plugin_trace", "trace_log", "console_log_file", "export_scripts"])
        precondition(TransientDiagnosticsTools.Option.pluginTrace.expires)
        precondition(TransientDiagnosticsTools.Option.traceLog.expires)
        precondition(!TransientDiagnosticsTools.Option.consoleLogFile.expires)
        precondition(!TransientDiagnosticsTools.Option.exportScripts.expires)
        precondition(TransientDiagnosticsTools.traceTimeout == 30)
        var tools = TransientDiagnosticsTools()
        precondition(tools.engineOptions.isEmpty)
        precondition(tools.snapshot(now: 0)["plugin_trace"] == "0")
        tools.set(.exportScripts, enabled: true, now: 0)
        precondition(tools.engineOptions.map(\.key) == ["export_scripts"])
        precondition(tools.engineOptions.first?.value == "1")
    }

    private static func expiryMath() {
        var tools = TransientDiagnosticsTools()
        tools.set(.pluginTrace, enabled: true, now: 100)
        precondition(tools.isEnabled(.pluginTrace))
        precondition(tools.deadline(.pluginTrace) == 130)
        precondition(tools.remainingSeconds(.pluginTrace, now: 100) == 30)
        precondition(tools.remainingSeconds(.pluginTrace, now: 129.5) == 1)
        precondition(tools.remainingSeconds(.pluginTrace, now: 130) == 0)
        // Just before the deadline nothing expires; at the deadline it does.
        precondition(tools.expire(now: 129.9).isEmpty && tools.isEnabled(.pluginTrace))
        let expired = tools.expire(now: 130)
        precondition(expired == [.pluginTrace] && !tools.isEnabled(.pluginTrace))
        precondition(tools.deadline(.pluginTrace) == nil && tools.remainingSeconds(.pluginTrace, now: 130) == nil)
        // A second expiration pass reports nothing.
        precondition(tools.expire(now: 200).isEmpty)
        // Untimed tools survive any expiration pass.
        tools.set(.consoleLogFile, enabled: true, now: 200)
        tools.set(.exportScripts, enabled: true, now: 200)
        precondition(tools.deadline(.consoleLogFile) == nil && tools.deadline(.exportScripts) == nil)
        precondition(tools.expire(now: 10_000).isEmpty)
        precondition(tools.isEnabled(.consoleLogFile) && tools.isEnabled(.exportScripts))
        // Disabling clears the deadline even for tracing flags.
        tools.set(.traceLog, enabled: true, now: 300)
        precondition(tools.deadline(.traceLog) == 330)
        tools.set(.traceLog, enabled: false, now: 301)
        precondition(!tools.isEnabled(.traceLog) && tools.deadline(.traceLog) == nil)
        // Re-enabling restarts the window rather than reusing the old deadline.
        tools.set(.traceLog, enabled: true, now: 400)
        precondition(tools.deadline(.traceLog) == 430)
        // Godot expires each tracing flag independently.
        tools.set(.pluginTrace, enabled: true, now: 500)
        tools.set(.traceLog, enabled: true, now: 510)
        precondition(tools.expire(now: 530) == [.pluginTrace])
        precondition(!tools.isEnabled(.pluginTrace) && tools.isEnabled(.traceLog))
        precondition(tools.expire(now: 540) == [.traceLog])
    }

    private static func snapshotAndReset() {
        var tools = TransientDiagnosticsTools()
        tools.set(.pluginTrace, enabled: true, now: 10)
        tools.set(.consoleLogFile, enabled: true, now: 10)
        let snapshot = tools.snapshot(now: 20)
        precondition(snapshot["plugin_trace"] == "1" && snapshot["plugin_trace_remaining_sec"] == "20")
        precondition(snapshot["trace_log"] == "0" && snapshot["trace_log_remaining_sec"] == nil)
        precondition(snapshot["console_log_file"] == "1" && snapshot["console_log_file_remaining_sec"] == nil)
        precondition(snapshot["export_scripts"] == "0")
        tools.reset()
        precondition(tools.engineOptions.isEmpty && !tools.isEnabled(.pluginTrace))
        precondition(tools.snapshot(now: 20).values.allSatisfy { $0 == "0" })
    }
}
