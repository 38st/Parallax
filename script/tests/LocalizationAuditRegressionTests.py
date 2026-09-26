import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('audit_checker', ROOT / 'check_localization_completeness.py')
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)


class LocalizationAuditRegressionTests(unittest.TestCase):
    def inventory(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Fixture.swift').write_text(source)
            return CHECKER._source_inventory(root)

    def test_initializer_memberwise_ternary_and_returned_keys(self):
        occurrences, unknown = self.inventory('''
struct Detail { let title: LocalizedStringKey; let value: String }
struct Recovery {
    init(title: LocalizedStringKey, detail: LocalizedStringKey) {}
}
func progress(_ value: Int) -> LocalizedStringKey {
    switch value { case 0: "Preparing"; default: "Complete" }
}
let view = Recovery(title: "Recovery", detail: "Try again")
let row = Detail(title: "Process", value: "Not localized")
let text = Text(flag ? "Ready" : "Waiting")
let raw = Text(verbatim: flag ? "Raw A" : "Raw B")
''')
        self.assertEqual({o.key for o in occurrences},
                         {'Recovery', 'Try again', 'Process', 'Preparing', 'Complete', 'Ready', 'Waiting'})
        self.assertEqual(unknown, ())

    def test_enum_payload_resolves_pid_width(self):
        occurrences, unknown = self.inventory(r'''
enum Failure {
    case missing(pid_t)
    var description: String {
        switch self { case .missing(let processIdentifier):
            String(localized: "Process \(processIdentifier) missing")
        }
    }
}
''')
        self.assertEqual({o.key for o in occurrences}, {'Process %d missing'})
        self.assertEqual(unknown, ())

    def test_unresolved_integer_width_fails_closed(self):
        occurrences, unknown = self.inventory(r'let text = Text("Process \(processIdentifier)")')
        self.assertEqual(occurrences, ())
        self.assertEqual(len(unknown), 1)

    def test_multiline_uses_closing_delimiter_indentation(self):
        occurrences, _ = self.inventory('let text = Text("""\n    Extra indent\n  """)')
        self.assertEqual({o.key for o in occurrences}, {'  Extra indent'})

    def test_empty_discovery_fails(self):
        spec = importlib.util.spec_from_file_location('audit_runner', ROOT / 'test_localization_completeness.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with mock.patch.object(unittest.defaultTestLoader, 'discover', return_value=unittest.TestSuite()):
            self.assertNotEqual(runner.main(), 0)

    def test_existing_spanish_labels_have_contextual_meaning(self):
        translations, _ = CHECKER.parse_strings_catalog(ROOT.parent / 'Sources/Parallax/Resources/es.lproj/Localizable.strings')
        for key, expected in {'Match System': 'Usar el ajuste del sistema', 'Light': 'Claro',
                              'Work': 'Trabajo', 'Throwaway': 'Desechable',
                              'Brave': 'Brave', 'Edge': 'Edge', 'Show': 'Mostrar',
                              'Crashed': 'Cierre inesperado'}.items():
            self.assertEqual(translations[key], expected)

    def test_cross_file_payload_width_and_arity_are_resolved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Types.swift').write_text('enum A { case retry(Int32, Int) } enum B { case retry(Int) }')
            (root / 'View.swift').write_text(r'''switch value { case let .retry(pid, count): Text("Retry \(pid), \(count)") }''')
            occurrences, unknown = CHECKER._source_inventory(root)
        self.assertEqual({o.key for o in occurrences}, {'Retry %d, %lld'})
        self.assertEqual(unknown, ())

    def test_string_expressions_are_not_localized_literal_branches(self):
        occurrences, unknown = self.inventory('''
let name: String? = nil
let other: String = "runtime"
Text(name ?? "Fallback Name")
Text(flag ? "String branch" : other)
Text(flag ? other : "Other string branch")
Text(flag ? "Localized true" : "Localized false")
''')
        self.assertEqual({o.key for o in occurrences}, {'Localized true', 'Localized false'})
        self.assertEqual(unknown, ())

    def test_localized_results_exclude_dictionary_and_call_arguments(self):
        occurrences, unknown = self.inventory('''
func title() -> LocalizedStringKey {
    let entries = ["key": "Raw dictionary value"]
    let label = String(format: "Raw format", "Argument")
    let raw = switch state { case .ready: "Raw switch"; default: "Other raw switch" }
    return "Returned title"
}
var detail: LocalizedStringKey {
    switch state {
    case .ready:
        let label = String(format: "Case format")
        return "Ready result"
    default: "Fallback result"
    }
}
var simple: LocalizedStringKey { "Simple result" }
''')
        self.assertEqual({o.key for o in occurrences},
                         {'Returned title', 'Ready result', 'Fallback result', 'Simple result'})
        self.assertEqual(unknown, ())

    def test_conflicting_inferred_and_explicit_widths_fail_closed(self):
        for declaration in ('let value = small', 'let value: Int32 = 1', 'let value = Int32(1)'):
            with self.subTest(declaration=declaration):
                occurrences, unknown = self.inventory('let small: Int32 = 1\n' +
                    'func a() { ' + declaration + r'; Text("Value \(value)") }' + '\n' +
                    r'func b() { let value = 2; Text("Value \(value)") }')
                self.assertEqual(occurrences, ())
                self.assertEqual(len(unknown), 2)

    def test_conflicting_string_named_declarations_do_not_guess(self):
        occurrences, unknown = self.inventory(r'''
func a(valueName: Int32) { Text("Name \(valueName)") }
func b(valueName: Int64) { Text("Name \(valueName)") }
''')
        self.assertEqual(occurrences, ())
        self.assertEqual(len(unknown), 2)

    def test_spanish_review_uses_formal_actions_and_context(self):
        translations, _ = CHECKER.parse_strings_catalog(ROOT.parent / 'Sources/Parallax/Resources/es.lproj/Localizable.strings')
        for key, expected in {
            'Media': 'Media',
            'Will be added': 'Se añadirá',
            'Will be changed': 'Se modificará',
            'Will be removed': 'Se eliminará',
            'Will be retained': 'Se conservará',
            'The application no longer exists. Removal was cancelled.':
                'La aplicación ya no existe. Se canceló la eliminación.',
            'The application changed while its new location was being verified. Try again.':
                'La aplicación cambió mientras se verificaba su nueva ubicación. Inténtelo de nuevo.',
            'Storage relocation was cancelled. Managed data remains at its original location.':
                'Se canceló el traslado del almacenamiento. Los datos administrados permanecen en su ubicación original.',
            'Your Spaces': 'Sus espacios',
            'The application changed identity. Your draft was kept.':
                'La aplicación cambió de identidad. Se conservó su borrador.',
        }.items():
            self.assertEqual(translations[key], expected)

    def test_nominal_scopes_do_not_share_unrelated_payload_types(self):
        occurrences, unknown = self.inventory(r'''
enum A {
    case value(Int32)
    var title: String { switch self { case .value(let value): String(localized: "Narrow \(value)") } }
}
struct B {
    let value: Int64
    var body: some View { Text("Wide \(value)") }
}
''')
        self.assertEqual({o.key for o in occurrences}, {'Narrow %d', 'Wide %lld'})
        self.assertEqual(unknown, ())
