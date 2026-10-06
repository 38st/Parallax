import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1,
      let bundle = Bundle(url: URL(fileURLWithPath: arguments[1])) else {
    fatalError("Expected a packaged app path")
}
precondition(Set(bundle.localizations) == ["en"], "Only English may be packaged")
precondition(bundle.preferredLocalizations.first == "en", "English fallback must be selected")
let text = bundle.localizedString(forKey: "Cancel", value: "missing copy", table: nil)
precondition(text == "Cancel", "Main bundle English lookup failed: \(text)")
print("Packaged main bundle English fallback: Cancel = \(text)")
