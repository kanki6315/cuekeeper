#!/usr/bin/env python3
"""Resolve a named iOS test destination, creating its simulator when missing."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def version(value):
    parts = tuple(int(p) for p in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def prepare(destination, minimum):
    fields = dict(part.strip().split('=', 1) for part in destination.split(','))
    # Explicit IDs and other platforms retain xcodebuild's destination semantics.
    if fields.get('platform') != 'iOS Simulator' or 'id' in fields:
        return destination
    name = fields.get('name')
    if not name:
        raise ValueError('An iOS Simulator destination needs name= or id=.')
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json'], text=True))
    device_type = next((d for d in inventory['devicetypes'] if d['name'] == name), None)
    requested = fields.get('OS', 'latest')
    runtimes = [r for r in inventory['runtimes']
                if r.get('isAvailable') and '.iOS-' in r['identifier']
                and version(r['version']) >= version(minimum)
                and (requested == 'latest' or version(r['version']) == version(requested))]
    if device_type:
        runtimes = [r for r in runtimes
                    if version(device_type.get('minRuntimeVersionString', '0')) <= version(r['version'])
                    <= version(device_type.get('maxRuntimeVersionString', '65535'))]
    if not runtimes:
        raise ValueError(f'No installed compatible iOS simulator runtime for {name} (OS={requested}, minimum {minimum}). Install it in Xcode Settings > Components.')
    runtime = max(runtimes, key=lambda r: version(r['version']))
    devices = inventory['devices'].get(runtime['identifier'], [])
    matches = [d for d in devices if d.get('isAvailable') and d['name'] == name]
    if matches:
        device = sorted(matches, key=lambda d: (d['state'] != 'Booted', d['udid']))[0]
        udid = device['udid']
        booted = device['state'] == 'Booted'
        print(f'Reusing {name} on iOS {runtime["version"]}: {udid}', file=sys.stderr)
    else:
        if not device_type:
            raise ValueError(f'No simulator named {name!r} or installed device type with that name. Set TEST_DESTINATION to a valid name or UUID.')
        udid = subprocess.check_output(['xcrun', 'simctl', 'create', name, device_type['identifier'], runtime['identifier']], text=True).strip()
        booted = False
        print(f'Created {name} on iOS {runtime["version"]}: {udid}', file=sys.stderr)
    if not booted:
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, stdout=sys.stderr)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, stdout=sys.stderr)
    fields.pop('name', None)
    fields.pop('OS', None)
    fields['id'] = udid
    return ','.join(f'{key}={value}' for key, value in fields.items())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', default='platform=iOS Simulator,name=iPhone 18 Pro')
    args = parser.parse_args()
    project = (Path(__file__).resolve().parents[1] / 'project.yml').read_text()
    match = re.search(r'^\s+iOS:\s*[\"\x27]?([0-9.]+)', project, re.MULTILINE)
    if not match:
        parser.error('Cannot read the iOS deployment target from project.yml')
    try:
        print(prepare(args.destination, match.group(1)))
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'Simulator preparation failed: {error}')


if __name__ == '__main__':
    main()
