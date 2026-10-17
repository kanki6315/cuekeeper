import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("benchmark_tests", Path(__file__).resolve().parents[1] / "benchmark_tests.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class BenchmarkTests(unittest.TestCase):
    def test_inventory_excludes_disabled_methods_and_empty_helper_classes(self):
        document = {"values": [{"enabledTests": [{"identifier": "AppUITests/Helper"},
                    {"identifier": "AppUITests/Editor/testSave()"}],
                    "disabledTests": [{"identifier": "AppUITests/Captures/testScreen()"}]}]}
        self.assertEqual(benchmark.inventory(document), ["AppUITests/Editor/testSave()"])

    def test_partition_preserves_all_methods_and_keeps_classes_and_units_together(self):
        methods = ["AppUITests/Slow/testA()", "AppUITests/Slow/testB()", "AppUITests/Fast/testC()",
                   "AppTests/First/testD()", "AppTests/Second/testE()"]
        shards = benchmark.partition(methods, {methods[0]: 40, methods[1]: 40}, 4)
        benchmark.verify_inventory(methods, [m for s in shards for m in s["methods"]])
        self.assertTrue(any(set(methods[:2]).issubset(s["methods"]) for s in shards))
        self.assertTrue(any(set(methods[3:]).issubset(s["methods"]) for s in shards))

    def test_results_cannot_silently_omit_or_duplicate_tests(self):
        for actual in [["a"], ["a", "b", "b"], ["a", "c"]]:
            with self.assertRaises(ValueError):
                benchmark.verify_inventory(["a", "b"], actual)
