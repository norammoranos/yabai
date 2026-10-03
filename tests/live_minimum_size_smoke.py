#!/usr/bin/env python3
"""Opt-in live smoke on an isolated Space containing exactly two test windows.

Provide an already floating NSOpenPanel and an ordinary neighbor. Temporarily
tile the panel and reduce the test Space's area; restore both in finally.
No document content is edited, no application is opened, no titles are logged.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yabai", default="/Users/mac/.local/bin/yabai")
    parser.add_argument("--space", type=int, required=True)
    parser.add_argument("--other-space", type=int, required=True)
    parser.add_argument("--panel-id", type=int, required=True)
    parser.add_argument("--neighbor-id", type=int, required=True)
    parser.add_argument("--compact-top-padding", type=int, required=True)
    args = parser.parse_args()

    def run(*words):
        return subprocess.check_output([args.yabai, "-m", *map(str, words)], timeout=5).decode()

    def windows():
        return json.loads(run("query", "--windows", "--space", args.space))

    def select(index):
        if json.loads(run("query", "--spaces", "--space"))["index"] != index:
            run("space", "--focus", index)

    def geometry():
        subprocess.run(["python3", str(Path(__file__).with_name("live_tile_geometry.py")),
                        "--yabai", args.yabai, "--space", str(args.space), "--minimum-tiles", "2"], check=True)

    initial = windows()
    assert {w["id"] for w in initial} == {args.panel_id, args.neighbor_id}, "Use an isolated two-window Space"
    panel = next(w for w in initial if w["id"] == args.panel_id)
    assert panel["is-floating"], "Panel must initially be floating"
    initial_frame = panel["frame"]
    baseline = json.loads(run("query", "--spaces", "--space"))["index"]
    top = run("config", "--space", args.space, "top_padding").strip()
    try:
        select(args.other_space)
        run("window", args.panel_id, "--toggle", "float")
        # Re-managing a window on an inactive desktop must preserve ownership.
        inactive = next(w for w in windows() if w["id"] == args.panel_id)
        assert inactive["split-type"] != "none", "Panel assigned to the wrong BSP tree"
        select(args.space)
        time.sleep(.2)
        geometry()
        assert any(w["minimum-size"]["w"] > 0 or w["minimum-size"]["h"] > 0 for w in windows())
        run("config", "--space", args.space, "top_padding", args.compact_top_padding)
        time.sleep(.2)
        compact = windows()
        assert all(w["is-auto-stacked"] for w in compact), "Expected an overflow stack"
        assert len({w["stack-group-id"] for w in compact}) == 1
        geometry()
        run("window", "--focus", args.panel_id)
        run("window", "--focus", "stack.next")
        assert json.loads(run("query", "--windows", "--window"))["id"] == args.neighbor_id
        run("window", "--focus", "stack.next")
        assert json.loads(run("query", "--windows", "--window"))["id"] == args.panel_id
        run("config", "--space", args.space, "top_padding", top)
        time.sleep(.2)
        assert not any(w["is-auto-stacked"] for w in windows())
        geometry()
        print("PASS panel classification, inactive ownership, minimum sizes, stack cycle and unfold")
    finally:
        run("config", "--space", args.space, "top_padding", top)
        panel = next((w for w in windows() if w["id"] == args.panel_id), None)
        if panel and not panel["is-floating"]:
            run("window", args.panel_id, "--toggle", "float")
        if panel:
            run("window", args.panel_id, "--resize", "abs:{w}:{h}".format(**initial_frame))
            run("window", args.panel_id, "--move", "abs:{x}:{y}".format(**initial_frame))
            deadline = time.monotonic() + 1
            while True:
                restored = json.loads(run("query", "--windows", "--window", args.panel_id))
                if all(abs(restored["frame"][k] - initial_frame[k]) < 1 for k in initial_frame):
                    break
                assert time.monotonic() < deadline, "Floating frame did not restore"
                time.sleep(.02)
        select(baseline)


if __name__ == "__main__":
    main()
