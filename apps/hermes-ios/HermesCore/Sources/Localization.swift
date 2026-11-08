import Foundation

/// A string from HermesCore's own String Catalog (`Localizable.xcstrings` in this framework):
/// `String(localized:)` alone would look in the app's bundle. Literals passed here are
/// extracted like `String(localized:)`'s, since the parameter is a `LocalizationValue`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: #bundle)
}
