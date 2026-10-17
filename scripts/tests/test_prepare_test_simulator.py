import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).resolve().parents[1] / 'prepare_test_simulator.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class SimulatorPreparationTests(unittest.TestCase):
    def inventory(self, devices=()):
        return {'devicetypes': [{'name': 'iPhone 18 Pro', 'identifier': 'phone-type',
                                 'minRuntimeVersionString': '27.0.0'}],
                'runtimes': [{'identifier': 'runtime.iOS-26-5', 'version': '26.5', 'isAvailable': True},
                             {'identifier': 'runtime.iOS-27-0', 'version': '27.0', 'isAvailable': True}],
                'devices': {'runtime.iOS-27-0': list(devices)}}

    def test_missing_device_created_on_compatible_runtime_and_booted(self):
        with patch.object(prepare.subprocess, 'check_output', side_effect=[json.dumps(self.inventory()), 'new-id\n']) as output, patch.object(prepare.subprocess, 'run') as run:
            result = prepare.prepare('platform=iOS Simulator,name=iPhone 18 Pro,OS=latest', '27.0')
        self.assertEqual(result, 'platform=iOS Simulator,id=new-id')
        self.assertEqual(output.call_args.args[0], ['xcrun', 'simctl', 'create', 'iPhone 18 Pro', 'phone-type', 'runtime.iOS-27-0'])
        self.assertEqual([c.args[0] for c in run.call_args_list], [
            ['xcrun', 'simctl', 'boot', 'new-id'], ['xcrun', 'simctl', 'bootstatus', 'new-id', '-b']])

    def test_booted_device_reused_without_creation_or_reboot(self):
        device = {'name': 'iPhone 18 Pro', 'udid': 'existing', 'state': 'Booted', 'isAvailable': True}
        with patch.object(prepare.subprocess, 'check_output', return_value=json.dumps(self.inventory([device]))) as output, patch.object(prepare.subprocess, 'run') as run:
            result = prepare.prepare('platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0', '27.0')
        self.assertIn('id=existing', result)
        self.assertEqual(output.call_count, 1)
        self.assertEqual(run.call_args.args[0], ['xcrun', 'simctl', 'bootstatus', 'existing', '-b'])
        self.assertEqual(run.call_count, 1)

    def test_incompatible_or_missing_runtime_fails_before_mutation(self):
        for requested in ['26.5', '28.0']:
            with self.subTest(requested=requested), patch.object(prepare.subprocess, 'check_output', return_value=json.dumps(self.inventory())) as output, patch.object(prepare.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'No installed compatible'):
                    prepare.prepare(f'platform=iOS Simulator,name=iPhone 18 Pro,OS={requested}', '27.0')
                self.assertEqual(output.call_count, 1)
                run.assert_not_called()

    def test_explicit_id_and_other_platforms_are_preserved(self):
        for destination in ['platform=iOS Simulator,id=my-device', 'platform=iOS,id=physical']:
            with patch.object(prepare.subprocess, 'check_output') as output:
                self.assertEqual(prepare.prepare(destination, '27.0'), destination)
                output.assert_not_called()
