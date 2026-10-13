#!/usr/bin/env python3
"""Build and run the signed macOS Core Data schema helper (or an optional paired iOS device)."""
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


def initialize_mac(timeout=180):
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    output = ROOT / "build/cloudkit-initialize-mac"
    output.mkdir(parents=True, exist_ok=True)
    print("Building the signed macOS Development schema helper. This Mac must be signed into iCloud.", flush=True)
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT, env=env, check=True)
    with (output / "build.log").open("w") as log:
        subprocess.run([
            "xcodebuild", "build", "-project", "Cuekeeper.xcodeproj",
            "-scheme", "Cuekeeper - Mac CloudKit Setup", "-configuration", "CloudKitSetup",
            "-destination", "platform=macOS", "-derivedDataPath", str(output / "DerivedData"),
            "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
        ], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    executable = output / "DerivedData/Build/Products/CloudKitSetup/CuekeeperSchemaHelper.app/Contents/MacOS/CuekeeperSchemaHelper"
    # Run the signed app executable directly so exit status/output belong to this invocation.
    with (output / "initialize.log").open("w") as log:
        result = subprocess.run([str(executable), "--initialize-development-schema"],
                                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    transcript = (output / "initialize.log").read_text()
    if result.returncode or SUCCESS not in transcript.splitlines():
        raise RuntimeError("macOS initialization was not confirmed. Check build/cloudkit-initialize-mac/initialize.log "
                           "and this Mac's iCloud account.")
    print("Development schema initialized on this Mac.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Use the legacy iOS runner instead: paired device UDID or name")
    parser.add_argument("--export", action="store_true", help="Export Development only after confirmed initialization")
    parser.add_argument("--timeout", type=int, default=180, help="Initialization timeout in seconds (default: 180)")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    try:
        if args.device:
            initialize(args.device, args.timeout)
        else:
            initialize_mac(args.timeout)
        if args.export:
            subprocess.run([sys.executable, str(ROOT / "scripts/cloudkit_schema.py"), "export"], cwd=ROOT, check=True)
    except (subprocess.SubprocessError, OSError, RuntimeError) as error:
        print(f"CloudKit initialization failed: {error}\nLogs: build/cloudkit-initialize-mac/ (or build/cloudkit-initialize/ for --device)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
