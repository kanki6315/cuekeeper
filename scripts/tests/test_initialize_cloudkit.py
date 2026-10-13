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
