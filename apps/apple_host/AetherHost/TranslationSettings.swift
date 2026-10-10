import Foundation

/// Local GGUF text-translation settings, mirroring the Godot shell's
/// "Local Translation Model" compatibility row: the target language follows
/// the interface language, and translation is enabled whenever a model path is
/// configured. The engine only honours these options when the private
/// translation provider is linked; see engine_is_text_translation_available().
struct TranslationSettings: Equatable {
    static let modelFileExtension = "gguf"

    var modelPath: String = ""

    var normalizedPath: String {
        modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var isConfigured: Bool { !normalizedPath.isEmpty }
    var displayName: String { TranslationSettings.displayName(for: normalizedPath) }

    /// Generic ABI option keys consumed by the private translation provider
    /// (abi/include/engine_options.h).
    enum Option {
        static let enabled = "text_translation.enabled"
        static let modelPath = "text_translation.model_path"
        static let targetLanguage = "text_translation.target_language"
    }

    enum Failure: Equatable {
        case empty, wrongExtension, missingFile, notReadable
    }

    /// Target language codes used by the Godot shell (LANG_* constants).
    static func targetLanguageCode(for language: ShellLanguage) -> String {
        switch language {
        case .simplified: return "zh_hans"
        case .traditional: return "zh_hant"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        }
    }

    /// Options applied with engine_set_option before a game opens. Order and
    /// values match the Godot shell's _apply_engine_options().
    func engineOptions(targetLanguage: String) -> [(key: String, value: String)] {
        [(Option.modelPath, normalizedPath),
         (Option.targetLanguage, targetLanguage),
         (Option.enabled, isConfigured ? "1" : "0")]
    }

    static func displayName(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).lastPathComponent
    }

    /// Validates a picked model file. The extension check is case-insensitive;
    /// the file must exist as a readable regular file.
    static func validate(path: String, fileManager: FileManager = .default) -> Failure? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard (trimmed as NSString).pathExtension.lowercased() == modelFileExtension else {
            return .wrongExtension
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return .missingFile }
        guard fileManager.isReadableFile(atPath: trimmed) else { return .notReadable }
        return nil
    }
}

/// engine_text_translation_state_t.
enum TranslationState: UInt32 {
    case disabled = 0, loading = 1, ready = 2, failed = 3
}

/// engine_text_translation_backend_t.
enum TranslationBackend: UInt32 {
    case none = 0, cpu = 1, gpu = 2

    static func label(for raw: UInt32) -> String {
        switch TranslationBackend(rawValue: raw) {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        default: return ""
        }
    }
}

/// Process-wide translation state plus the statistics subset the settings page
/// shows. Built from engine_get_text_translation_state()/stats() snapshots.
struct TranslationStatus: Equatable {
    var state: TranslationState = .disabled
    var backend: String = ""
    var modelFileBytes: UInt64 = 0
    var translationsCompleted: UInt64 = 0
    var translationsFailed: UInt64 = 0

    init() {}

    init(state rawState: UInt32, stats: [String: NSNumber]? = nil) {
        state = TranslationState(rawValue: rawState) ?? .disabled
        guard let stats else { return }
        backend = TranslationBackend.label(for: stats["backend"]?.uint32Value ?? 0)
        modelFileBytes = stats["modelFileBytes"]?.uint64Value ?? 0
        translationsCompleted = stats["translationsCompleted"]?.uint64Value ?? 0
        translationsFailed = stats["translationsFailed"]?.uint64Value ?? 0
    }

    /// Status line for the settings page.
    func summary(_ t: (String) -> String) -> String {
        switch state {
        case .disabled: return t("translationStatusDisabled")
        case .loading: return t("translationLoading")
        case .ready: return t("translationStatusReady")
        case .failed: return t("translationStatusFailed")
        }
    }

    /// Optional detail line: backend, model size and completed translations.
    /// Empty while the model is not loaded.
    func detail(_ t: (String) -> String) -> String {
        guard state == .ready || translationsCompleted > 0 else { return "" }
        var parts: [String] = []
        if !backend.isEmpty { parts.append(t("translationBackend") + ": " + backend) }
        if modelFileBytes > 0 {
            parts.append(t("translationModelSize") + ": " + Self.byteCount(modelFileBytes))
        }
        parts.append(t("translationDone") + ": " + String(translationsCompleted))
        if translationsFailed > 0 { parts.append(t("translationFailedCount") + ": " + String(translationsFailed)) }
        return parts.joined(separator: " · ")
    }

    static func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
