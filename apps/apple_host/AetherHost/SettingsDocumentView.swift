import SwiftUI

enum SettingsDocument: String, Identifiable {
    case privacy, license, additionalLicense, thirdParty
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .privacy: return "privacyDocument"
        case .license: return "licenses"
        case .additionalLicense: return "additionalLicense"
        case .thirdParty: return "thirdPartyLicenses"
        }
    }
    func resource(language: ShellLanguage) -> (String, String?) {
        switch self {
        case .privacy:
            return ("privacy_disclaimer_" + ["zh_hans", "zh_hant", "en", "ja", "ko"][language.index], "txt")
        case .license: return ("LICENSE", nil)
        case .additionalLicense: return ("COPYING", "iOS")
        case .thirdParty: return ("THIRD_PARTY_LICENSES", "md")
        }
    }
    func contents(language: ShellLanguage, bundle: Bundle = .main) -> String? {
        let (name, ext) = resource(language: language)
        guard let url = bundle.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct SettingsDocumentView: View {
    let document: SettingsDocument
    let language: ShellLanguage
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text(document.titleKey)).font(.title2.bold())
            ScrollView {
                Text(document.contents(language: language) ?? language.text("documentUnavailable"))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            HStack {
                Spacer()
                Button(language.text("ok"), action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 720, height: 560)
    }
}

/// First-use legal gate. Presented modally and non-dismissable until the user
/// either accepts (persisted separately from settings) or declines (quit).
struct LegalAgreementView: View {
    let language: ShellLanguage
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("legalTitle")).font(.title2.bold())
            Text(language.text("legalFirstSummary")).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(SettingsDocument.privacy.contents(language: language) ?? language.text("documentUnavailable"))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            HStack {
                Button(language.text("legalDecline"), action: decline).keyboardShortcut(.cancelAction)
                Spacer()
                Button(language.text("legalAccept"), action: accept).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 600)
    }
}
