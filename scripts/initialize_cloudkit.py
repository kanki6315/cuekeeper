#!/usr/bin/env python3
"""Build and run Apple's Core Data schema initializer on a paired iOS device."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUCCESS = "CUEKEEPER_SCHEMA_INIT_OK"


def initialize(device, timeout=180):
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    output = ROOT / "build/cloudkit-initialize"
    output.mkdir(parents=True, exist_ok=True)
    print("Building the Development-only initializer. This replaces Cuekeeper on the selected device, "
          "but uses a separate local setup store. Keep the device unlocked and signed into iCloud.", flush=True)
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT, env=env, check=True)
    with (output / "build.log").open("w") as log:
        subprocess.run([
            "xcodebuild", "build", "-project", "Cuekeeper.xcodeproj",
            "-scheme", "Cuekeeper - Initialize CloudKit", "-configuration", "CloudKitSetup",
            "-destination", "generic/platform=iOS", "-derivedDataPath", str(output / "DerivedData"),
            "-allowProvisioningUpdates",
        ], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    app = output / "DerivedData/Build/Products/CloudKitSetup-iphoneos/Cuekeeper.app"
    subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", device, str(app)],
                   cwd=ROOT, env=env, check=True)
    result = subprocess.run([
        "xcrun", "devicectl", "device", "process", "launch", "--device", device,
        "--terminate-existing", "--console", "--timeout", str(timeout),
        "com.arjunakankipati.cuekeeper", "--cloudkit-schema-cli",
    ], cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        timeout=timeout + 15)
    (output / "initialize.log").write_text(result.stdout)
    print(result.stdout, end="", flush=True)
    # Device launch success alone is not schema initialization success.
    if result.returncode or SUCCESS not in result.stdout.splitlines():
        raise RuntimeError("Initialization was not confirmed. Check build/cloudkit-initialize/initialize.log, "
                           "unlock the device, verify its iCloud account, and try again.")
    print("Development schema initialized. Next: ./cloudkit.sh export")
    print("Return to the ordinary Cuekeeper build or reinstall the TestFlight build afterward.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Paired device UDID or name from xcrun devicectl list devices")
    parser.add_argument("--timeout", type=int, default=180, help="Initialization timeout in seconds (default: 180)")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    try:
        initialize(args.device, args.timeout)
    except (subprocess.SubprocessError, OSError, RuntimeError) as error:
        print(f"CloudKit initialization failed: {error}\nBuild log: build/cloudkit-initialize/build.log", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
