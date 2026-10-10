import Foundation

@main
struct ShellStringsTests {
    static func main() {
        let languages = ShellLanguage.allCases
        precondition(languages.count == 5)
        precondition(Set(languages.map(\.index)) == Set(0..<5))
        precondition(ShellLanguage.localizationKeys.count >= 80)
        for key in ShellLanguage.localizationKeys {
            guard let values = ShellLanguage.localizedValues(for: key) else { fatalError("missing values: \(key)") }
            precondition(values.count == languages.count, "wrong language count: \(key)")
            precondition(values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "empty translation: \(key)")
            for language in languages {
                precondition(language.text(key) == values[language.index], "lookup mismatch: \(key)")
            }
        }
        precondition(ShellLanguage.english.text("missing-key") == "missing-key")
        precondition(ShellLanguage(rawValue: "english")?.locale.identifier == "en")
        precondition(ShellLanguage(rawValue: "traditional")?.locale.identifier == "zh-Hant")
        print("PASS: five-language catalog, key coverage, non-empty translations, locale mapping and fallback")
    }
}
