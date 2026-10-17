"""Exercise release orchestration with fake build/signing commands; never contacts Apple."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / "release.sh", self.root)
        shutil.copy(ROOT / "project.yml", self.root)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/cloudkit_schema.py").write_text('import sys\nsys.exit(42)\n')
        (self.root / "scripts/prepare_test_simulator.py").write_text(
            'import os, sys\n'
            'print("platform=iOS Simulator,id=prepared-device")\n'
            'sys.exit(int(os.environ.get("PREPARE_EXIT_CODE", "0")))\n')
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        commands = {
            "git": 'if [ "$1" = rev-parse ]; then case "$*" in *--verify*) exit 1;; *) echo abc123;; esac; fi',
            "xcodegen": 'exit 0',
            "xcodebuild": 'echo called >> "$BUILD_MARKER"',
        }
        for name, code in commands.items():
            path = bin_dir / name
            path.write_text('#!/bin/sh\n' + code + '\n')
            path.chmod(0o755)
        self.env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                    "DEVELOPER_DIR": str(self.root), "RELEASE_ENV_FILE": "/dev/null",
                    "ASC_KEY_ID": "", "BUILD_MARKER": str(self.root / "build-called")}

    def run_release(self, *arguments):
        return subprocess.run(['bash', str(self.root / 'release.sh'), '--skip-tests', *arguments],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_upload_cannot_bypass_schema_check(self):
        result = self.run_release('--skip-cloudkit-check')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('only allowed with --no-upload', result.stderr)
        self.assertFalse((self.root / 'build-called').exists())

    def test_schema_failure_stops_before_archive_even_with_skip_tests(self):
        for flags in [(), ('--no-upload',)]:
            with self.subTest(flags=flags):
                result = self.run_release(*flags)
                self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
                self.assertFalse((self.root / 'build-called').exists())

    def test_explicit_local_packaging_bypass_runs_build_without_upload(self):
        result = self.run_release('--no-upload', '--skip-cloudkit-check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'build-called').read_text().count('called'), 2)
        export = next((self.root / 'build/release').glob('*/ExportOptions.plist'))
        self.assertIn('<string>export</string>', export.read_text())
        self.assertIn('production readiness is unverified', result.stdout)

    def test_api_key_export_provisions_and_maps_both_targets(self):
        import json
        import plistlib

        key = self.root / "key.p8"
        key.write_text("test key")
        self.env.update(ASC_KEY_ID="KEY", ASC_ISSUER_ID="ISSUER", ASC_KEY_PATH=str(key))
        (self.root / "asc_profile.py").write_text(
            'import json, sys\n'
            'from pathlib import Path\n'
            'args = dict(zip(sys.argv[1::2], sys.argv[2::2]))\n'
            'with Path("profile-calls").open("a") as f: f.write(json.dumps(args) + "\\n")\n'
            'print(args["--name"])\n')
        result = self.run_release('--no-upload', '--skip-cloudkit-check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (self.root / "profile-calls").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        app, widget = calls
        self.assertEqual(app['--bundle-id'], 'com.arjunakankipati.cuekeeper')
        self.assertEqual(widget['--bundle-id'], 'com.arjunakankipati.cuekeeper.widgets')
        for call in calls:
            self.assertEqual(call['--app-group'], 'group.com.arjunakankipati.cuekeeper')
        self.assertIn('--cloudkit-container', app)
        self.assertNotIn('--cloudkit-container', widget)
        export = next((self.root / 'build/release').glob('*/ExportOptions.plist'))
        options = plistlib.loads(export.read_bytes())
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(options['provisioningProfiles'], {
            app['--bundle-id']: app['--name'], widget['--bundle-id']: widget['--name']})

    def test_simulator_preparation_failure_blocks_tests_and_archive(self):
        (self.root / "scripts/tests").mkdir()
        (self.root / "scripts/tests/test_placeholder.py").write_text(
            'import unittest\nclass Placeholder(unittest.TestCase):\n    def test_pass(self): pass\n')
        result = subprocess.run(
            ['bash', str(self.root / 'release.sh'), '--no-upload', '--skip-cloudkit-check'],
            cwd=self.root, env={**self.env, 'PREPARE_EXIT_CODE': '7'},
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertFalse((self.root / 'build-called').exists())

    def test_simulator_failure_still_blocks_archive_without_diagnostic_collection(self):
        (self.root / "scripts/tests").mkdir()
        (self.root / "scripts/tests/test_placeholder.py").write_text(
            'import unittest\n'
            'class Placeholder(unittest.TestCase):\n'
            '    def test_pass(self): pass\n')
        (self.root / "bin/xcodebuild").write_text(
            '#!/bin/sh\n'
            'echo "$*" >> "$BUILD_MARKER"\n'
            'if [ "$1" = test ]; then exit "${TEST_EXIT_CODE:-0}"; fi\n')
        marker = self.root / 'build-called'
        for exit_code in (0, 65):
            with self.subTest(exit_code=exit_code):
                marker.unlink(missing_ok=True)
                result = subprocess.run(
                    ['bash', str(self.root / 'release.sh'), '--no-upload', '--skip-cloudkit-check'],
                    cwd=self.root, env={**self.env, 'TEST_EXIT_CODE': str(exit_code)},
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
                calls = marker.read_text().splitlines()
                self.assertTrue(calls[0].startswith('test '))
                self.assertIn('-collect-test-diagnostics never', calls[0])
                self.assertIn('-destination platform=iOS Simulator,id=prepared-device', calls[0])
                self.assertEqual(len(calls), 3 if exit_code == 0 else 1)


if __name__ == '__main__':
    unittest.main()
