import Foundation

/// Display name of the app (single place to change when renaming).
enum AppInfo {
    static let name = "Bossa"
    /// Marketing version (from the `VERSION` file at build time) and build number (build timestamp).
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var versionLabel: String { "\(version) (\(build))" }
}

/// Looks `key` up in the bundle's Localizable.strings (English source text is the key; a missing entry shows the key itself).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

/// Messages coming from the Rust core are English: either an exact string or "Prefix: detail".
func localizeCoreMessage(_ m: String) -> String {
    for p in ["Connection failed: ", "Could not apply the change: "] where m.hasPrefix(p) {
        return L(p + "%@", String(m.dropFirst(p.count)))
    }
    return L(m)
}

// MARK: - In-app language choice (overrides the system language without a relaunch)

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es, pt
    var id: String { rawValue }
    /// Languages are shown in their own name; "System default" follows the macOS setting.
    var displayName: String {
        switch self {
        case .system: return L("System default")
        case .en: return "English"
        case .es: return "Español"
        case .pt: return "Português"
        }
    }

    static let defaultsKey = "appLanguage"
    static var saved: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
}

/// `Bundle.main` with a swappable lookup table: both `NSLocalizedString` and SwiftUI's `Text("literal")` go through
/// `localizedString(forKey:)`, so replacing it re-localises the whole UI live.
private final class LanguageBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var override: Bundle?
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let o = Self.override { return o.localizedString(forKey: key, value: value, table: tableName) }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

func applyLanguage(_ lang: AppLanguage) {
    if !(Bundle.main is LanguageBundle) { object_setClass(Bundle.main, LanguageBundle.self) }
    if lang == .system {
        LanguageBundle.override = nil
    } else if let path = Bundle.main.path(forResource: lang.rawValue, ofType: "lproj"), let b = Bundle(path: path) {
        LanguageBundle.override = b
    }
    UserDefaults.standard.set(lang.rawValue, forKey: AppLanguage.defaultsKey)
}

/// One-time copy of the saved language / last-known device from the pre-rename "Bose Tray" defaults domain.
enum LegacyDefaults {
    static func migrate() {
        let d = UserDefaults.standard
        guard d.object(forKey: "migratedFromBoseTray") == nil else { return }
        if let old = UserDefaults(suiteName: "dev.local.bosetray") {
            for k in [AppLanguage.defaultsKey, LastKnown.key] where d.object(forKey: k) == nil {
                if let v = old.object(forKey: k) { d.set(v, forKey: k) }
            }
        }
        d.set(true, forKey: "migratedFromBoseTray")
    }
}
