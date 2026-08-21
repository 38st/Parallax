import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT_ROOT = pathlib.Path(__file__).resolve().parents[1]
CHECKER_PATH = SCRIPT_ROOT / "check_localization_completeness.py"
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"

SPEC = importlib.util.spec_from_file_location("localization_checker", CHECKER_PATH)
assert SPEC is not None and SPEC.loader is not None
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)


class LocalizationCompletenessTests(unittest.TestCase):
    def audit(self, fixture: str):
        root = FIXTURES / fixture
        return CHECKER.audit_project(root / "Sources", root / "Resources")

    def test_complete_fixture_inventories_explicit_and_swiftui_literals(self):
        result = self.audit("complete")

        self.assertEqual(result.issues, ())
        self.assertEqual(
            result.source_keys,
            {
                "Ready",
                "Welcome",
                "Profile",
                "Hello %@",
                "item-count",
                "Helper title",
                "External helper title",
                "Localization value helper title",
                "Names must be %lld UTF-8 bytes or fewer.",
                "Raw %@",
                "Multiline %@",
                "Explicit key",
                "Resource key",
            },
        )
        self.assertNotIn("Debug only", result.source_keys)
        self.assertEqual(
            {occurrence.surface for occurrence in result.occurrences},
            {
                "Text",
                "Label",
                "String(localized:)",
                "LocalizedStringKey",
                "LocalizedStringResource",
                "localizedRow",
                "externalLocalizedRow",
                "externalLocalizedValueRow",
            },
        )
        self.assertEqual(result.english_strings["Unicode A"], "Unicode A")

    def test_missing_source_key_is_a_deliberate_regression(self):
        issues = self.audit("missing_key").issues

        self.assertEqual(
            [(issue.code, issue.key) for issue in issues],
            [("source-key-missing-both", "Uncatalogued")],
        )

    def test_placeholder_mismatch_is_a_deliberate_regression(self):
        issues = self.audit("placeholder_mismatch").issues

        self.assertIn(
            ("placeholder-key-mismatch-es", "Hello %@"),
            [(issue.code, issue.key) for issue in issues],
        )

    def test_unknown_interpolation_fails_closed_and_typed_member_is_checked(self):
        result = self.audit("interpolation_adversarial")
        issue_pairs = {(issue.code, issue.key) for issue in result.issues}

        self.assertIn("Items %lld", result.source_keys)
        self.assertNotIn("Unknown %@", result.source_keys)
        self.assertIn(
            ("placeholder-key-mismatch-es", "Items %lld"),
            issue_pairs,
        )
        self.assertIn(
            (
                "unknown-localization-interpolation",
                "FixtureView.swift:model.opaqueMetric()#1",
            ),
            issue_pairs,
        )

    def test_identifier_and_duration_suffixes_preserve_swift_value_types(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            (source_root / "TypedSuffixes.swift").write_text(
                (
                    "import SwiftUI\n"
                    "struct Presentation {\n"
                    "    let durationLabel: String?\n"
                    "    let processIdentifier: pid_t\n"
                    "    let bundleIdentifier: String\n"
                    "}\n"
                    "struct TypedSuffixesView: View {\n"
                    "    let presentation: Presentation\n"
                    "    var body: some View {\n"
                    "        VStack {\n"
                    "            if let duration = presentation.durationLabel {\n"
                    '                Text("Duration \\(duration)")\n'
                    "            }\n"
                    '            Text("Process \\(presentation.processIdentifier)")\n'
                    '            Text("Bundle \\(presentation.bundleIdentifier)")\n'
                    "        }\n"
                    "    }\n"
                    "}\n"
                ),
                encoding="utf-8",
            )

            occurrences = CHECKER.source_inventory(source_root)

        self.assertEqual(
            {occurrence.key for occurrence in occurrences},
            {
                "Duration %@",
                "Process %d",
                "Bundle %@",
            },
        )

    def test_positional_reordering_is_safe_but_unpositioned_and_shape_changes_fail(self):
        issues = self.audit("placeholder_adversarial").issues
        issue_keys = {
            issue.key
            for issue in issues
            if issue.code.startswith("placeholder-key-mismatch")
        }

        self.assertNotIn("%@ has %lld items", issue_keys)
        self.assertEqual(
            issue_keys,
            {
                "Unsafe %@ %lld",
                "Wrong %@ %lld",
                "Added %@",
                "Removed %@ %lld",
            },
        )

    def test_plural_category_mismatch_is_a_deliberate_regression(self):
        issues = self.audit("plural_mismatch").issues
        issue_pairs = [(issue.code, issue.key) for issue in issues]

        self.assertIn(
            ("plural-category-mismatch", "item-count/count"),
            issue_pairs,
        )
        self.assertIn(
            ("plural-invalid-spec-type-es", "item-count/count"),
            issue_pairs,
        )

    def test_identically_malformed_plural_entries_fail_intrinsic_validation(self):
        issues = self.audit("plural_intrinsic_invalid").issues
        codes = {issue.code for issue in issues}

        for locale in ("en", "es"):
            self.assertTrue(
                {
                    f"plural-invalid-outer-format-{locale}",
                    f"plural-invalid-spec-type-{locale}",
                    f"plural-missing-value-type-{locale}",
                    f"plural-missing-variable-{locale}",
                    f"plural-unreferenced-variable-{locale}",
                    f"plural-nonstring-category-{locale}",
                    f"plural-placeholder-incompatible-{locale}",
                    f"plural-missing-reference-{locale}",
                }.issubset(codes)
            )

    def test_identical_bogus_plural_value_types_and_plain_categories_fail(self):
        issues = self.audit("plural_value_type_invalid").issues
        issue_pairs = {(issue.code, issue.key) for issue in issues}

        for locale in ("en", "es"):
            self.assertIn(
                (
                    f"plural-invalid-value-type-{locale}",
                    "bogus-count/count",
                ),
                issue_pairs,
            )
            self.assertIn(
                (
                    f"plural-placeholder-incompatible-{locale}",
                    "bogus-count/count/one",
                ),
                issue_pairs,
            )

    def test_live_localization_value_helper_literals_are_visible_and_accounted(self):
        repository = SCRIPT_ROOT.parent
        source_root = repository / "Sources" / "Parallax"
        resources_root = source_root / "Resources"
        key = "The library version is required."
        occurrences = CHECKER.source_inventory(source_root)
        dynamic = CHECKER.dynamic_localization_inventory(source_root)

        matching = [
            occurrence
            for occurrence in occurrences
            if occurrence.key == key
        ]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0].surface, "issue")
        expected_labeled_first = {
            "Views/StorageRelocationPreviewView.swift": {
                "Current",
                "New",
            },
            "Views/ProfileEditorView.swift": {
                "Launch Arguments",
                "Environment Inheritance",
                "Browsing & App Data",
                "Launch Preview",
            },
        }
        for path, expected in expected_labeled_first.items():
            actual = {
                occurrence.key
                for occurrence in occurrences
                if occurrence.path == path
                and occurrence.surface
                in {"pathRow", "advancedSettingsCard"}
            }
            self.assertTrue(expected.issubset(actual), (path, actual))
        self.assertFalse(
            any(
                occurrence.path == "Services/LibraryImportValidator.swift"
                and occurrence.expression == "detail"
                for occurrence in dynamic
            )
        )

        english, _ = CHECKER.parse_strings_catalog(
            resources_root / "en.lproj" / "Localizable.strings"
        )
        spanish, _ = CHECKER.parse_strings_catalog(
            resources_root / "es.lproj" / "Localizable.strings"
        )
        baseline = CHECKER.load_baseline(
            SCRIPT_ROOT / "localization_completeness_baseline.json"
        )
        accounted_keys = {key}.union(
            *expected_labeled_first.values()
        )
        for accounted_key in accounted_keys:
            if accounted_key in english and accounted_key in spanish:
                continue
            if accounted_key not in english and accounted_key not in spanish:
                code = "source-key-missing-both"
            elif accounted_key not in english:
                code = "source-key-missing-en"
            else:
                code = "source-key-missing-es"
            self.assertIn(f"{code}:{accounted_key}", baseline)

    def test_helper_discovery_supports_value_and_resource_parameter_types(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            (source_root / "Helpers.swift").write_text(
                (
                    "func valueRow(code: Int, detail: "
                    "String.LocalizationValue) {\n"
                    "    _ = String(localized: detail)\n"
                    "}\n"
                    "func resourceRow(_ resource: "
                    "String.LocalizationResource) {\n"
                    "    _ = String(localized: resource)\n"
                    "}\n"
                    "func firstLabelRow(title: "
                    "String.LocalizationValue) {\n"
                    "    _ = String(localized: title)\n"
                    "}\n"
                    "valueRow(code: 1, detail: \"Value literal\")\n"
                    "resourceRow(\"Resource literal\")\n"
                    "firstLabelRow(title: \"First labeled literal\")\n"
                ),
                encoding="utf-8",
            )

            occurrences = CHECKER.source_inventory(source_root)
            dynamic = CHECKER.dynamic_localization_inventory(source_root)

        self.assertEqual(
            {(item.key, item.surface) for item in occurrences},
            {
                ("Value literal", "valueRow"),
                ("Resource literal", "resourceRow"),
                ("First labeled literal", "firstLabelRow"),
            },
        )
        self.assertEqual(dynamic, ())

    def test_dynamic_string_localized_key_is_inventoried_as_unresolved_debt(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            (source_root / "Dynamic.swift").write_text(
                (
                    "let first = String(localized: runtimeKey)\n"
                    "let second = String(localized: runtimeKey)\n"
                ),
                encoding="utf-8",
            )
            occurrences = CHECKER.dynamic_localization_inventory(source_root)

        self.assertEqual(len(occurrences), 2)
        self.assertEqual(occurrences[0].path, "Dynamic.swift")
        self.assertEqual(occurrences[0].expression, "runtimeKey")
        self.assertEqual(occurrences[0].ordinal, 1)
        self.assertEqual(occurrences[1].ordinal, 2)

    def test_catalog_duplicates_locale_only_keys_and_kind_collisions_fail(self):
        issues = self.audit("catalog_structure").issues
        issue_pairs = {(issue.code, issue.key) for issue in issues}

        self.assertIn(("duplicate-catalog-key-en", "Duplicate"), issue_pairs)
        self.assertIn(("catalog-key-missing-es", "Duplicate"), issue_pairs)
        self.assertIn(("catalog-key-missing-es", "English only"), issue_pairs)
        self.assertIn(("catalog-key-missing-en", "Spanish only"), issue_pairs)
        self.assertIn(("catalog-key-kind-collision-en", "Collision"), issue_pairs)
        self.assertIn(("catalog-key-kind-collision-es", "Collision"), issue_pairs)

    def test_cli_allows_only_explicit_baseline_debt_and_rejects_new_debt(self):
        fixture = FIXTURES / "missing_key"
        result = self.audit("missing_key")
        fingerprint = result.issues[0].fingerprint

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = pathlib.Path(temporary_directory)
            allowed = temporary / "allowed.json"
            empty = temporary / "empty.json"
            stale = temporary / "stale.json"
            allowed.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "purpose": "fixture debt; not translation completion",
                        "allowed_issues": [fingerprint],
                    }
                ),
                encoding="utf-8",
            )
            empty.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "purpose": "no debt",
                        "allowed_issues": [],
                    }
                ),
                encoding="utf-8",
            )
            stale.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "purpose": "fixture debt plus a resolved entry",
                        "allowed_issues": [
                            fingerprint,
                            "source-key-missing-both:Resolved debt",
                        ],
                    }
                ),
                encoding="utf-8",
            )
            command = [
                sys.executable,
                str(CHECKER_PATH),
                "--source-root",
                str(fixture / "Sources"),
                "--resources-root",
                str(fixture / "Resources"),
            ]

            allowed_run = subprocess.run(
                command + ["--baseline", str(allowed)],
                check=False,
                capture_output=True,
                text=True,
            )
            rejected_run = subprocess.run(
                command + ["--baseline", str(empty)],
                check=False,
                capture_output=True,
                text=True,
            )
            stale_run = subprocess.run(
                command + ["--baseline", str(stale)],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(allowed_run.returncode, 0, allowed_run.stderr)
        self.assertIn("known debt=1, new issues=0", allowed_run.stdout)
        self.assertEqual(rejected_run.returncode, 1)
        self.assertIn(fingerprint, rejected_run.stderr)
        self.assertEqual(stale_run.returncode, 1)
        self.assertIn("stale baseline entries must be removed", stale_run.stderr)
        self.assertIn("Resolved debt", stale_run.stderr)


if __name__ == "__main__":
    unittest.main()
