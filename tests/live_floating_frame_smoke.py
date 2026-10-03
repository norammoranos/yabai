#!/usr/bin/env python3
"""Opt-in regression for back-to-back floating resize/move cache races."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--window-id", type=int, required=True)
parser.add_argument("--yabai", default="/Users/mac/.local/bin/yabai")
args = parser.parse_args()


def run(*words):
    return subprocess.check_output([args.yabai, "-m", *map(str, words)], timeout=3).decode()


def window():
    return json.loads(run("query", "--windows", "--window", args.window_id))


def apply(frame):
    run("window", args.window_id, "--resize", "abs:{w}:{h}".format(**frame))
    run("window", args.window_id, "--move", "abs:{x}:{y}".format(**frame))
    deadline = time.monotonic() + 1
    while True:
        actual = window()["frame"]
        if all(abs(actual[k] - frame[k]) < 1 for k in frame):
            return
        assert time.monotonic() < deadline, "Frame changed by a stale resize/move cache"
        time.sleep(.02)


initial = window()
assert initial["is-floating"] and initial["can-resize"] and not initial["is-minimized"]
original = initial["frame"]
try:
    shifted = {k: v + (20 if k in ("w", "h") else 5) for k, v in original.items()}
    apply(shifted)
    apply(original)
    print("PASS consecutive floating resize/move and exact frame restoration")
finally:
    apply(original)
