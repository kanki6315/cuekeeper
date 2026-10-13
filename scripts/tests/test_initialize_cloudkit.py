import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("initialize_cloudkit", Path(__file__).resolve().parents[1] / "initialize_cloudkit.py")
initializer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(initializer)


class InitializerTests(unittest.TestCase):
    def run_initializer(self, output, code=0):
        with tempfile.TemporaryDirectory() as directory, patch.object(initializer, "ROOT", Path(directory)), patch.object(
            initializer.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output)
        ) as run:
            initializer.initialize("Test phone", 30)
            return run.call_args_list

    def test_requires_explicit_completion_marker(self):
        with self.assertRaises(RuntimeError):
            self.run_initializer("App launched successfully\n")

    def test_rejects_failure_exit_even_with_marker(self):
        with self.assertRaises(RuntimeError):
            self.run_initializer(initializer.SUCCESS + "\n", 1)

    def test_builds_setup_only_and_waits_for_completion(self):
        calls = self.run_initializer("Preparing schema\n" + initializer.SUCCESS + "\n")
        self.assertIn("CloudKitSetup", calls[1].args[0])
        self.assertIn("--device", calls[2].args[0])
        self.assertIn("--console", calls[3].args[0])
        self.assertEqual(calls[3].args[0][-1], "--cloudkit-schema-cli")
        self.assertEqual(calls[3].kwargs["timeout"], 45)

    def test_rejects_marker_embedded_in_other_output(self):
        with self.assertRaises(RuntimeError):
            self.run_initializer("Arguments contained " + initializer.SUCCESS)


class MacInitializerTests(unittest.TestCase):
    def run_mac(self, transcript, code=0):
        def command(args, **kwargs):
            if args[-1] == "--initialize-development-schema":
                kwargs["stdout"].write(transcript)
                return subprocess.CompletedProcess(args, code)
            return subprocess.CompletedProcess(args, 0)
        with tempfile.TemporaryDirectory() as directory, patch.object(initializer, "ROOT", Path(directory)), patch.object(
            initializer.subprocess, "run", side_effect=command
        ) as run:
            initializer.initialize_mac(30)
            return run.call_args_list

    def test_mac_uses_signed_helper_and_bounded_direct_launch(self):
        calls = self.run_mac(initializer.SUCCESS + "\n")
        self.assertIn("platform=macOS", calls[1].args[0])
        self.assertIn("-allowProvisioningDeviceRegistration", calls[1].args[0])
        self.assertIn("CuekeeperSchemaHelper.app/Contents/MacOS/", calls[2].args[0][0])
        self.assertEqual(calls[2].kwargs["timeout"], 30)
        self.assertFalse(any("devicectl" in call.args[0] for call in calls))

    def test_mac_rejects_launch_without_completion(self):
        with self.assertRaises(RuntimeError):
            self.run_mac("Started\n")

    def test_mac_rejects_nonzero_exit_with_marker(self):
        with self.assertRaises(RuntimeError):
            self.run_mac(initializer.SUCCESS + "\n", 1)

    def test_failed_initialization_never_exports(self):
        with patch.object(initializer.sys, "argv", ["initialize_cloudkit.py", "--export"]), patch.object(
            initializer, "initialize_mac", side_effect=RuntimeError("Unavailable")
        ), patch.object(initializer.subprocess, "run") as run:
            self.assertEqual(initializer.main(), 1)
            run.assert_not_called()

    def test_export_runs_after_successful_mac_initialization(self):
        events = []
        with patch.object(initializer.sys, "argv", ["initialize_cloudkit.py", "--export"]), patch.object(
            initializer, "initialize_mac", side_effect=lambda timeout: events.append("init")
        ), patch.object(initializer.subprocess, "run", side_effect=lambda *args, **kwargs: events.append("export")):
            self.assertEqual(initializer.main(), 0)
            self.assertEqual(events, ["init", "export"])
