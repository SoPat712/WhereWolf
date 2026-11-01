#!/usr/bin/env python3
"""Check navigation and layout on a disposable simulator without screenshots."""
import argparse
import json
import math
import os
import shutil
import statistics
from pathlib import Path
import subprocess
import time

from ui_accessibility import read_state, snapshot, user_location


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("udid")
    parser.add_argument("--output", type=Path, default=Path("/tmp/overland-ui-layout.json"))
    parser.add_argument("--start-at", choices=("tabs", "navigation", "forms", "server"), default="tabs",
                        help="Resume after earlier checks have passed")
    parser.add_argument("--map-only", action="store_true", help="Run only map gesture and camera checks")
    parser.add_argument("--resume-map", choices=("tracker", "trip", "settings"),
                        help="Resume animation checks after settled map checks saved in --output; requires --map-only")
    parser.add_argument("--gestures-only", action="store_true", help="Run ruler momentum and drawer handoff checks")
    parser.add_argument("--settle-only", action="store_true", help="Run drawer spring sampling and interruption checks")
    args = parser.parse_args()
    if args.resume_map and (not args.map_only or not args.output.exists()):
        parser.error("--resume-map requires --map-only and an existing --output result")
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    device = next(d for group in devices.values() for d in group if d["udid"] == args.udid)
    if (device["name"] not in ("Overland Fake Route", "Overland UI Audit")
            and device["udid"] != "42FA2C2F-F66C-41DB-A33C-A018165BB0D7"):
        parser.error("Use Overland Regression or a disposable Overland Fake Route / Overland UI Audit simulator")
    base = ["idb"]
    if os.environ.get("IDB_COMPANION"):
        base += ["--companion", os.environ["IDB_COMPANION"]]
    checks = json.loads(args.output.read_text())["checks"] if args.resume_map else []
    limitations = []
    slow_drawer = False
    gesture_samples = {}

    def ui(*parts):
        return run(*base, "ui", *parts, "--udid", args.udid)

    def state():
        return read_state(ui)

    def find(label, kind=None):
        if label == "Current location":
            return user_location(state())
        return next((e for e in state() if (e.get("AXLabel") == label
                     or (kind == "TextField" and not e.get("AXLabel") and e.get("AXValue") == label))
                     and (kind is None or e.get("type") == kind)), None)

    def frame(label, kind=None):
        element = find(label, kind)
        assert element, f"Missing {kind or 'element'}: {label}"
        return element["frame"]

    def drawer_geometry(elements=None):
        elements = state() if elements is None else elements
        element = next((e for e in elements if e.get("AXLabel") == "Drawer geometry"), None)
        assert element and element.get("AXValue"), "Drawer presentation geometry is missing"
        return json.loads(element["AXValue"])

    def center(label, kind=None):
        f = frame(label, kind)
        return round(f["x"] + f["width"] / 2), round(f["y"] + f["height"] / 2)

    def tap(label, kind="Button"):
        x, y = center(label, kind)
        ui("tap", str(x), str(y))
        time.sleep(3 if slow_drawer and label in ("Controls panel", "Tracker", "Trip", "Settings") else 0.7)

    def swipe(start, end, drawer=True):
        ui("swipe", *map(str, (*start, *end)), "--duration", "0.65", "--delta", "5")
        time.sleep(3 if slow_drawer and drawer else 0.8)

    def selected(label):
        tabs = [e for e in state() if e.get("AXLabel") in ("Tracker", "Trip", "Settings")
                and e.get("type") == "Button"]
        assert len(tabs) == 3, f"Expected three tabs: {len(tabs)}"
        elements = state()
        has_map = any(e.get("subrole") == "AXMapArea" for e in elements)
        has_trip_controls = any(e.get("AXLabel") == "Trip Settings" and e.get("type") == "Button"
                                for e in elements)
        if label == "Settings":
            assert not has_map and not find("Controls panel"), "Settings did not replace the map page"
        else:
            assert has_map, f"{label} map is missing"
            assert has_trip_controls == (label == "Trip"), f"Wrong controls for {label}"

    def scroll_to(label, kind=None, direction="up", attempts=14):
        for _ in range(attempts):
            element = find(label, kind)
            tab_y = frame("Tracker", "Button")["y"]
            panel = find("Controls panel")
            top_y = panel["frame"]["y"] + panel["frame"]["height"] if panel else 120
            if element:
                f = element["frame"]
                if top_y < f["y"] and f["y"] + f["height"] < tab_y - 8:
                    return element
            x = round(frame("Tracker", "Button")["x"] + 20)
            if direction == "down" or (element and element["frame"]["y"] <= top_y):
                swipe((x, 180), (x, 440))
            else:
                swipe((x, round(tab_y - 80)), (x, round(tab_y - 340)))
        raise AssertionError(f"Could not scroll {label} clear of tab bar")

    def record(message):
        checks.append(message)
        print(message, flush=True)

    def continuous_drag(points, sample_after=None):
        # Repeated DOWN events move one contact; restart inserts a lift and a new grab.
        executable = Path(shutil.which("idb")).resolve()
        interpreter = executable.read_text().splitlines()[0].removeprefix("#!")
        script = """
import asyncio, json, logging, sys
from idb.common.types import HIDDelay, HIDDirection, HIDPress, HIDTouch, Point, TCPAddress
from idb.grpc.client import Client
from idb.grpc.management import ClientManager
async def main():
    points = json.loads(sys.argv[3])
    events = [HIDPress(HIDTouch(Point(*points[0][:2])), HIDDirection.DOWN)]
    for start, end in zip(points, points[1:]):
        if len(end) > 3 and end[3] == "restart":
            events.append(HIDPress(HIDTouch(Point(*start[:2])), HIDDirection.UP))
            events.append(HIDDelay(end[2]))
            events.append(HIDPress(HIDTouch(Point(*end[:2])), HIDDirection.DOWN))
            continue
        frames = max(1, round(end[2] * 60))
        for i in range(1, frames + 1):
            events.append(HIDDelay(end[2] / frames))
            events.append(HIDPress(HIDTouch(Point(start[0] + (end[0] - start[0]) * i / frames,
                                                  start[1] + (end[1] - start[1]) * i / frames)), HIDDirection.DOWN))
    events.append(HIDPress(HIDTouch(Point(*points[-1][:2])), HIDDirection.UP))
    if sys.argv[2]:
        host, port = sys.argv[2].rsplit(":", 1)
        connection = Client.build(TCPAddress(host, int(port)), logging.getLogger("gesture-audit"))
    else:
        connection = ClientManager().from_udid(sys.argv[1])
    async with connection as client:
        await client.send_events(events)
asyncio.run(main())
"""
        command = [interpreter, "-c", script, args.udid, os.environ.get("IDB_COMPANION", ""), json.dumps(points)]
        snapshot = None
        if sample_after is None:
            run(*command)
        else:
            with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
                time.sleep(sample_after)
                snapshot = drawer_geometry()
                output, _ = process.communicate(timeout=15)
                assert process.returncode == 0, output
        time.sleep(3 if slow_drawer else 0.8)
        return snapshot

    def audit_settle():
        nonlocal slow_drawer
        location = find("Show My Location", "Button")
        if location and location.get("AXValue"):
            slow_drawer = bool(json.loads(location["AXValue"]).get("slowDrawer"))
        for initial, direction in (("Expanded", 1), ("Collapsed", -1)):
            if find("Controls panel").get("AXValue") != initial:
                tap("Controls panel")
            values = drawer_geometry()
            travel = values["expandedHeight"] - values["collapsedHeight"]
            x, y = center("Controls panel")
            end = y + direction * travel * 0.65
            continuous_drag([(x, y, 0), (x, end, 0.55), (x, end, 0.08)])
            values = drawer_geometry()
            trace = values["settleSamples"]
            gesture_samples["settle-from-" + initial.lower()] = trace
            assert len(trace) >= 15, "Spring did not expose frame samples"
            intervals = [b["time"] - a["time"] for a, b in zip(trace, trace[1:])]
            maximum_fps = values["maximumFramesPerSecond"]
            assert 0.75 / maximum_fps < statistics.median(intervals) < 0.035, "Spring samples do not follow the display cadence"
            low, high = values["collapsedHeight"], values["expandedHeight"]
            target = low if direction > 0 else high
            assert low + travel * 0.3 < trace[0]["height"] < low + travel * 0.7, "Release was not near the midpoint"
            assert abs(trace[-1]["height"] - target) <= 0.1, "Spring did not reach its detent"
            overshoot = 0.1 if values["reduceMotion"] else 3.1
            assert all(low - overshoot <= f["height"] <= high + overshoot for f in trace), "Spring exceeds its overshoot budget"
            slope = (trace[-1]["width"] - trace[0]["width"]) / (trace[-1]["height"] - trace[0]["height"])
            radius_slope = (trace[-1]["radius"] - trace[0]["radius"]) / (trace[-1]["height"] - trace[0]["height"])
            for a, b in zip(trace, trace[1:]):
                assert abs((b["radius"] - a["radius"]) - radius_slope * (b["height"] - a["height"])) <= 0.02, "Corner radius uses different progress"
                assert abs((b["width"] - a["width"]) - slope * (b["height"] - a["height"])) <= 0.75, "Width and height use different progress"
                if abs(a["height"] - target) > 3.1 and abs(b["height"] - target) > 3.1:
                    assert (b["height"] - a["height"]) * direction <= 0.2, "Spring reversed before its final overshoot"
                for index in range(3):
                    key = f"overland.drawer.icon.{index}"
                    assert key in a and key in b, "Actual tab-icon frame probe is missing"
                    # Fixed layout plus the sheet's horizontal transform explains icon travel.
                    center_x = sum(a[f"overland.drawer.icon.{i}"] for i in range(3)) / 3
                    factor = (a[key] - center_x) / (a["width"] - 24)
                    residual = (b[key] - a[key]) - factor * (b["width"] - a["width"])
                    assert abs(residual) <= 2, f"Tab icon jumped independently of width: {residual} pt"
                assert abs(a["materialAlpha"] - a["contentAlpha"]) <= 0.001, "Glass and content fade separately"
            selected("Tracker")
        record("Midpoint releases follow the display cadence: one spring, bounded overshoot, no unexplained icon jumps over 2 pt")
        if find("Controls panel").get("AXValue") != "Expanded":
            tap("Controls panel")

        values = drawer_geometry()
        travel = values["expandedHeight"] - values["collapsedHeight"]
        x, y = center("Controls panel")
        end = y + travel * 0.55
        _, tab_y = center("Trip", "Button")
        captured = continuous_drag([(x, y, 0), (x, end, 0.4), (x, end, 0.08),
                                    (x, tab_y, 0.08, "restart"),
                                    (x, tab_y - 35, 0.15), (x, tab_y - 35, 2.0)], sample_after=1.3)
        assert captured["dragging"], "Interruption was not sampled while holding the drawer"
        previous, resumed = captured["settleSamples"][-1], captured["samples"][0]
        assert captured["collapsedHeight"] + 3 < previous["height"] < captured["expandedHeight"] - 3, "Spring finished before the second grab"
        assert abs(previous["height"] - resumed["height"]) <= 0.5, "Grabbing the spring jumps in height"
        assert abs(previous["width"] - resumed["width"]) <= 0.5, "Grabbing the spring jumps in width"
        gesture_samples["interrupted-spring"] = {"settle": captured["settleSamples"], "drag": captured["samples"]}
        selected("Tracker")
        record("Grabbing a running spring resumes its last displayed height and width without a jump")
        if find("Controls panel").get("AXValue") != "Expanded":
            tap("Controls panel")

    def audit_gestures():
        nonlocal slow_drawer
        location = find("Show My Location", "Button")
        if location and location.get("AXValue"):
            slow_drawer = bool(json.loads(location["AXValue"]).get("slowDrawer"))

        def expand():
            if find("Controls panel").get("AXValue") != "Expanded":
                tap("Controls panel")
            time.sleep(0.3)

        last_trace_time = 0

        def samples(name):
            nonlocal last_trace_time
            values = drawer_geometry()
            result = values["samples"]
            assert len(result) >= 3 and result[0]["time"] > last_trace_time, f"No new continuous drawer movement: {name}"
            last_trace_time = result[-1]["time"]
            gesture_samples[name] = result
            return values, result

        expand()
        tap("Show My Location")
        telemetry = find("History ruler motion")
        assert telemetry, "Ruler motion telemetry is missing"
        motion = json.loads(telemetry["AXValue"])
        if motion["maximum"] >= 600:
            before = motion["samples"][-1][0] if motion["samples"] else 0
            x, y = center("Location history ruler")
            ui("swipe", str(x - 45), str(y), str(x + 45), str(y), "--duration", "0.2", "--delta", "3")
            time.sleep(2)
            motion = json.loads(find("History ruler motion")["AXValue"])
            trace = [s for s in motion["samples"] if s[0] > before]
            gesture_samples["ruler-flick"] = trace
            coast = [s for s in trace if s[4] and 2 < s[1] < motion["maximum"] - 2]
            assert len(coast) >= 8, "Flick did not continue after finger release"
            assert coast[-1][1] - coast[0][1] > 20, "Ruler jumped or stopped instead of coasting"
            intervals = [(b[1] - a[1]) / (b[0] - a[0]) for a, b in zip(coast, coast[1:]) if b[0] > a[0]]
            assert sum(intervals[-3:]) / 3 < sum(intervals[:3]) / 3 * 0.65, "Ruler did not decelerate smoothly"
            assert all(b[1] >= a[1] - 0.5 for a, b in zip(coast, coast[1:])), "Ruler reversed or jumped during decay"
            assert find("Recorded point"), "Map replay did not follow the flick"
            dragged = [s[1] for s in trace if s[3]]
            assert 55 <= max(dragged) - min(dragged) <= 105, "Ruler drag does not track the 90 pt finger movement"
            x, y = center("Location history ruler")
            ui("swipe", str(x + 90), str(y), str(x - 90), str(y), "--duration", "0.15", "--delta", "3")
            time.sleep(2)
            assert find("Location history ruler")["AXValue"] == "Live", "Flicking back to the Live boundary failed"
            motion = json.loads(find("History ruler motion")["AXValue"])
            gesture_samples["ruler-live-boundary"] = motion["samples"]
            assert abs(motion["position"]) < 1, "Ruler did not settle on the Live boundary"
            tap("Show My Location")
            record("Ruler coasts after release with monotonic, decaying position samples; replay and Live remain available")
        else:
            limitations.append("Full ruler decay needs at least 50 ticks; seed load_replay_demo.py on Overland UI Audit.")
        handle = frame("Controls panel")
        assert handle["height"] >= 44, "Grabber target is smaller than 44 pt"
        values = drawer_geometry()
        x = round(handle["x"] + 55)
        y = round((handle["y"] + handle["height"] + frame("Tracker", "Button")["y"]) / 2)
        swipe((x, y), (x, min(850, y + 280)))
        values, trace = samples("middle-content")
        assert max(s["height"] for s in trace) - min(s["height"] for s in trace) > 80, "Middle content does not drag the drawer"
        expand()
        start = center("Trip", "Button")
        ui("swipe", *map(str, (*start, start[0], start[1] + 45)), "--duration", "0.12", "--delta", "3")
        time.sleep(3 if slow_drawer else 0.8)
        values, trace = samples("tab-area")
        assert max(s["height"] for s in trace) - min(s["height"] for s in trace) > 20, "Tab-strip area does not drag the drawer"
        selected("Tracker")
        record("Entire drawer drags from middle content and tab strip; grabber target is at least 44 pt")
        expand()

        size = run("xcrun", "simctl", "ui", args.udid, "content_size").strip()
        opened_details = find("Show location details", "Button") is not None
        if opened_details:
            tap("Show location details")
        try:
            run("xcrun", "simctl", "ui", args.udid, "content_size", "accessibility-extra-extra-extra-large")
            time.sleep(1)
            expand()
            values = drawer_geometry()
            assert values["contentHeight"] > values["scrollHeight"] + 100, "Handoff fixture does not overflow"
            top = round(frame("Controls panel")["y"] + 44)
            x = round(frame("Controls panel")["x"] + 60)
            swipe((x, top + 250), (x, top + 150))
            values = drawer_geometry()
            assert values["scrollOffset"] > 30, "Expanded content did not scroll"
            swipe((x, top + 40), (x, 830))
            values, trace = samples("scroll-to-collapse")
            assert any(s["offset"] > 20 for s in trace), "Drag never started in scrolled content"
            assert any(s["offset"] <= 1 and s["height"] < values["expandedHeight"] - 80 for s in trace), "Scroll top did not hand off to drawer during the same touch"
            assert find("Controls panel")["AXValue"] == "Collapsed", "Continuous downward handoff did not collapse"
            record("One downward gesture scrolls to the top, takes over the drawer, and collapses it")
            expand()
            top = round(frame("Controls panel")["y"] + 44)
            continuous_drag([(x, top + 170, 0), (x, top + 330, 0.8), (x, top + 40, 1.4)])
            values, trace = samples("expand-to-scroll")
            expanded = values["expandedHeight"]
            assert any(s["height"] < expanded - 80 for s in trace), "Gesture did not expose a partially open drawer"
            assert any(s["height"] >= expanded - 1 and s["offset"] > 40 for s in trace), "Upward gesture did not expand then scroll without lifting"
            assert all(s["offset"] <= 1 for s in trace if s["height"] < expanded - 1), "Content scrolled while drawer was moving"
            screen = next(e["frame"] for e in state() if e.get("type") == "Application")
            narrow, wide = min(620, round(screen["width"] * 0.85)), min(620, round(screen["width"] * 0.95))
            for sample in trace:
                fraction = (sample["height"] - values["collapsedHeight"]) / (expanded - values["collapsedHeight"])
                assert abs(sample["width"] - (narrow + (wide - narrow) * fraction)) <= 1, "Width stopped following drawer drag"
            record("Upward reversal expands the partially open drawer before scrolling, with continuous width interpolation")
        finally:
            run("xcrun", "simctl", "ui", args.udid, "content_size", size)
            time.sleep(1)
            if opened_details:
                scroll_to("Hide location details", "Button", direction="down")
                tap("Hide location details")
        tap("Show My Location")
        expand()

    def audit_map():
        nonlocal slow_drawer

        def geometry(elements=None):
            elements = state() if elements is None else elements
            element = next((e for e in elements if e.get("AXLabel") == "Show My Location"
                            and e.get("type") == "Button"), None)
            assert element and element.get("AXValue"), "Map audit geometry is missing from Show My Location"
            return json.loads(element["AXValue"])

        slow_drawer = geometry().get("slowDrawer", False)

        def point(element):
            f = element["frame"]
            return f["x"] + f["width"] / 2, f["y"] + f["height"] / 2

        def map_state(elements=None):
            elements = state() if elements is None else elements
            dot = user_location(elements)
            assert dot, "Current location is missing; authorize location on the disposable simulator"
            panel = dict(next(e for e in elements if e.get("AXLabel") == "Controls panel"))
            values = drawer_geometry(elements)
            panel["frame"] = {"x": values["sheetX"], "y": values["sheetY"],
                              "width": values["sheetWidth"], "height": values["sheetHeight"]}
            screen = next(e["frame"] for e in elements if e.get("type") == "Application")
            return point(dot), panel, screen

        def edge_swipe(edge, sheet, screen):
            if edge == "above":
                start = round(screen["x"] + screen["width"] * 0.4), round(sheet["y"] - 36)
                return start, (start[0] + 90, start[1])
            x = sheet["x"] - 4 if edge == "left" else sheet["x"] + sheet["width"] + 4
            assert screen["x"] + 1 <= x <= screen["x"] + screen["width"] - 1, "Drawer leaves no map edge to pan"
            # Side-edge touches must clear the phone's rounded corners and home gesture area.
            bottom = min(sheet["y"] + sheet["height"] - 8, screen["y"] + screen["height"] - 60)
            top = max(screen["y"] + 70, bottom - 90)
            assert bottom - top >= 20, "Visible map edge is too short for a map pan"
            return (round(x), round(bottom)), (round(x), round(top))

        def set_panel(value):
            for attempt in range(3):
                if find("Controls panel").get("AXValue") != value:
                    tap("Controls panel")
                deadline = time.monotonic() + 8
                previous = None
                stable_since = time.monotonic()
                while time.monotonic() < deadline:
                    elements = state()
                    panel = next(e for e in elements if e.get("AXLabel") == "Controls panel")
                    values = drawer_geometry(elements)
                    top = values["sheetY"]
                    if previous is None or abs(top - previous) > 0.1:
                        stable_since = time.monotonic()
                    previous = top
                    if panel.get("AXValue") == value and time.monotonic() - stable_since >= 0.5:
                        return
                    time.sleep(0.2)
            raise AssertionError(f"Drawer did not settle {value}: {values}")

        def recenter():
            tap("Show My Location")
            time.sleep(0.6)
            elements = state()
            dot, panel, screen = map_state(elements)
            values = geometry(elements)
            target_y = (values["targetSafeTop"] + drawer_geometry(elements)["sheetY"]) / 2
            target = screen["x"] + screen["width"] / 2, target_y
            assert math.dist(dot, target) <= 10, f"Recenter misses {panel.get('AXValue')} target: {dot} vs {target}"
            assert math.dist((values["targetX"], values["targetY"]), target) <= 1, "Stored camera target differs from visible geometry"
            return target

        def edge_pans(context):
            for edge in ("above", "left", "right"):
                recenter()
                before, panel, screen = map_state()
                f = panel["frame"]
                ratio = 0.85 if panel.get("AXValue") == "Collapsed" else 0.95
                assert abs(f["width"] - min(620, round(screen["width"] * ratio))) <= 1, "Drawer has the wrong settled width"
                start, end = edge_swipe(edge, f, screen)
                swipe(start, end, drawer=False)
                after, after_panel, _ = map_state()
                assert math.dist(before, after) >= 20, f"Map did not pan {edge} drawer ({context})"
                assert abs(after_panel["frame"]["y"] - f["y"]) <= 2, f"Map pan moved drawer ({context}, {edge})"
            record(f"Map pans above and beside both drawer edges: {context}")

        def follow_moves(context, target=None):
            target = target or recenter()
            for latitude in (45.5156, 45.5160):
                run("xcrun", "simctl", "location", args.udid, "set", f"{latitude},-122.6784")
                for _ in range(30):
                    values = geometry()
                    if abs(values["latitude"] - latitude) < 0.00001 and abs(values["longitude"] + 122.6784) < 0.00001:
                        break
                    time.sleep(0.3)
                else:
                    raise AssertionError(f"Simulated fix did not reach the map ({context}): {values}")
                # MapKit animates its system annotation after the coordinate changes.
                deadline = time.monotonic() + 4
                while True:
                    dot, _, _ = map_state()
                    if math.dist(dot, target) <= 2 or time.monotonic() >= deadline:
                        break
                    time.sleep(0.1)
                assert math.dist(dot, target) <= 10, f"Following location drifted from recenter target ({context}): {dot} vs {target}"
            record(f"Recenter and simulated location movement retain the camera target: {context}")

        def drawer_motion(context):
            set_panel("Expanded")
            expanded = drawer_geometry()["sheetY"]
            set_panel("Collapsed")
            recenter()
            compact = drawer_geometry()["sheetY"]
            start = center("Controls panel")
            end = start[0], round(start[1] - (compact - expanded))
            command = [*base, "ui", "swipe", *map(str, (*start, *end)),
                       "--duration", "8", "--delta", "5", "--udid", args.udid]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            midpoint = False
            try:
                deadline = time.monotonic() + 15
                while process.poll() is None and time.monotonic() < deadline:
                    elements = state()
                    dot, panel, screen = map_state(elements)
                    progress = (compact - panel["frame"]["y"]) / max(1, compact - expanded)
                    if 0.25 < progress < 0.75:
                        midpoint = True
                    target = (screen["x"] + screen["width"] / 2,
                              (geometry(elements)["targetSafeTop"] + drawer_geometry(elements)["sheetY"]) / 2)
                    assert math.dist(dot, target) <= 10, f"Drawer motion misses the visible center ({context}): {dot} vs {target}"
                    time.sleep(0.15)
                output, _ = process.communicate(timeout=3)
                assert process.returncode == 0, f"Drawer drag failed: {output}"
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
            assert midpoint, f"No mid-drag accessibility sample ({context})"
            time.sleep(3 if slow_drawer else 0.8)
            elements = state()
            dot, _, screen = map_state(elements)
            target = (screen["x"] + screen["width"] / 2,
                      (geometry(elements)["targetSafeTop"] + drawer_geometry(elements)["sheetY"]) / 2)
            assert math.dist(dot, target) <= 10, f"Settling drawer misses the visible center ({context})"
            record(f"Drawer drag and settling center the dot in the visible map, including mid-drag: {context}")
            follow_moves(f"{context}, after drawer movement", target)

        def mid_transition(context):
            if not slow_drawer:
                return
            set_panel("Expanded")
            open_geometry = drawer_geometry()
            open_top = open_geometry["sheetY"]
            set_panel("Collapsed")
            closed_top = drawer_geometry()["sheetY"]
            _, _, screen = map_state()
            for edge in ("above", "left", "right", "recenter"):
                set_panel("Expanded")
                recenter()
                locate_point = center("Show My Location", "Button")
                grabber_point = center("Controls panel")
                ui("tap", *map(str, grabber_point))
                deadline = time.monotonic() + 15
                while True:
                    values = drawer_geometry(snapshot(ui))
                    progress = (closed_top - values["sheetY"]) / (closed_top - open_top)
                    if progress > 0.05:
                        break
                    assert time.monotonic() < deadline, f"Drawer did not begin collapsing ({context})"
                assert progress < 0.95, f"Drawer settled before gesture sampling ({context}): {values}"
                if edge == "recenter":
                    ui("tap", *map(str, locate_point))
                    chosen = geometry(snapshot(ui))
                    chosen_top = chosen["targetDrawerTop"]
                    assert open_top < chosen_top < closed_top, "Recenter missed the intermediate drawer position"
                    target = chosen["targetX"], (chosen["targetSafeTop"] + chosen_top) / 2
                    assert abs(chosen["targetY"] - target[1]) <= 1, "Intermediate recenter chose the wrong vertical target"
                    time.sleep(3)
                    elements = state()
                    dot, _, screen = map_state(elements)
                    final_target = (screen["x"] + screen["width"] / 2,
                                    (geometry(elements)["targetSafeTop"] + drawer_geometry(elements)["sheetY"]) / 2)
                    assert math.dist(dot, final_target) <= 10, f"Drawer completion misses the visible center ({context}): {dot} vs {final_target}"
                    follow_moves(f"{context}, after intermediate recenter", final_target)
                else:
                    top = values["sheetY"]
                    sheet = {"x": values["sheetX"], "y": values["sheetY"],
                             "width": values["sheetWidth"], "height": values["sheetHeight"]}
                    compact_width = min(620, round(screen["width"] * 0.85))
                    open_width = min(620, round(screen["width"] * 0.95))
                    if open_width > compact_width:
                        assert compact_width < sheet["width"] < open_width, "Moving drawer did not expose an intermediate width"
                    else:
                        assert abs(sheet["width"] - open_width) <= 1, "Moving drawer exceeds its maximum width"
                    # Keep injected touches outside the drawer's entire path, including its grabber.
                    touch_sheet = dict(sheet, x=open_geometry["sheetX"],
                                       width=open_geometry["sheetWidth"])
                    if edge == "above":
                        touch_sheet["y"] = open_top - 12
                    start, end = edge_swipe(edge, touch_sheet, screen)
                    continuous_drag([(*start, 0), (*end, 0.65)])
                    elements = state()
                    dot, _, screen = map_state(elements)
                    # Drawer collapse moves the follow target too; measure detachment from its final position.
                    target = (screen["x"] + screen["width"] / 2,
                              (geometry(elements)["targetSafeTop"] + drawer_geometry(elements)["sheetY"]) / 2)
                    gesture_samples[f"moving-{context}-{edge}"] = {
                        "start": start, "end": end, "drawerBefore": values,
                        "dotAfter": dot, "targetAfter": target,
                        "cameraAfter": geometry(elements),
                    }
                    assert math.dist(dot, target) >= 20, f"Map did not pan {edge} the moving drawer ({context}): {dot} vs {target}"
            record(f"Map edge pans and recenter work during drawer settling: {context}")

        def chrome_pans():
            recenter()
            style = frame("Map style", "PopUpButton")
            locate = frame("Show My Location", "Button")
            zoom_out = frame("Zoom Out", "Button")
            points = ((round(style["x"] - 6), round(locate["y"] + locate["height"] / 2)),
                      (round(style["x"] + style["width"] + 6), round(locate["y"] + locate["height"] / 2)),
                      (round(zoom_out["x"] + zoom_out["width"] / 2), round(zoom_out["y"] + zoom_out["height"] + 8)))
            for start in points:
                recenter()
                before, _, _ = map_state()
                swipe(start, (start[0] - 80, start[1]), drawer=False)
                after, _, _ = map_state()
                assert math.dist(before, after) >= 20, f"Map controls block a pan outside their capsule: {start}"
            record("Map pans immediately beside and below the map controls capsule")

        def animated_tabs():
            for initial in ("Collapsed", "Expanded"):
                set_panel(initial)
                destination = center("Trip", "Button")
                grabber = center("Controls panel")
                ui("tap", *map(str, grabber))
                time.sleep(0.3)
                ui("tap", *map(str, destination))
                time.sleep(3)
                selected("Trip")
                tap("Tracker")
            set_panel("Collapsed")
            start = center("Tracker", "Button")
            end = center("Settings", "Button")
            grabber = center("Controls panel")
            ui("tap", *map(str, grabber))
            time.sleep(0.3)
            ui("swipe", *map(str, (*start, *end)), "--duration", "0.4", "--delta", "5")
            time.sleep(3)
            selected("Settings")
            tap("Tracker")
            record("Tab taps and horizontal scrubbing remain active during drawer animation")

        def settings_gap():
            set_panel("Collapsed")
            compact = drawer_geometry()
            assert not compact["settings"], "Expected map drawer geometry"
            tap("Settings")
            selected("Settings")
            settings = drawer_geometry()
            assert settings["settings"], "Expected Settings drawer geometry"
            map_gap = compact["safeBottomY"] - compact["tabsBottom"]
            settings_gap = settings["safeBottomY"] - settings["tabsBottom"]
            assert map_gap >= -19 and settings_gap >= -19, "Tab controls overlap the home indicator"
            assert abs(settings["sheetBottom"] - compact["sheetBottom"]) <= 1, "Settings capsule bottom differs from the collapsed map capsule"
            assert abs(settings_gap - map_gap) <= 1, "Settings capsule changes the bottom safe-area gap"
            assert abs(settings["tabsBottom"] - compact["tabsBottom"]) <= 1, "Settings moves the tab strip vertically"
            record("Settings and collapsed map capsules share their bottom safe-area gap and tab position")
            tap("Tracker")
            selected("Tracker")

        run("xcrun", "simctl", "location", args.udid, "set", "45.5152,-122.6784")
        time.sleep(1.5)
        resume_context = {"tracker": "Tracker", "trip": "after Trip switch",
                          "settings": "after Settings switch"}.get(args.resume_map)
        if resume_context:
            prerequisite = f"Recenter and simulated location movement retain the camera target: {resume_context}, after drawer movement"
            assert checks and checks[-1] == prerequisite, "Saved checks do not end at the requested animation checkpoint"
            assert slow_drawer, "Resuming animation checks requires OVERLAND_UI_AUDIT=1"
        else:
            settings_gap()
            chrome_pans()
        for context, destinations in (("Tracker", ()), ("after Trip switch", ("Trip",)),
                                      ("after Settings switch", ("Settings", "Tracker"))):
            if resume_context and context != resume_context:
                continue
            for destination in destinations:
                tap(destination)
                selected(destination)
            if resume_context is None:
                for value in ("Collapsed", "Expanded"):
                    set_panel(value)
                    edge_pans(f"{context}, {value}")
                    follow_moves(f"{context}, {value}")
                drawer_motion(context)
            mid_transition(context)
            resume_context = None
        if find("Trip Settings", "Button"):
            tap("Tracker")
        if slow_drawer:
            animated_tabs()
        set_panel("Expanded")
        if not slow_drawer:
            limitations.append("Mid-transition edge pans and recenter require OVERLAND_UI_AUDIT=1 on a Debug simulator build.")
        limitations.append("IDB HID has no touch identifier: panning or tapping recenter with a second finger while holding the drawer mid-drag is not covered. Mid-drag visible-center alignment is sampled during a continuous drawer swipe.")

    original_size = run("xcrun", "simctl", "ui", args.udid, "content_size").strip()
    original_appearance = run("xcrun", "simctl", "ui", args.udid, "appearance").strip()
    try:
        for _ in range(20):
            if find("Settings", "Button"):
                break
            time.sleep(0.5)
        if args.settle_only:
            tap("Tracker")
            audit_settle()
            return
        if args.gestures_only:
            tap("Tracker")
            audit_gestures()
            return
        if args.map_only:
            tap("Tracker")
            selected("Tracker")
            audit_map()
            return
        if args.start_at == "tabs":
            tap("Tracker")
            selected("Tracker")
            location_button = find("Show My Location", "Button")
            if location_button and location_button.get("AXValue"):
                slow_drawer = json.loads(location_button["AXValue"]).get("slowDrawer", False)
                if slow_drawer:
                    time.sleep(3)
            baseline = {label: frame(label, "Button") for label in ("Tracker", "Trip", "Settings")}
            expanded_top = frame("Controls panel")["y"]
            tap("Controls panel")
            compact = frame("Controls panel")
            assert compact["height"] >= 44, "Grabber hit area is too small"
            screen = next(e["frame"] for e in state() if e.get("type") == "Application")
            assert abs(compact["width"] - min(620, round(screen["width"] * 0.85))) <= 1, "Folded drawer width is not 85%"
            tab_frames = [frame(label, "Button") for label in ("Tracker", "Trip", "Settings")]
            spacing = (compact["width"] - 32) / 3
            for index, tab_frame in enumerate(tab_frames):
                expected = compact["x"] + 16 + spacing * (index + 0.5)
                assert abs(tab_frame["x"] + tab_frame["width"] / 2 - expected) < 1, "Tab is not centered in its drawer slot"
            tab_top = min(f["y"] for f in tab_frames)
            assert compact["y"] + compact["height"] <= tab_top + 1, "Grabber overlaps the tabs"
            assert tab_top - compact["y"] <= 48, "Grabber sits too far above the tabs"
            values = drawer_geometry()
            assert values["sheetHeight"] <= values["tabHeight"] + 24, "Collapsed capsule has excess visible padding"
            assert compact["y"] < values["sheetY"], "Grabber hit extension must be invisible above the capsule"
            for label, before in baseline.items():
                after = frame(label, "Button")
                assert all(abs(before[axis] - after[axis]) < 1 for axis in ("y", "height")), f"{label} moved vertically on collapse"
            time.sleep(2)
            assert find("Controls panel")["AXValue"] == "Collapsed", "Status refresh reopened the panel"
            start = center("Controls panel")
            swipe(start, (start[0], start[1] - 45))
            assert abs(frame("Controls panel")["y"] - compact["y"]) < 1, "Short upward drag did not settle closed"
            start = center("Controls panel")
            travel = compact["y"] - expanded_top
            swipe(start, (start[0], round(start[1] - travel * 0.7)))
            selected("Tracker")
            assert find("Send Now", "Button"), "Vertical drag did not reopen panel"
            expanded = frame("Controls panel")
            start = center("Controls panel")
            swipe(start, (start[0], start[1] + 45))
            assert find("Controls panel")["AXValue"] == "Expanded", "Short downward drag did not settle open"
            record("Panel expansion keeps tab y and height fixed and leaves selection unchanged")

            audit_settle()
            audit_gestures()
            audit_map()

        if args.start_at in ("tabs", "navigation"):
            if args.start_at == "navigation":
                tap("Tracker")
                selected("Tracker")
                baseline = {label: frame(label, "Button") for label in ("Tracker", "Trip", "Settings")}
            for destination in ("Settings", "Tracker", "Trip", "Settings", "Trip", "Tracker"):
                tap(destination)
                selected(destination)
            record("Direct tab taps work between every pair of pages")

            swipe(center("Tracker", "Button"), center("Settings", "Button"))
            selected("Settings")
            swipe(center("Settings", "Button"), center("Tracker", "Button"))
            selected("Tracker")
            # Begin on an unselected tab to catch coordinate calculations anchored to selection.
            swipe(center("Trip", "Button"), center("Settings", "Button"))
            selected("Settings")
            record("Horizontal scrub works in both directions and from an unselected tab")

            assert not find("Controls panel"), "Settings exposes the map panel"
            assert not any(e.get("subrole") == "AXMapArea" for e in state()), "Settings exposes a map"
            settings_tabs = {label: frame(label, "Button") for label in baseline}
            assert abs(settings_tabs["Trip"]["y"] - baseline["Trip"]["y"]) <= 1, "Settings moves the tab strip vertically"
            assert abs(settings_tabs["Settings"]["height"] - baseline["Tracker"]["height"]) < 1, "Settings changes the selected tab hit area"
            start = center("Settings", "Button")
            swipe(start, (start[0], start[1] - 160))
            selected("Settings")
            assert all(abs(frame(label, "Button")["y"] - before["y"]) < 1
                       for label, before in settings_tabs.items()), "Settings bar responds to drawer pan"
            record("Settings uses compact tab padding and disables drawer pan while preserving tab hit areas")
            scroll_to("Privacy Policy")
            record("Last Settings row scrolls above the drawer tabs")

        if args.start_at != "server":
            tap("Settings")
            scroll_to("WiFi Zones", "Button")
            tap("WiFi Zones")
            assert find("WiFi Zones", "Heading") or find("WiFi Zones", "StaticText"), "WiFi navigation title is missing"
            tap("Add Zone")
            assert find("Add Zone", "Heading") or find("Add Zone", "StaticText"), "WiFi zone form did not open"
            assert find("Latitude", "TextField") and find("Longitude", "TextField")
            tap("Cancel")
            tap("Settings")
            scroll_to("About Usage Presets", "Button", direction="down")
            tap("About Usage Presets")
            assert find("Done", "Button"), "Preset help did not open"
            tap("Done")
            record("WiFi navigation, zone form, and preset help open and dismiss")

        if args.start_at == "server":
            tap("Settings")
        scroll_to("Server", "Button", direction="down")
        tap("Server")
        scroll_to("Clear Server URL", "Button")
        record("Last Server action scrolls clear of the drawer tabs")

        tap("Tracker")
        for appearance in ("dark", "light"):
            run("xcrun", "simctl", "ui", args.udid, "appearance", appearance)
            time.sleep(0.5)
            selected("Tracker")
            assert frame("Send Now")["y"] < frame("Tracker", "Button")["y"]
        record("Both appearance modes retain visible controls and tabs")

        run("xcrun", "simctl", "ui", args.udid, "content_size", "accessibility-extra-extra-extra-large")
        time.sleep(1)
        selected("Tracker")
        tab = frame("Tracker", "Button")
        assert tab["height"] >= 44 and tab["y"] > 0, "Large-text tabs are not usable"
        handle = frame("Controls panel")
        assert drawer_geometry()["sheetY"] >= 60, "Large-text panel exceeds the top safe area"
        scroll_to("Send Now", "Button")
        tap("Trip")
        selected("Trip")
        scroll_to("Start Trip", "Button")
        record("Largest accessibility text keeps panel actions reachable")
        tap("Settings")
        selected("Settings")
        back = next((e for e in state() if e.get("AXLabel") == "Settings"
                     and e.get("type") == "Button" and e["frame"]["y"] < 200), None)
        if back:
            f = back["frame"]
            ui("tap", str(round(f["x"] + f["width"] / 2)), str(round(f["y"] + f["height"] / 2)))
            time.sleep(0.7)
        scroll_to("Privacy Policy", attempts=40)
        record("Largest accessibility text keeps the last Settings row above the compact bar")
    except Exception:
        args.output.with_suffix(".accessibility.json").write_text(json.dumps(state(), indent=2))
        raise
    finally:
        run("xcrun", "simctl", "ui", args.udid, "content_size", original_size)
        run("xcrun", "simctl", "ui", args.udid, "appearance", original_appearance)
        args.output.write_text(json.dumps({"checks": checks, "limitations": limitations, "gestureSamples": gesture_samples}, indent=2))


if __name__ == "__main__":
    main()
