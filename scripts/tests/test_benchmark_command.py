"""Exercise the CLI orchestration without booting simulators or building Xcode."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BenchmarkCommandTests(unittest.TestCase):
    def run_benchmark(self, failure=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(ROOT / 'benchmark.sh', root)
            (root / 'scripts').mkdir()
            (root / 'bin').mkdir()
            fake = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
name=Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([name]+args)+'\\n')
if name == 'xcodebuild' and args[0] == 'build-for-testing':
 p=Path(args[args.index('-derivedDataPath')+1])/'Build/Products'
 p.mkdir(parents=True); (p/'suite.xctestrun').touch()
if name == 'xcrun' and args[1] == 'create': print('device-'+args[2].split()[-1])
if name == 'xcrun' and args[1:3] == ['boot', 'device-2'] and os.environ.get('FAIL') == 'boot': sys.exit(9)
if name == 'benchmark_tests.py':
 p=Path(args[args.index('--output')+1]); p.mkdir(); (p/'tests.json').write_text('{}')
 if p.name == os.environ.get('FAIL'): sys.exit(7)
'''
            for name in ['xcodegen', 'xcodebuild', 'xcrun']:
                path = root / 'bin' / name
                path.write_text(fake); path.chmod(0o755)
            (root / 'scripts/benchmark_tests.py').write_text(fake)
            result = subprocess.run(['bash', str(root / 'benchmark.sh')], cwd='/',
                env={**os.environ, 'PATH': str(root/'bin')+os.pathsep+os.environ['PATH'],
                     'CALLS': str(root/'calls'), 'FAIL': failure}, capture_output=True, text=True)
            calls = [json.loads(line) for line in (root/'calls').read_text().splitlines()]
            return result, calls

    def test_build_discover_and_two_runs_with_warm_timings(self):
        result, calls = self.run_benchmark()
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = [c for c in calls if c[0] == 'benchmark_tests.py']
        self.assertEqual(len(runs), 2)
        self.assertNotIn('--timings', runs[0])
        self.assertTrue(runs[1][runs[1].index('--timings')+1].endswith('/first/tests.json'))
        for run in runs:
            self.assertEqual([run[i+1] for i,v in enumerate(run) if v == '--device'], ['device-1','device-2','device-3','device-4'])
        self.assertEqual(sum(c[:2] == ['xcodebuild','build-for-testing'] for c in calls), 1)
        self.assertEqual(sum('-enumerate-tests' in c for c in calls), 1)
        self.assertEqual([c[-1] for c in calls if c[:3] == ['xcrun','simctl','delete']], ['device-1','device-2','device-3','device-4'])

    def test_failed_first_run_stops_and_cleans_up(self):
        result, calls = self.run_benchmark('first')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(sum(c[0] == 'benchmark_tests.py' for c in calls), 1)
        self.assertEqual(sum(c[:3] == ['xcrun','simctl','delete'] for c in calls), 4)

    def test_partial_preparation_failure_only_removes_created_devices(self):
        result, calls = self.run_benchmark('boot')
        self.assertEqual(result.returncode, 9)
        self.assertFalse(any(c[0] == 'benchmark_tests.py' for c in calls))
        self.assertEqual([c[-1] for c in calls if c[:3] == ['xcrun','simctl','delete']], ['device-1','device-2'])
