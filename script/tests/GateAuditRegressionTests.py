"""Synthetic script regressions; never install, sign, or launch an application."""
import os
import pathlib
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB = ROOT / 'script/lib/build_and_run'


class GateAuditRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='parallax-gate-audit-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        environment = mock.patch.dict(os.environ, {
            'PARALLAX_BUILD_CACHE_ROOT': str(self.root / 'cache'),
            'PARALLAX_PACKAGING_LOCK_ROOT': str(self.root / 'locks')})
        environment.start()
        self.addCleanup(environment.stop)

    def shell(self, body, library='input_and_tools', replacements=None, signal_defaults=()):
        source = (LIB / (library + '.sh')).read_text()
        for before, after in (replacements or {}).items():
            source = source.replace(before, after)
        handle = tempfile.NamedTemporaryFile(suffix='.sh', delete=False)
        handle.close()
        script = pathlib.Path(handle.name)
        self.addCleanup(script.unlink)
        script.write_text('set -euo pipefail\nROOT_DIR="$PWD"\nBUILD_SCRIPT_LIB_DIR=' + repr(str(LIB)) + '\ndie() { echo "Error: $*" >&2; exit 1; }\n' + source + '\n' + body)
        def reset_signals():
            for number in signal_defaults:
                signal.signal(number, signal.SIG_DFL)
        return subprocess.run(['/bin/bash', str(script)], cwd=self.root,
                              capture_output=True, text=True,
                              preexec_fn=reset_signals if signal_defaults else None)

    def repository(self):
        def git(*args):
            subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True)
        git('init', '-q', '--initial-branch=master')
        (self.root / 'Sources').mkdir()
        (self.root / 'Sources/App.swift').write_text('let value = 1\n')
        (self.root / 'Package.swift').write_text('// fixture\n')
        (self.root / '.gitignore').write_text('dist/\n')
        git('add', '.')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'fixture')
        return git

    def test_release_ignores_inputs_excluded_from_snapshot(self):
        self.repository()
        (self.root / 'Sources/dist').mkdir()
        (self.root / 'Sources/dist/Injected.swift').write_text('let injected = 1')
        (self.root / '.git/info/exclude').write_text('.DS_Store\n')
        (self.root / 'Sources/.DS_Store').write_bytes(b'Finder metadata')
        result = self.shell('ROOT_DIR="$PWD"; require_clean_release_tree')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_detects_index_visibility_flags(self):
        git = self.repository()
        for flag in ('--skip-worktree', '--assume-unchanged'):
            git('update-index', flag, 'Sources/App.swift')
            self.assertNotEqual(self.shell('ROOT_DIR="$PWD"; require_clean_release_tree').returncode, 0)
            git('update-index', '--no-skip-worktree', '--no-assume-unchanged', 'Sources/App.swift')

    def test_committed_staged_and_unstaged_whitespace(self):
        git = self.repository()
        git('update-ref', 'refs/remotes/origin/master', 'HEAD')
        git('config', 'branch.master.remote', 'origin')
        git('config', 'branch.master.merge', 'refs/heads/master')
        git('config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
        path = self.root / 'Sources/App.swift'
        for state in ('unstaged', 'staged', 'committed'):
            path.write_text('let value = 2   \n')
            if state != 'unstaged':
                git('add', '.')
            if state == 'committed':
                git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'whitespace')
            result = subprocess.run(['python3', str(ROOT / 'script/check_git_state.py'), '--diff-check', str(self.root)], capture_output=True)
            self.assertEqual(result.returncode, 1, (state, result.stderr))

    def test_whitespace_without_base_fails_closed(self):
        self.repository()
        result = subprocess.run(['python3', str(ROOT / 'script/check_git_state.py'), '--diff-check', str(self.root)], capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_native_build_layout_is_explicit(self):
        result = self.shell('''
BUILD_CACHE_ROOT="$PWD/cache"
swift() { [[ " $* " == *" --build-system native "* ]] || return 87; echo "$PWD/bin"; }
build_slice arm64 debug
''', 'app_assembly')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unsupported_native_build_system_is_clear(self):
        result = self.shell('''
BUILD_CACHE_ROOT="$PWD/cache"
swift() { echo 'error: unknown option --build-system' >&2; return 1; }
build_slice arm64 debug
''', 'app_assembly')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('native', result.stderr)

    def test_empty_and_undocumented_modes_rejected_before_tools(self):
        for mode in ('', '--debug', '--logs', '--telemetry'):
            source = (ROOT / 'script/build_and_run.sh').read_text().split('if [[ "$MODE" == "verify" ]]; then')[0]
            source = source.replace('ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"', 'ROOT_DIR=' + repr(str(ROOT)))
            result = subprocess.run(['/bin/bash', '-c', source + '\nexit 0', 'fixture', mode], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unknown mode', result.stderr)

    def test_signature_identifier_requires_exact_field(self):
        result = self.shell('''
fake_codesign() { if [[ "$1" == -d ]]; then printf '%s\n' 'Identifier=com.parallax.Parallax.untrusted' 'flags=runtime' 'TeamIdentifier=not set'; fi; }
verify_code_signature fixture local com.parallax.Parallax '' 0
''', 'artifact_verification', {'/usr/bin/codesign': 'fake_codesign'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('identifier', result.stderr)

    def test_identity_preflight_requires_exact_name_or_hash(self):
        result = self.shell('''
SIGN_IDENTITY='Developer ID Application: Fixture'; NOTARIZE=1; STAPLE=1; NOTARY_PROFILE=fixture
require_tool() { :; }
fake_security() { echo '  1) ABCDEF "Developer ID Application: Fixture Untrusted"'; }
fake_xcrun() { :; }
preflight_release_credentials
''', replacements={'/usr/bin/security': 'fake_security', '/usr/bin/xcrun': 'fake_xcrun'})
        self.assertNotEqual(result.returncode, 0)

    def test_gatekeeper_disabled_is_not_signed_evidence(self):
        result = self.shell('''
fake_codesign() { if [[ "$1" == -d ]]; then printf '%s\n' 'Identifier=com.parallax.Parallax' 'flags=runtime' 'TeamIdentifier=FIXTURE'; fi; }
fake_spctl() { echo 'assessments disabled'; }
verify_code_signature fixture signed com.parallax.Parallax FIXTURE 0
''', 'artifact_verification', {'/usr/bin/codesign': 'fake_codesign', '/usr/sbin/spctl': 'fake_spctl'})
        self.assertNotEqual(result.returncode, 0)

    def test_timestamp_normalization_is_utc(self):
        path = self.root / 'entry'
        path.write_text('fixture')
        result = self.shell('export TZ=America/New_York; SOURCE_DATE_EPOCH=1710037800; normalize_tree_timestamps "$PWD/entry"', 'artifact_distribution')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(path.stat().st_mtime), 1710037800)

    def test_inventory_find_failure_is_rejected(self):
        app = self.root / 'Parallax.app'
        (app / 'Contents').mkdir(parents=True)
        app.chmod(0o755)
        (app / 'Contents').chmod(0o755)
        result = self.shell('fake_find() { printf "%s\\0" "$PWD/Parallax.app/Contents"; return 73; }; verify_application_inventory "$PWD/Parallax.app" 0',
                            'artifact_verification', {'/usr/bin/find': 'fake_find'})
        self.assertNotEqual(result.returncode, 0)

    def test_partial_publication_restores_previous_before_staging_cleanup(self):
        stage = self.root / '.parallax-package.fixture'
        stage.mkdir()
        (stage / 'previous-Parallax.app').mkdir()
        (stage / 'previous-Parallax.app/old').write_text('previous')
        result = self.shell('''
STAGING_DIR="$PWD/.parallax-package.fixture"; APP_NAME=Parallax
LOCAL_APP_BACKUP="$STAGING_DIR/previous-Parallax.app"; LOCAL_APP_DESTINATION="$PWD/Parallax.app"
LOCAL_APP_PUBLISHED=0; MOUNT_POINT=""
PUBLISH_COMMITTED=0; PUBLISHED_DESTINATIONS=(); PUBLISHED_SOURCES=()
trap cleanup EXIT
exit 143
''', 'app_assembly')
        self.assertEqual(result.returncode, 143)
        self.assertTrue((self.root / 'Parallax.app/old').exists())

    def test_secret_scan_is_relative_even_under_dist(self):
        root = self.root / 'dist/checkout'
        (root / 'script').mkdir(parents=True)
        for name in ('run_secret_scan.sh', 'gitleaks.toml'):
            (root / 'script' / name).write_bytes((ROOT / 'script' / name).read_bytes())
        scanner = self.root / 'scanner'
        scanner.write_text("""#!/bin/bash
if [[ "$1" == version ]]; then echo 8.30.1; exit 0; fi
location="$2"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --report-path ]]; then echo '[]' >"$2"; fi
  shift
done
if [[ "$location" == *canary* ]]; then exit 1; fi
[[ "$location" == . ]] || exit 99
""")
        scanner.chmod(0o755)
        result = subprocess.run(['/bin/bash', str(root / 'script/run_secret_scan.sh')],
                                env=dict(os.environ, GITLEAKS_BIN=str(scanner)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rehearsal_rejects_downgrade_and_mismatched_bundle(self):
        import plistlib
        paths = [self.root / name for name in ('previous.app', 'candidate.app')]
        for path in paths:
            (path / 'Contents').mkdir(parents=True)
        def write(path, version, build, identifier):
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleShortVersionString': version, 'CFBundleVersion': build,
                'CFBundleIdentifier': identifier}))
        write(paths[0], '2.0.0', '2', 'com.parallax.Parallax')
        for version, build, identifier in [('1.0.0', '9', 'com.parallax.Parallax'),
                                            ('3.0.0', '3', 'com.untrusted.App')]:
            write(paths[1], version, build, identifier)
            result = subprocess.run(['python3', str(ROOT / 'script/lib/rehearsal_support.py'),
                                     'upgrade', *map(str, paths)], capture_output=True)
            self.assertEqual(result.returncode, 1, result.stderr)

    def test_rollback_fingerprint_includes_modes_links_and_empty_directories(self):
        tree = self.root / 'app'
        tree.mkdir()
        executable = tree / 'binary'
        executable.write_text('same bytes')
        def fingerprint():
            return subprocess.check_output(['python3', str(ROOT / 'script/lib/rehearsal_support.py'), 'hash', str(tree)])
        before = fingerprint()
        executable.chmod(0o755)
        self.assertNotEqual(fingerprint(), before)
        before = fingerprint()
        (tree / 'empty').mkdir()
        self.assertNotEqual(fingerprint(), before)
        before = fingerprint()
        (tree / 'link').symlink_to('binary')
        self.assertNotEqual(fingerprint(), before)

    def test_packaging_signals_exit_nonzero(self):
        source = (ROOT / 'script/build_and_run.sh').read_text()
        traps = '\n'.join(line for line in source.splitlines() if line.startswith('trap '))
        for name, status in [('HUP', 129), ('INT', 130), ('TERM', 143)]:
            with self.subTest(signal=name):
                result = self.shell('MOUNT_POINT=""; STAGING_DIR=""\n' + traps +
                                    '\nkill -' + name + ' $$\necho continued', 'app_assembly',
                                    signal_defaults=(signal.SIGHUP, signal.SIGINT))
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertNotIn('continued', result.stdout)

    def test_rehearsal_signal_cannot_report_success(self):
        source = (ROOT / 'script/rehearse_install_upgrade_rollback.sh').read_text()
        traps = 'trap cleanup EXIT' + source.split('trap cleanup EXIT', 1)[1].split('materialize_app()', 1)[0]
        result = self.shell('cleanup() { :; }; ' + traps + '\nkill -TERM $$\necho continued')
        self.assertEqual(result.returncode, 143)
        self.assertNotIn('continued', result.stdout)

    def test_address_sanitizer_report_from_ignored_child_fails_lane(self):
        fake = self.root / 'bin'
        fake.mkdir()
        for command, body in {
            'swift': 'if [[ "$1" == test ]]; then echo "ERROR: AddressSanitizer: heap-use-after-free" >"${ASAN_OPTIONS##*log_path=}.fixture"; fi; exit 0',
            'xcodebuild': 'echo fixture', 'xcrun': 'echo fixture'
        }.items():
            path = fake / command
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o755)
        result = subprocess.run([str(ROOT / 'script/run_sanitizer_tests.sh'), 'address', str(self.root / 'reports')],
                                env=dict(os.environ, PATH=str(fake) + ':/usr/bin:/bin'), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('diagnostic=1', result.stderr)

    def test_kernel_locks_exclude_contenders_and_release_after_kill(self):
        import sys
        cache, dist = self.root / 'cache', self.root / 'dist'
        cache.mkdir()
        dist.mkdir()
        helper = str(LIB / 'packaging_lock.py')
        command = ['python3', helper, str(cache), str(dist), sys.executable, '-c']
        owner = subprocess.Popen(command + ['import sys; print("ready", flush=True); sys.stdin.read()'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(owner.stdout.readline().strip(), 'ready')
            contender = subprocess.run(command + ['pass'], capture_output=True, text=True)
            self.assertNotEqual(contender.returncode, 0)
            self.assertIn('another packaging invocation', contender.stderr)
        finally:
            owner.kill()
            owner.communicate()
        self.assertEqual(subprocess.run(command + ['pass'], capture_output=True).returncode, 0)

    def test_clean_repository_passes_even_when_untracked_display_is_disabled(self):
        git = self.repository()
        git('config', 'status.showUntrackedFiles', 'no')
        self.assertEqual(self.shell('require_clean_release_tree').returncode, 0)
        (self.root / 'untracked').write_text('must be detected')
        self.assertNotEqual(self.shell('require_clean_release_tree').returncode, 0)

    def test_release_ignores_info_exclude_input_absent_from_snapshot(self):
        self.repository()
        (self.root / '.git/info/exclude').write_text('Sources/hidden.swift\n')
        (self.root / 'Sources/hidden.swift').write_text('let hidden = 1')
        self.assertEqual(self.shell('require_clean_release_tree').returncode, 0)

    def test_existing_dist_is_not_marked_or_deleted_on_failed_build(self):
        dist = self.root / 'Downloads'
        (dist / 'Parallax.app').mkdir(parents=True)
        (dist / 'Parallax.app/sentinel').write_text('user-owned')
        fake = self.root / 'bin'
        fake.mkdir()
        (fake / 'swift').write_text('#!/bin/bash\nexit 86\n')
        (fake / 'swift').chmod(0o755)
        result = subprocess.run([str(ROOT / 'script/build_and_run.sh'), 'build', '--dist', str(dist)],
                                env=dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'],
                                         PARALLAX_BUILD_CACHE_ROOT=str(self.root / 'cache')), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((dist / '.metadata_never_index').exists())
        self.assertEqual((dist / 'Parallax.app/sentinel').read_text(), 'user-owned')

    def test_dist_alias_of_install_directory_is_rejected(self):
        install = self.root / 'Applications'
        install.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(install, target_is_directory=True)
        result = subprocess.run([str(ROOT / 'script/build_and_run.sh'), 'build', '--dist', str(alias),
                                 '--install-dir', str(install)],
                                env=dict(os.environ, PARALLAX_BUILD_CACHE_ROOT=str(self.root / 'cache')), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('distribution directory cannot be the installation directory', result.stderr)
        self.assertEqual(list(install.iterdir()), [])

    def test_install_preserves_existing_dist_application(self):
        source = (ROOT / 'script/build_and_run.sh').read_text()
        branch = source[source.index('if [[ "$MODE" == "build" || "$MODE" == "install"'):source.index('normalize_tree_timestamps "$STAGED_APP"')]
        dist = self.root / 'dist'
        (dist / 'Parallax.app').mkdir(parents=True)
        sentinel = dist / 'Parallax.app/sentinel'
        sentinel.write_text('previous output')
        result = self.shell('''MODE=install; APP_NAME=Parallax; BUNDLE_ID=com.parallax.Parallax; DIST_DIR="$PWD/dist"; INSTALL_DIR="$PWD/Applications"; STAGED_APP=fixture
prepare_install_directory() { :; }
stop_running_local_app() { :; }
register_local_app() { :; }
unregister_local_app() { :; }
publish_local_app() { :; }
''' + branch, 'artifact_distribution')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sentinel.read_text(), 'previous output')

    def test_release_compiles_committed_snapshot(self):
        self.repository()
        (self.root / 'Sources/dist').mkdir()
        (self.root / 'Sources/dist/ignored.swift').write_text('excluded source')
        source = (ROOT / 'script/build_and_run.sh').read_text()
        snapshot = source[source.index('if [[ "$MODE" == "release" ]]; then\n  RELEASE_REVISION='):source.index('STAGED_APP="$STAGING_DIR/$APP_NAME.app"')]
        stage = self.root / '.stage'
        stage.mkdir()
        result = self.shell('MODE=release; ROOT_DIR="$PWD"; STAGING_DIR="$PWD/.stage"\n' + snapshot)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((stage / 'source/Sources/dist').exists())
        (self.root / 'Sources/App.swift').write_text('uncommitted replacement')
        self.assertEqual((stage / 'source/Sources/App.swift').read_text(), 'let value = 1\n')

    def test_release_forwards_required_team_to_verifier(self):
        source = (ROOT / 'script/build_and_run.sh').read_text()
        call = source[source.index("\nverify_app "):source.index('if [[ "$MODE" == "build" || "$MODE" == "install"')]
        result = self.shell('''STAGED_APP=fixture; APP_EXPECTATION=signed; ARCHITECTURE=native; BUNDLE_ID=com.parallax.Parallax
EXPECTED_TEAM_ID=EXPECTED; APP_NOTARIZED=1
verify_app() { [[ "$5" == EXPECTED ]]; }
''' + call)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_signal_preserves_backup_and_status_when_restoration_is_ambiguous(self):
        stage = self.root / '.parallax-package.fixture'
        stage.mkdir()
        (stage / 'previous-Parallax.app').mkdir()
        (stage / 'previous-Parallax.app/old').write_text('old')
        (self.root / 'Parallax.app').mkdir()
        (self.root / 'Parallax.app/new').write_text('new')
        result = self.shell('''STAGING_DIR="$PWD/.parallax-package.fixture"; LOCAL_APP_PUBLISHED=0
LOCAL_APP_BACKUP="$STAGING_DIR/previous-Parallax.app"; LOCAL_APP_DESTINATION="$PWD/Parallax.app"
MOUNT_POINT=""; PUBLISH_COMMITTED=0
trap cleanup EXIT
exit 143
''', 'app_assembly')
        self.assertEqual(result.returncode, 143)
        self.assertEqual((stage / 'previous-Parallax.app/old').read_text(), 'old')
        self.assertEqual((self.root / 'Parallax.app/new').read_text(), 'new')

    def test_packaging_contract_checks_syntax_of_each_library(self):
        libraries = self.root / 'libraries'
        libraries.mkdir()
        (libraries / 'broken.sh').write_text('if then\n')
        source = (ROOT / 'script/test_build_and_run.sh').read_text()
        function = source[source.index('test_shell_syntax_and_mode_contract()'):source.index('test_release_preflight_preserves_existing_artifacts()')]
        result = self.shell('PACKAGER=' + repr(str(ROOT / 'script/build_and_run.sh')) + '\n' +
                            'PACKAGER_LIB_DIR="$PWD/libraries"\npass() { :; }\nassert_contains() { :; }\n' +
                            function + '\ntest_shell_syntax_and_mode_contract')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('syntax error', result.stderr)

    def test_universal_assembly_preserves_cache_paths_with_spaces(self):
        for architecture in ('arm64', 'x86_64'):
            product = self.root / 'cache with spaces' / architecture
            bundle = product / 'Parallax_Parallax.bundle'
            bundle.mkdir(parents=True)
            (bundle / 'AppIcon.icns').write_text('icon')
            for language in ('en',):
                (bundle / f'{language}.lproj').mkdir()
                for catalog in ('Localizable.strings', 'Localizable.stringsdict'):
                    (bundle / f'{language}.lproj' / catalog).write_text(language + catalog)
            (product / 'Parallax').write_text('binary')
            (product / 'Parallax').chmod(0o755)
        result = self.shell('''APP_NAME=Parallax; ARCHITECTURE=universal; CONFIGURATION=debug
RESOURCE_BUNDLE_NAME=Parallax_Parallax.bundle; ICON_FILE=AppIcon.icns; PROVENANCE_FILE=provenance
requested_architectures() { echo 'arm64 x86_64'; }
build_slice() { echo "$PWD/cache with spaces/$1"; }
fake_lipo() { [[ "$#" -eq 5 ]] || return 86; /bin/cp "$2" "$5"; }
write_info_plist() { :; }
write_provenance() { :; }
verify_deployment_target() { :; }
assemble_app "$PWD/app"
''', 'app_assembly', {'/usr/bin/lipo': 'fake_lipo'})
        self.assertEqual(result.returncode, 0, result.stderr)
        for language in ('en',):
            for catalog in ('Localizable.strings', 'Localizable.stringsdict'):
                self.assertEqual((self.root / 'app/Contents/Resources' / f'{language}.lproj' / catalog).read_text(), language + catalog)

    def test_main_bundle_declares_english_only(self):
        result = self.shell('APP_NAME=Parallax; BUNDLE_ID=com.fixture; VERSION=1; BUILD_NUMBER=1; MIN_SYSTEM_VERSION=14.0; write_info_plist "$PWD/Info.plist"', 'app_assembly')
        self.assertEqual(result.returncode, 0, result.stderr)
        import plistlib
        self.assertEqual(plistlib.loads((self.root / 'Info.plist').read_bytes())['CFBundleLocalizations'], ['en'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
