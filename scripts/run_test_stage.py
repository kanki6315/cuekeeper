#!/usr/bin/env python3
"""Stream an Xcode test stage, retain its raw log, and report quiet-worker progress."""
import argparse
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time


def debugger_notice(line):
    # Only this known Xcode metadata warning, never general debugger/test errors.
    prefix = '[MT] IDELaunchParametersSnapshot: '
    return 'xcodebuild[' in line and prefix in line and line.split(prefix, 1)[1].strip() in (
        "debugger version lookup failed for path '<nil>': noURL",
        'no debugger version',
    )


def run_stage(command, label, log_path, interval=15):
    log_path = Path(log_path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    next_update = started + interval
    print(f'[{label}] Starting. Full log: {log_path.resolve()}', flush=True)
    suppressed = 0

    def display(line):
        nonlocal suppressed
        text = line.decode('utf-8', errors='replace')
        if debugger_notice(text):
            suppressed += 1
            if suppressed == 1:
                print(f'[{label}] Xcode could not read debugger-version metadata; '
                      'repeated notices are retained in the full log. Tests are continuing.', flush=True)
        else:
            print(text, end='', flush=True)

    with log_path.open('wb') as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   env={**os.environ, 'NSUnbufferedIO': 'YES'}, start_new_session=True)
        previous_handlers = {}

        def interrupt(signum, _frame):
            raise KeyboardInterrupt

        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.signal(signum, interrupt)
        pending = b''
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    for key, _ in selector.select(max(0, next_update - time.monotonic())):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        log.write(chunk)
                        log.flush()
                        pending += chunk
                        while b'\n' in pending:
                            line, pending = pending.split(b'\n', 1)
                            display(line + b'\n')
                    if time.monotonic() >= next_update:
                        elapsed = int(time.monotonic() - started)
                        print(f'[{label}] Still running ({elapsed // 60}m {elapsed % 60:02d}s). '
                              'Parallel workers may report results only when they finish.', flush=True)
                        next_update = time.monotonic() + interval
                if pending:
                    display(pending)
            result = process.wait()
        except KeyboardInterrupt:
            os.killpg(process.pid, signal.SIGINT)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            print(f'\n[{label}] Interrupted. Full log: {log_path.resolve()}', flush=True)
            return 130
        finally:
            process.stdout.close()
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
    elapsed = int(time.monotonic() - started)
    status = 'PASSED' if result == 0 else f'FAILED (exit {result})'
    print(f'[{label}] {status} after {elapsed // 60}m {elapsed % 60:02d}s. '
          f'Full log: {log_path.resolve()}', flush=True)
    return result if result >= 0 else 128 - result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a command is required after --')
    return run_stage(command, args.label, args.log)


if __name__ == '__main__':
    raise SystemExit(main())
