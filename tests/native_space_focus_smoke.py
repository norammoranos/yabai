#!/usr/bin/env python3
"""Opt-in live regression: selects desktops, restores the original selection.

Run while no one switches Spaces. Requires enabled native Desktop shortcuts
on macOS 27. Tests distant and empty desktop selection through the real IPC.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default=str(Path.home() / '.local/bin/yabai'))
args = parser.parse_args()


def spaces():
    return json.loads(subprocess.check_output([args.binary, '-m', 'query', '--spaces'], timeout=3))


def select(target):
    started = time.monotonic()
    result = subprocess.run([args.binary, '-m', 'space', '--focus', str(target['index'])],
                            capture_output=True, text=True, timeout=2)
    live = spaces()
    actual = next(s for s in live if s['has-focus'])
    elapsed = time.monotonic() - started
    if result.returncode or actual['id'] != target['id']:
        raise RuntimeError(f"FAIL target={target['index']} actual={actual['index']}: " + result.stdout.strip() + result.stderr.strip())
    for original in initial:
        if original['display'] != baseline['display']:
            current = next(s for s in live if s['id'] == original['id'])
            if current['is-visible'] != original['is-visible']:
                raise RuntimeError('FAIL: another display changed its visible Space')
    print(f"PASS target={target['index']} empty={not target['windows']} elapsed={elapsed:.2f}s")


initial = spaces()
baseline = next(s for s in initial if s['has-focus'])
local = sorted((s for s in initial if s['display'] == baseline['display'] and not s['is-native-fullscreen']), key=lambda s: s['index'])
if baseline['is-native-fullscreen'] or len(local) < 2:
    raise SystemExit('Requires an ordinary desktop and another desktop on its display.')
targets = [local[0], local[-1]]
empty = next((s for s in local if not s['windows']), None)
if empty:
    targets.append(empty)
try:
    for target in targets:
        if next(s for s in spaces() if s['has-focus'])['id'] != target['id']:
            select(target)
finally:
    if next(s for s in spaces() if s['has-focus'])['id'] != baseline['id']:
        select(baseline)
