"""Check live progress, narrow warning filtering, and preservation of test failures."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('test_stage', Path(__file__).resolve().parents[1] / 'run_test_stage.py')
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)


class TestStageTests(unittest.TestCase):
    def test_quiet_worker_progress_and_failure_are_preserved(self):
        warning = "xcodebuild[1:2] [MT] IDELaunchParametersSnapshot: debugger version lookup failed for path '<nil>': noURL"
        other_error = 'xcodebuild[1:2] [MT] IDELaunchParametersSnapshot: debugger connection failed'
        code = ('import sys,time\n'
                'print("UI test started", flush=True)\n'
                f'print({warning!r}, file=sys.stderr, flush=True)\n'
                f'print({warning!r}, file=sys.stderr, flush=True)\n'
                'time.sleep(0.15)\n'
                f'print({other_error!r}, flush=True)\n'
                'print("UI assertion failed", flush=True)\n'
                'sys.exit(65)\n')
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'ui.log'
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = STAGE.run_stage([sys.executable, '-u', '-c', code], 'UI tests', log, interval=0.04)
            shown = output.getvalue()
            self.assertEqual(result, 65)
            self.assertIn('[UI tests] Still running', shown)
            self.assertIn('UI test started', shown)
            self.assertIn('UI assertion failed', shown)
            self.assertIn(other_error, shown)
            self.assertNotIn(warning, shown)
            self.assertEqual(shown.count('Xcode could not read debugger-version metadata'), 1)
            self.assertEqual(log.read_text().count(warning), 2)
            self.assertIn(other_error, log.read_text())
            self.assertIn('FAILED (exit 65)', shown)

    def test_success_and_final_line_without_newline(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'unit.log'
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = STAGE.run_stage([sys.executable, '-c', 'print("done", end="")'], 'Unit tests', log)
            self.assertEqual(result, 0)
            self.assertEqual(log.read_text(), 'done')
            self.assertIn('done', output.getvalue())
            self.assertIn('[Unit tests] PASSED', output.getvalue())


if __name__ == '__main__':
    unittest.main()
