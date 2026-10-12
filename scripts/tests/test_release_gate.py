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


if __name__ == '__main__':
    unittest.main()
