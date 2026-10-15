import Foundation
import MIQCore

/// Localised text for the Quick Look preview (and the pieces shared with the
/// thumbnail extension and the app's panel preview). Every string lives in the
/// "Preview" table, `Preview.xcstrings`, which is a resource of each target
/// that compiles this file.
///
/// Two kinds of keys:
/// * Text written here and in the other extension files, looked up with
///   `String(localized: "…", table: "Preview")` — the table spelled as a
///   literal, which is what Xcode's string extraction reads.
/// * MIQCore's English UI text (field labels, badges, warnings, QC rows, error
///   descriptions). MIQCore stays English — it is also built on Linux and for
///   the CLI, where processed string-catalog resources aren't available — and
///   is translated here through `core(_:)`, whose keys are the phrases and
///   templates `CoreUIText` lists.
enum PreviewL10n {
    /// The table name. Not "Localizable", so the catalog can sit in the app
    /// target next to the app's own `Localizable.xcstrings`.
    static let table = "Preview"

    /// Marker returned by `Bundle.localizedString` for a key the catalog lacks.
    private static let missing = "\u{1}miq.missing\u{1}"

    /// `english` (text produced by MIQCore) in the user's language, falling back
    /// to the English for anything the catalog doesn't cover.
    static func core(_ english: String) -> String {
        CoreUIText.localize(english) { key in
            let value = Bundle.main.localizedString(forKey: key, value: missing, table: table)
            return value == missing ? nil : value
        }
    }

    /// Opacity menu titles: "25%" / "25 %" / "%25" by locale.
    static func percent(_ fraction: Float) -> String {
        Double(fraction).formatted(.percent.precision(.fractionLength(0)))
    }
}
