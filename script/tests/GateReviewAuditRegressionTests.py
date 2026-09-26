"""Second-review regressions using disposable repositories and command fakes."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import unittest

import GateAuditRegressionTests as support

ROOT, LIB = support.ROOT, support.LIB


class GateReviewAuditRegressionTests(unittest.TestCase):
    setUp = support.GateAuditRegressionTests.setUp
    shell = support.GateAuditRegressionTests.shell
    repository = support.GateAuditRegressionTests.repository

    def fixture_packager(self):
        git = self.repository()
        shutil.copytree(ROOT / 'script', self.root / 'script')
        git('add', 'script')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'packager')
        return git

    def environment(self):
        return dict(os.environ, PARALLAX_BUILD_CACHE_ROOT=str(self.root / 'cache'),
                    PARALLAX_PACKAGING_LOCK_ROOT=str(self.root / 'locks'))

    def test_cold_packaging_link_requests_reproducibility(self):
        result = self.shell('''BUILD_CACHE_ROOT="$PWD/cache"
swift() {
  [[ " $* " == *" --help "* ]] && return 0
  [[ " $* " == *" -Xlinker -reproducible "* ]] || return 87
  echo "$PWD/bin"
}
build_slice arm64 release
''', 'app_assembly')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_compile_failure_does_not_claim_native_is_unavailable(self):
        result = self.shell('''BUILD_CACHE_ROOT="$PWD/cache"
swift() { [[ " $* " == *" --help "* ]] && return 0; echo 'fixture compile error' >&2; return 86; }
build_slice arm64 debug
''', 'app_assembly')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compilation failed', result.stderr)
        self.assertNotIn('requires a toolchain', result.stderr)
        self.assertNotIn('requires --build-system native', result.stderr)

    def test_dirty_release_does_not_create_cache_or_distribution(self):
        self.fixture_packager()
        (self.root / 'Sources/App.swift').write_text('uncommitted')
        result = subprocess.run([str(self.root / 'script/build_and_run.sh'), 'release',
                                 '--dist', str(self.root / 'output')], env=self.environment(),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('clean Git working tree', result.stderr)
        self.assertFalse((self.root / 'cache').exists())
        self.assertFalse((self.root / 'output').exists())

    def test_clean_release_missing_credentials_preserves_artifacts(self):
        self.fixture_packager()
        dist = self.root / 'dist'
        dist.mkdir()
        sentinel = dist / 'Parallax-9.9.9-999.zip'
        sentinel.write_bytes(b'known good')
        result = subprocess.run([str(self.root / 'script/build_and_run.sh'), 'release',
                                 '--version', '9.9.9', '--build', '999'],
                                env=dict(self.environment(), SIGN_IDENTITY=''), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('release requires --sign', result.stderr)
        self.assertEqual(sentinel.read_bytes(), b'known good')
        self.assertEqual(list(dist.iterdir()), [sentinel])
        self.assertFalse((self.root / 'cache').exists())

    def test_reexec_runs_validation_and_credential_preflight_once(self):
        git = self.fixture_packager()
        library = self.root / 'script/lib/build_and_run/input_and_tools.sh'
        library.write_text(library.read_text() + '''
validate_inputs() { echo validate >>"$ROOT_DIR/dist/invocations"; SOURCE_DATE_EPOCH=1234; }
preflight_tools() { echo tools >>"$ROOT_DIR/dist/invocations"; }
preflight_release_credentials() { echo credentials >>"$ROOT_DIR/dist/invocations"; }
''')
        assembly = self.root / 'script/lib/build_and_run/app_assembly.sh'
        assembly.write_text(assembly.read_text() + '\nassemble_app() { [[ "$SOURCE_DATE_EPOCH" == 1234 ]] || die lost-epoch; die fixture-stop; }\n')
        git('add', 'script')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'fake tools')
        # Keep the trace ignored so the clean-tree check stays meaningful.
        trace = self.root / 'dist/invocations'
        trace.parent.mkdir()
        self.addCleanup(lambda: trace.unlink(missing_ok=True))
        trace.unlink(missing_ok=True)
        result = subprocess.run([str(self.root / 'script/build_and_run.sh'), 'release'],
                                env=self.environment(), capture_output=True, text=True)
        self.assertIn('fixture-stop', result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ['validate', 'tools', 'credentials'])

    def test_distribution_lock_does_not_write_to_user_folder(self):
        cache, dist = self.root / 'cache', self.root / 'Downloads'
        cache.mkdir(); dist.mkdir()
        result = subprocess.run([sys.executable, str(LIB / 'packaging_lock.py'), str(cache), str(dist),
                                 sys.executable, '-c', 'pass'], env=self.environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(dist.iterdir()), [])

    def test_distribution_lock_excludes_a_different_checkout_cache(self):
        cache, dist = self.root / 'cache', self.root / 'Downloads'
        cache.mkdir(); dist.mkdir()
        other = self.root / 'other-cache'; other.mkdir()
        command = [sys.executable, str(LIB / 'packaging_lock.py')]
        owner = subprocess.Popen(command + [str(cache), str(dist), sys.executable, '-c',
                                 'import sys; print("ready", flush=True); sys.stdin.read()'],
                                 env=self.environment(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(owner.stdout.readline().strip(), 'ready')
            result = subprocess.run(command + [str(other), str(dist), sys.executable, '-c', 'pass'],
                                    env=self.environment(), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('another packaging invocation', result.stderr)
        finally:
            owner.kill(); owner.communicate()

    def test_user_application_is_refused_before_compilation(self):
        self.fixture_packager()
        dist = self.root / 'Downloads'
        app = dist / 'Parallax.app'; app.mkdir(parents=True)
        (app / 'sentinel').write_text('user owned')
        fake = self.root / 'bin'; fake.mkdir()
        (fake / 'swift').write_text('#!/bin/bash\necho compiler-was-invoked >&2; exit 86\n')
        (fake / 'swift').chmod(0o755)
        result = subprocess.run([str(self.root / 'script/build_and_run.sh'), 'build', '--dist', str(dist)],
                                env=dict(self.environment(), PATH=str(fake) + ':' + os.environ['PATH']),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not a verified packager output', result.stderr)
        self.assertNotIn('compiler-was-invoked', result.stderr)
        self.assertEqual((app / 'sentinel').read_text(), 'user owned')

    def packaged_app(self):
        self.repository()
        app = self.root / 'dist/Parallax.app'
        (app / 'Contents/Resources').mkdir(parents=True)
        revision = subprocess.check_output(['git', '-C', str(self.root), 'rev-parse', 'HEAD'], text=True).strip()
        info = {'CFBundleIdentifier': 'com.parallax.Parallax', 'CFBundleExecutable': 'Parallax',
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '14.0'}
        provenance = {'Application': 'Parallax', 'BundleIdentifier': 'com.parallax.Parallax',
                      'Version': '0.1.0', 'BuildNumber': '1', 'MinimumSystemVersion': '14.0',
                      'GitRevision': revision, 'SigningIdentity': 'adhoc'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/Resources/PackagingProvenance.plist').write_bytes(plistlib.dumps(provenance))
        return app

    def test_install_removes_only_owned_default_output(self):
        app = self.packaged_app()
        result = self.shell('''APP_NAME=Parallax; BUNDLE_ID=com.parallax.Parallax; PROVENANCE_FILE=PackagingProvenance.plist
INSTALL_DIR="$PWD/Applications"
unregister_local_app() { echo "$1" >"$PWD/unregistered"; }
remove_owned_default_app
''', 'artifact_distribution')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(app.exists())
        self.assertEqual((self.root / 'unregistered').read_text().strip(), str(app.resolve()))

    def test_mismatched_provenance_is_not_owned(self):
        app = self.packaged_app()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'another.app'}))
        result = self.shell('''APP_NAME=Parallax; BUNDLE_ID=com.parallax.Parallax; PROVENANCE_FILE=PackagingProvenance.plist
INSTALL_DIR="$PWD/Applications"
unregister_local_app() { exit 87; }
remove_owned_default_app
''', 'artifact_distribution')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(app.exists())

    def test_asan_check_and_unknown_reports_fail_even_when_child_exit_is_ignored(self):
        fake = self.root / 'bin'; fake.mkdir()
        for name in ('xcrun', 'xcodebuild'):
            path = fake / name; path.write_text('#!/bin/bash\necho fixture\n'); path.chmod(0o755)
        swift = fake / 'swift'
        for message in ('AddressSanitizer: CHECK failed', 'unclassified runtime diagnostic'):
            with self.subTest(message=message):
                swift.write_text('#!/bin/bash\nif [[ "$1" == test ]]; then printf "%s\\n" "$REPORT_TEXT" >"${ASAN_OPTIONS##*log_path=}.fixture"; fi\n')
                swift.chmod(0o755)
                result = subprocess.run([str(ROOT / 'script/run_sanitizer_tests.sh'), 'address', str(self.root / 'reports')],
                                        env=dict(self.environment(), PATH=str(fake) + ':/usr/bin:/bin', REPORT_TEXT=message),
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('diagnostic=1', result.stderr)

    def test_coverage_distinguishes_native_support_from_test_failure(self):
        fake = self.root / 'bin'; fake.mkdir()
        swift = fake / 'swift'; swift.touch(); swift.chmod(0o755)
        for supported in (False, True):
            with self.subTest(supported=supported):
                swift.write_text('#!/bin/bash\nif [[ " $* " == *" --help "* ]]; then exit ' +
                                 ('0' if supported else '64') + '; fi\necho test-failed >&2; exit 86\n')
                result = subprocess.run([str(ROOT / 'script/check_coverage.sh'), '--output-dir', str(self.root / 'coverage')],
                                        env=dict(self.environment(), PATH=str(fake) + ':' + os.environ['PATH']),
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                if supported:
                    self.assertIn('test execution or evidence capture failed', result.stderr)
                    self.assertNotIn('requires a SwiftPM toolchain', result.stderr)
                    self.assertIn('swift_test_exit_status=86', (self.root / 'coverage/test-status.txt').read_text())
                else:
                    self.assertIn('supporting --build-system native', result.stderr)
                    self.assertFalse((self.root / 'coverage/test-status.txt').exists())

    def test_owned_custom_output_can_be_replaced(self):
        app = self.packaged_app()
        stage = self.root / '.parallax-package.fixture'; stage.mkdir()
        (stage / 'Parallax.app').mkdir()
        (stage / 'Parallax.app/new').write_text('new')
        result = self.shell('''APP_NAME=Parallax; BUNDLE_ID=com.parallax.Parallax; MODE=build
STAGING_DIR="$PWD/.parallax-package.fixture"
publish_local_app "$STAGING_DIR/Parallax.app" "$PWD/dist/Parallax.app"
''', 'artifact_distribution')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((app / 'new').read_text(), 'new')
        self.assertFalse((stage / 'previous-Parallax.app').exists())

    def test_inherited_environment_cannot_skip_preflight(self):
        result = subprocess.run(['/bin/bash', '-c',
                                 'export PARALLAX_PACKAGING_LOCK_PID=$$; exec "$1" build --version invalid --dist "$2"',
                                 'fixture', str(ROOT / 'script/build_and_run.sh'), str(self.root / 'output')],
                                env=self.environment(), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('version must be semantic', result.stderr)
        self.assertFalse((self.root / 'cache').exists())
        self.assertFalse((self.root / 'output').exists())
