import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1,
      let bundle = Bundle(url: URL(fileURLWithPath: arguments[1])) else {
    fatalError("Expected a packaged app path")
}
precondition(bundle.localizations.contains("en") && bundle.localizations.contains("es"))
precondition(bundle.preferredLocalizations.first == "es", "Run with -AppleLanguages '(es)'")
let translated = bundle.localizedString(forKey: "Cancel", value: "missing translation", table: nil)
precondition(translated == "Cancelar", "Main bundle Spanish lookup failed: \(translated)")
print("Packaged main bundle Spanish: Cancel = \(translated)")
