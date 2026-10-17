#!/usr/bin/env bash
# Build and run the full balanced suite twice on four dedicated iOS simulators.
set -euo pipefail
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    cat <<'HELP'
Usage: ./benchmark.sh
Builds once, creates four iPhone 18 Pro / iOS 27 simulators, then runs the
full suite twice. The second run uses warmed devices and first-run timings.
Results and build files are retained under build/balanced.*. Only simulators
created by this invocation are removed on exit, including after failure.
Run while other worktrees are not testing. No release or upload is performed.
HELP
    exit 0
fi
[ "$#" = 0 ] || { echo 'Usage: ./benchmark.sh' >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build
run_dir="$(mktemp -d "$PWD/build/balanced.XXXXXX")"
derived="$run_dir/DerivedData"
devices=()
device_args=()
cleanup() {
    # Bash 3.2 needs the length guard with nounset and empty arrays.
    if [ "${#devices[@]}" -gt 0 ]; then
        for id in "${devices[@]}"; do
            xcrun simctl shutdown "$id" >/dev/null 2>&1 || true
            xcrun simctl delete "$id" >/dev/null 2>&1 || echo "Could not remove benchmark simulator $id" >&2
        done
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Benchmark artifacts: %s\n' "$run_dir"
xcodegen generate --quiet
xcodebuild build-for-testing \
    -project Cuekeeper.xcodeproj -scheme Cuekeeper \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
    > "$run_dir/build.log" 2>&1 || { cat "$run_dir/build.log" >&2; exit 1; }
shopt -s nullglob
test_runs=("$derived"/Build/Products/*.xctestrun)
[ "${#test_runs[@]}" = 1 ] || { echo 'Expected exactly one built .xctestrun file' >&2; exit 1; }
test_run="${test_runs[0]}"
app="$derived/Build/Products/Debug-iphonesimulator/Cuekeeper.app"
for worker in 1 2 3 4; do
    id="$(xcrun simctl create "Cuekeeper Balanced ${run_dir##*/} $worker" \
        com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro \
        com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
    devices+=("$id")
    printf '%s\n' "$id" >> "$run_dir/devices.txt"
    device_args+=(--device "$id")
    xcrun simctl boot "$id"
done
for id in "${devices[@]}"; do
    xcrun simctl bootstatus "$id" -b
    xcrun simctl install "$id" "$app"
    xcrun simctl privacy "$id" grant calendar com.arjunakankipati.cuekeeper
done
xcodebuild test-without-building -xctestrun "$test_run" \
    -destination "platform=iOS Simulator,id=${devices[0]}" \
    -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
    -test-enumeration-output-path "$run_dir/enumeration.json" \
    > "$run_dir/enumeration.log" 2>&1 || { cat "$run_dir/enumeration.log" >&2; exit 1; }
python3 scripts/benchmark_tests.py --xctestrun "$test_run" \
    --enumeration "$run_dir/enumeration.json" "${device_args[@]}" \
    --output "$run_dir/first"
python3 scripts/benchmark_tests.py --xctestrun "$test_run" \
    --enumeration "$run_dir/enumeration.json" "${device_args[@]}" \
    --timings "$run_dir/first/tests.json" --output "$run_dir/warm"
printf '\nWarmed results: %s/warm/summary.json\n' "$run_dir"
