import Foundation

// User-facing text is looked up in the app bundle's `Localizable.strings` with
// the English wording as the key. A bundle without a matching translation, a
// `swift run` build with no `.lproj` directories, and the test target all fall
// back to the key itself, so every context reads as English rather than as an
// identifier. `scripts/check-localization.sh` keeps the tables and the call
// sites in step.

public func localized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

public func localized(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), arguments: arguments)
}
