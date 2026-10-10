import Foundation

@main
struct TranslationSettingsTests {
    static func main() {
        // Target language codes mirror the Godot shell's LANG_* constants.
        let expected: [(ShellLanguage, String)] = [
            (.simplified, "zh_hans"), (.traditional, "zh_hant"),
            (.english, "en"), (.japanese, "ja"), (.korean, "ko"),
        ]
        for (language, code) in expected {
            precondition(TranslationSettings.targetLanguageCode(for: language) == code, "code for \(language)")
        }

        // Options mirror the Godot shell's _apply_engine_options order/values.
        var settings = TranslationSettings(modelPath: "  /tmp/models/qwen.gguf ")
        precondition(settings.normalizedPath == "/tmp/models/qwen.gguf")
        precondition(settings.isConfigured)
        precondition(settings.displayName == "qwen.gguf")
        let options = settings.engineOptions(targetLanguage: "zh_hans")
        precondition(options.count == 3)
        precondition(options[0].key == "text_translation.model_path" && options[0].value == "/tmp/models/qwen.gguf")
        precondition(options[1].key == "text_translation.target_language" && options[1].value == "zh_hans")
        precondition(options[2].key == "text_translation.enabled" && options[2].value == "1")

        // Clearing the path disables translation without dropping the option keys.
        settings.modelPath = "   "
        precondition(!settings.isConfigured)
        precondition(settings.displayName.isEmpty)
        let cleared = settings.engineOptions(targetLanguage: "ja")
        precondition(cleared[0].value.isEmpty)
        precondition(cleared[1].value == "ja")
        precondition(cleared[2].value == "0")

        // Validation: extension (case-insensitive), existence and file type.
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("aether-translation-tests-\(UUID().uuidString)")
        try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        precondition(TranslationSettings.validate(path: "") == .empty)
        precondition(TranslationSettings.validate(path: "   ") == .empty)
        precondition(TranslationSettings.validate(path: directory.path) == .wrongExtension)
        precondition(TranslationSettings.validate(path: directory.appendingPathComponent("notes.txt").path) == .wrongExtension)
        precondition(TranslationSettings.validate(path: directory.appendingPathComponent("missing.gguf").path) == .missingFile)
        let folder = directory.appendingPathComponent("folder.gguf")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        precondition(TranslationSettings.validate(path: folder.path) == .missingFile)
        let model = directory.appendingPathComponent("MODEL.GGUF")
        fm.createFile(atPath: model.path, contents: Data([0x47, 0x47, 0x55, 0x46]))
        precondition(TranslationSettings.validate(path: model.path) == nil)
        precondition(TranslationSettings.validate(path: "  " + model.path + "  ") == nil)

        // Engine state mapping and settings-page text.
        let disabled = TranslationStatus(state: 0)
        precondition(disabled.state == .disabled)
        precondition(disabled.summary { $0 } == "translationStatusDisabled")
        precondition(disabled.detail { $0 }.isEmpty)
        let loading = TranslationStatus(state: 1)
        precondition(loading.summary { $0 } == "translationLoading")
        let failed = TranslationStatus(state: 3)
        precondition(failed.summary { $0 } == "translationStatusFailed")
        // Unknown values fall back to disabled instead of trapping.
        precondition(TranslationStatus(state: 9).state == .disabled)

        let ready = TranslationStatus(
            state: 2,
            stats: [
                "backend": NSNumber(value: 1),
                "modelFileBytes": NSNumber(value: 2_147_483_648),
                "translationsCompleted": NSNumber(value: 42),
                "translationsFailed": NSNumber(value: 1),
            ])
        precondition(ready.state == .ready)
        precondition(ready.backend == "cpu")
        precondition(ready.modelFileBytes == 2_147_483_648)
        precondition(ready.summary { $0 } == "translationStatusReady")
        let detail = ready.detail { $0 }
        precondition(detail.contains("translationBackend: cpu"), detail)
        precondition(detail.contains("translationDone: 42"), detail)
        precondition(detail.contains("translationFailedCount: 1"), detail)

        // Statistics without a loaded model do not produce a detail line.
        let idle = TranslationStatus(state: 0, stats: ["translationsCompleted": NSNumber(value: 3)])
        precondition(idle.detail { $0 }.contains("translationDone: 3"))
        precondition(TranslationStatus(state: 0).detail { $0 }.isEmpty)
        precondition(TranslationBackend.label(for: 1) == "cpu")
        precondition(TranslationBackend.label(for: 2) == "gpu")
        precondition(TranslationBackend.label(for: 0).isEmpty)
        precondition(!TranslationStatus.byteCount(2_147_483_648).isEmpty)

        print("PASS: translation settings, option mapping, model validation and status text")
    }
}
