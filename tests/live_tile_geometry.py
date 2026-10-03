#!/usr/bin/env python3
"""Read-only live regression: distinct ordinary tiles must not overlap.

Run on a deliberately prepared test Space. Floating windows, explicit zooms,
and stacks are excluded because their overlap is intentional. Never log titles.
"""
import argparse
import itertools
import json
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--yabai", default="/Users/mac/.local/bin/yabai")
    parser.add_argument("--space", type=int, required=True)
    parser.add_argument("--minimum-tiles", type=int, default=1)
    args = parser.parse_args()
    windows = json.loads(subprocess.check_output(
        [args.yabai, "-m", "query", "--windows", "--space", str(args.space)]))
    tiles = [w for w in windows if w["has-ax-reference"]
             and not any(w[k] for k in ("is-floating", "is-minimized", "is-hidden",
                                       "has-fullscreen-zoom", "has-parent-zoom"))
             ]
    failures = []
    for a, b in itertools.combinations(tiles, 2):
        if a.get("stack-group-id") and a["stack-group-id"] == b.get("stack-group-id"):
            continue
        af, bf = a["frame"], b["frame"]
        width = min(af["x"] + af["w"], bf["x"] + bf["w"]) - max(af["x"], bf["x"])
        height = min(af["y"] + af["h"], bf["y"] + bf["h"]) - max(af["y"], bf["y"])
        if width > 1 and height > 1:
            failures.append({"windows": [a["id"], b["id"]],
                             "intersection": [round(width, 2), round(height, 2)]})
    if len(tiles) < args.minimum_tiles:
        failures.append({"missing_tiles": args.minimum_tiles - len(tiles)})
    print(json.dumps({"ok": not failures, "tile_count": len(tiles),
                      "overlaps": failures}))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
