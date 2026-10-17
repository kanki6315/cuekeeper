#!/usr/bin/env python3
"""Run one enumerated suite across explicit, already prepared simulator workers.

Build and enumerate first. This runner never creates, erases or deletes devices.
Each worker receives whole test classes; unit tests stay together on one worker.
It fails if results omit, duplicate or unexpectedly add any enabled test method.
"""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time


def inventory(document):
    if document.get("errors"):
        raise ValueError(f"Test enumeration failed: {document['errors']}")
    values = document["values"]
    if len(values) != 1:
        raise ValueError("Enumerate exactly one test configuration")
    # Xcode also enumerates helper classes with no methods; they execute no tests.
    methods = [row["identifier"] for row in values[0]["enabledTests"]
               if row["identifier"].count("/") == 2]
    if not methods or len(set(methods)) != len(methods):
        raise ValueError("Expected a nonempty, unique test-method inventory")
    return methods


def result_methods(document):
    rows = []
    def walk(node):
        if node.get("nodeType") == "Test Case":
            # test://bundle/scheme/target/class/method
            identifier = "/".join(node["nodeIdentifierURL"].split("/")[-3:])
            rows.append((identifier.removesuffix("()") + "()", node))
        for child in node.get("children", []):
            walk(child)
    for root in document["testNodes"]:
        walk(root)
    return rows


def partition(methods, timings, workers):
    groups = defaultdict(list)
    for method in methods:
        target, cls, _ = method.split("/")
        # UI classes reset independently; retain unit suite ordering/isolation.
        group = f"{target}/{cls}" if target.endswith("UITests") else target
        groups[group].append(method)
    estimates = {group: sum(timings.get(m, 25 if "UITests/" in m else .1)
                            for m in members) for group, members in groups.items()}
    shards = [{"selectors": [], "methods": [], "estimated_seconds": 0.0} for _ in range(workers)]
    for group in sorted(groups, key=lambda g: (-estimates[g], g)):
        shard = min(shards, key=lambda s: s["estimated_seconds"])
        shard["selectors"].append(group)
        shard["methods"].extend(groups[group])
        shard["estimated_seconds"] += estimates[group]
    assert Counter(m for s in shards for m in s["methods"]) == Counter(methods)
    return shards


def verify_inventory(expected, actual):
    missing = Counter(expected) - Counter(actual)
    extra = Counter(actual) - Counter(expected)
    if missing or extra:
        raise ValueError(f"Test coverage inventory mismatch: missing={dict(missing)}, extra={dict(extra)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--enumeration", type=Path, required=True)
    parser.add_argument("--timings", type=Path, help="xcresulttool get test-results tests JSON from a previous run")
    parser.add_argument("--device", action="append", required=True, help="Prepared simulator UDID; repeat once per worker")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if len(set(args.device)) != len(args.device):
        parser.error("Each worker needs a distinct simulator")
    methods = inventory(json.loads(args.enumeration.read_text()))
    timings = {m: n.get("durationInSeconds", 0) for m, n in result_methods(json.loads(args.timings.read_text()))} if args.timings else {}
    shards = partition(methods, timings, len(args.device))
    if any(not shard["selectors"] for shard in shards):
        parser.error("Use fewer devices: an empty selector list would run the entire suite")
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "plan.json").write_text(json.dumps(shards, indent=2) + "\n")
    def run(item):
        index, shard = item
        bundle = args.output / f"worker-{index}.xcresult"
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(args.xctestrun.resolve()),
                   "-destination", f"platform=iOS Simulator,id={args.device[index]}",
                   "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                   "-resultBundlePath", str(bundle.resolve())]
        command += [f"-only-testing:{selector}" for selector in shard["selectors"]]
        start = time.monotonic()
        with (args.output / f"worker-{index}.log").open("w") as log:
            process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        result = {"worker": index, "seconds": time.monotonic() - start,
                  "returncode": process.returncode, "command": command}
        print(json.dumps(result), flush=True)
        return result
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=len(shards)) as pool:
        results = list(pool.map(run, enumerate(shards)))
    elapsed = time.monotonic() - start
    rows = []
    nodes = []
    for index in range(len(shards)):
        data = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path",
                                        str(args.output / f"worker-{index}.xcresult")], text=True)
        (args.output / f"worker-{index}-tests.json").write_text(data)
        document = json.loads(data)
        rows.extend(result_methods(document))
        nodes.extend(document["testNodes"])
    (args.output / "tests.json").write_text(json.dumps({"testNodes": nodes}, indent=2) + "\n")
    summary = {"workers": results, "elapsed_seconds": elapsed,
               "counts": dict(Counter(n["result"] for _, n in rows))}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    verify_inventory(methods, [m for m, _ in rows])
    print(json.dumps(summary), flush=True)
    return int(any(r["returncode"] for r in results) or any(n["result"] not in {"Passed", "Skipped"} for _, n in rows))


if __name__ == "__main__":
    raise SystemExit(main())
