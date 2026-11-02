#!/usr/bin/env python3
"""Exercise real simulator location delivery against a disposable local server.

Creates and removes its own simulator, or reuses the shared Overland Regression phone so a
first boot does not compete with the test. Never targets the owner's trial simulator.
No screenshots, production endpoints, or persisted credentials are used.
"""
import argparse
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time

from ui_accessibility import read_state, user_location

BUNDLE = "com.aaronpk.overland"


def run(*args, timeout=60):
    return subprocess.check_output(args, text=True, timeout=timeout, stderr=subprocess.STDOUT)


def wait_for(check, message, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(1)
    raise AssertionError(message)


def check_history_migration(udid):
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data").strip())
    path = container / "Library/Application Support/Recent Locations/history.sqlite"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"_type": "location", "lat": 45.5152, "lon": -122.6784,
                          "tst": time.time(), "tid": "migration-test"}).encode()
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE points (id INTEGER PRIMARY KEY, timestamp REAL NOT NULL, "
                   "latitude REAL NOT NULL, longitude REAL NOT NULL, format INTEGER NOT NULL, payload BLOB NOT NULL)")
        db.execute("INSERT INTO points VALUES (4000, ?, 45.5152, -122.6784, 1, ?)", (time.time(), payload))
        db.execute("INSERT INTO points VALUES (4001, 1, 45.5152, -122.6784, 1, ?)", (payload,))

    def migrated():
        with sqlite3.connect(path) as db:
            schema = db.execute("SELECT sql FROM sqlite_master WHERE name = 'points'").fetchone()[0]
            return "AUTOINCREMENT" in schema and db.execute("SELECT COUNT(*) FROM points").fetchone()[0] == 1

    run("xcrun", "simctl", "launch", udid, BUNDLE, "-GLTrackingStateDefaults", "NO")
    wait_for(migrated, "Replay migration or expiry failed")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT payload FROM points WHERE id = 4000").fetchone()[0] == payload, "Migration changed the stored record"
        db.execute("UPDATE points SET timestamp = 1")
    run("xcrun", "simctl", "terminate", udid, BUNDLE)
    run("xcrun", "simctl", "launch", udid, BUNDLE, "-GLTrackingStateDefaults", "NO")

    def expired():
        with sqlite3.connect(path) as db:
            return db.execute("SELECT COUNT(*) FROM points").fetchone()[0] == 0

    wait_for(expired, "Replay did not prune the expired final record")
    run("xcrun", "simctl", "terminate", udid, BUNDLE)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--simulator-id", help="Reuse Overland Regression or a disposable Overland Fake Route / Overland UI Audit simulator; app data is reset")
    parser.add_argument("--keep-on-failure", action="store_true", help="Keep the stopped disposable simulator for diagnosis if a check fails")
    parser.add_argument("--output", type=Path, default=Path("/tmp/overland-fake-route-results.json"))
    args = parser.parse_args()
    if not args.app.is_dir():
        parser.error("Supply a built simulator .app directory")

    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    existing = next((d for group in devices.values() for d in group if d["udid"] == args.simulator_id), None)
    if args.simulator_id and (not existing or existing["name"] not in ("Overland Regression", "Overland Fake Route", "Overland UI Audit")):
        parser.error("Only Overland Regression, Overland Fake Route or Overland UI Audit can be reused")
    booted = [d["name"] for group in devices.values() for d in group
              if d["state"] == "Booted" and d["udid"] != args.simulator_id]
    if booted:
        parser.error("Shut down running simulators before this test: " + ", ".join(booted))

    requests = []
    lock = threading.Lock()

    class Receiver(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with lock:
                status = 503 if not requests else 200
                requests.append({"status": status, "body": body, "time": time.monotonic()})
            response = json.dumps([] if body.get("_type") else {"result": "ok" if status == 200 else "retry"}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            if status == 503:
                self.send_header("Retry-After", "8")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    runtime = next(r["identifier"] for r in runtimes if r["isAvailable"] and r["name"].startswith("iOS 27"))
    udid = args.simulator_id or run("xcrun", "simctl", "create", "Overland Fake Route", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime).strip()
    companion = None
    route = None
    runtime_log = None
    runtime_stream = None
    completed = False
    checks = []
    try:
        print(f"Isolated simulator {udid}", flush=True)
        if not existing or existing["state"] != "Booted":
            run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=180)
        runtime_log = args.output.with_suffix(".runtime.log").open("w")
        runtime_stream = subprocess.Popen(
            ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "compact",
             "--level", "default", "--predicate", 'process == "Overland"'],
            stdout=runtime_log, stderr=subprocess.STDOUT)
        if existing:
            run("xcrun", "simctl", "uninstall", udid, BUNDLE)
        run("xcrun", "simctl", "install", udid, str(args.app.resolve()), timeout=120)
        for service in ("location-always", "motion"):
            run("xcrun", "simctl", "privacy", udid, "grant", service, BUNDLE)
        history_path = check_history_migration(udid)
        run("xcrun", "simctl", "location", udid, "set", "45.5152,-122.6784")
        endpoint = f"http://127.0.0.1:{server.server_port}/locations"
        run("xcrun", "simctl", "launch", udid, BUNDLE,
            "-GLAPIEndpointDefaults", endpoint, "-GLTrackingStateDefaults", "YES",
            "-GLSignificantLocationModeDefaults", "1", "-GLDesiredAccuracyDefaults", "-1",
            "-GLPausesAutomaticallyDefaults", "NO", "-GLSendIntervalDefaults", "1",
            "-GLNotificationsEnabledDefaults", "NO", "-GLLoggingModeDefaults", "0",
            "-GLTripPausesAutomaticallyDefaults", "NO", "-GLTripDesiredAccuracyDefaults", "-1")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        log = tempfile.TemporaryFile()
        companion = subprocess.Popen(["idb_companion", "--udid", udid, "--grpc-port", str(port)], stdout=log, stderr=log, start_new_session=True)
        base = ["idb", "--companion", f"localhost:{port}", "ui"]

        def ui(*commands):
            return run(*base, *commands, "--udid", udid, timeout=15)

        def state():
            return read_state(ui)

        def ready():
            try:
                return state()
            except (subprocess.SubprocessError, json.JSONDecodeError):
                return None

        def find(label, kind=None):
            if label == "Current location":
                return user_location(state())
            return next((e for e in state() if e.get("AXLabel") == label and (kind is None or e.get("type") == kind)), None)

        def tap(label, kind="Button", last=False):
            matches = [e for e in state() if e.get("AXLabel") == label and e.get("type") == kind]
            if not matches:
                raise AssertionError(f"Missing {kind}: {label}")
            f = matches[-1 if last else 0]["frame"]
            ui("tap", str(round(f["x"] + f["width"] / 2)), str(round(f["y"] + f["height"] / 2)))
            time.sleep(0.8)

        wait_for(ready, "IDB did not become ready", timeout=60)
        wait_for(lambda: find("Stop Tracking", "Button"), "Tracker did not start")

        def drag_panel(distance):
            frame = find("Controls panel")["frame"]
            x = round(frame["x"] + frame["width"] / 2)
            y = round(frame["y"] + frame["height"] / 2)
            ui("swipe", str(x), str(y), str(x), str(max(65, min(820, y + distance))), "--duration", "0.8")
            time.sleep(1)

        location_button = find("Show My Location", "Button")
        assert location_button and location_button["frame"]["x"] > 250, "Location control is not at top right"
        assert find("Map style", "PopUpButton"), "Map style control missing"
        wait_for(lambda: find("Current location"), "Map location missing")

        def marker_center(frame):
            return (frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2)

        def marker_geometry(label, frame):
            if label == "Current location":
                return marker_center(frame)
            return tuple(frame[axis] for axis in ("x", "y", "width", "height"))

        last_frame = None
        stable_since = time.monotonic()

        def map_settled():
            nonlocal last_frame, stable_since
            current = find("Current location", "GenericElement")
            if not current:
                return False
            frame = current["frame"]
            if last_frame is None or any(abs(a - b) > 1
                                         for a, b in zip(marker_center(frame), marker_center(last_frame))):
                stable_since = time.monotonic()
            last_frame = frame
            return time.monotonic() - stable_since >= 2

        wait_for(map_settled, "Initial map camera did not settle")
        location_frame = find("Current location", "GenericElement")["frame"]

        def check_map_clearance():
            legal = find("Legal")["frame"]
            panel_top = json.loads(find("Drawer geometry")["AXValue"])["sheetY"]
            # The credit and Legal link sit at the top left, under the clock.
            assert legal["y"] < 160 and legal["y"] + legal["height"] < panel_top, f"Legal link is not at the top: {legal}"
            current = find("Current location", "GenericElement")["frame"]
            assert all(abs(a - b) <= 1 for a, b in zip(marker_center(current), marker_center(location_frame))), "Current location moved with drawer"

        check_map_clearance()
        drag_panel(600)
        collapsed = find("Controls panel")
        assert collapsed["frame"]["y"] > 700, "Panel did not collapse"
        assert not find("Stop Tracking", "Button"), "Collapsed panel exposes hidden actions"
        assert find("Tracker", "Button") and find("Trip", "Button") and find("Settings", "Button")
        check_map_clearance()
        drag_panel(-700)
        expanded = find("Controls panel")
        # The compact Tracker drawer opens about 145 points above its closed tab strip.
        assert expanded["frame"]["y"] < collapsed["frame"]["y"] - 100, "Panel did not open"
        assert 250 < expanded["frame"]["y"] < 650, "Panel does not fit its controls"
        check_map_clearance()
        action = find("Stop Tracking", "Button")["frame"]
        tabs = find("Tracker", "Button")["frame"]
        assert action["y"] + action["height"] < tabs["y"], "Tracking action overlaps tabs"
        assert tabs["y"] - action["y"] - action["height"] < 50, "Panel leaves empty space below its actions"
        drag_panel(700)
        tap("Tracker")
        assert find("Stop Tracking", "Button"), "Tab did not reopen controls"
        checks.append("Drawer collapses to tabs and opens over a fixed map; map controls sit at top right")
        print(checks[-1], flush=True)

        tap("Stop Tracking")
        wait_for(lambda: find("Keep Tracking", "Button"), "Stop confirmation missing")
        tap("Keep Tracking")
        assert find("Stop Tracking", "Button"), "Cancel stopped tracking"
        checks.append("Main stop confirmation preserves tracking when canceled")
        print(checks[-1], flush=True)
        tap("Trip")
        tap("Trip Settings")
        assert find("Trip Settings", "Heading"), "Trip Settings did not open"
        tap("Done")
        assert find("Start Trip", "Button"), "Closing Trip Settings did not return to the Trip drawer"
        tap("Show My Location")
        checks.append("Trip Settings opens as a sheet over the Trip drawer and closes back to it")
        tap("Start Trip")
        wait_for(lambda: find("Stop Trip", "Button"), "Trip did not start")
        route = subprocess.Popen(["xcrun", "simctl", "location", udid, "start", "--speed=12", "--interval=1",
                                  "45.5152,-122.6784", "45.5182,-122.6784", "45.5182,-122.6724"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: len([e for e in state() if e.get("type") == "Button"
                              and re.search(r"\d{1,2}:\d{2}:\d{2}", e.get("AXLabel") or "")]) >= 2,
                 "Trip timeline did not receive the first route points")
        drag_panel(600)
        assert not find("Stop Trip", "Button"), "Collapsed Trip panel exposes its controls"

        def coordinates():
            with lock:
                return {tuple(f["geometry"]["coordinates"]) for r in requests for f in r["body"].get("locations", [])
                        if (f.get("geometry") or {}).get("type") == "Point"}

        wait_for(lambda: len(coordinates()) >= 6, "Simulated route did not reach server", timeout=75)
        tap("Trip")
        checks.append("Trip continues recording while its controls are collapsed")
        with sqlite3.connect(history_path) as db:
            ids = [row[0] for row in db.execute("SELECT id FROM points")]
        assert ids and min(ids) > 4001, "History reused an expired ID and would miss new replay points"
        checks.append("Replay migrates legacy records unchanged and preserves increasing IDs after expiry")
        with lock:
            snapshots = list(requests)
        failed = snapshots[0]["body"]["locations"]
        assert snapshots[0]["status"] == 503
        assert len(snapshots) > 1 and snapshots[1]["time"] - snapshots[0]["time"] >= 7.8, "Retry-After was ignored"
        checks.append("503 Retry-After prevents early retries")
        def record_key(feature):
            properties = feature.get("properties", {})
            geometry = feature.get("geometry") or {}
            return (properties.get("timestamp"), properties.get("action"), tuple(geometry.get("coordinates", [])))
        failed_keys = {record_key(f) for f in failed}
        assert any(failed_keys <= {record_key(f) for f in r["body"].get("locations", [])}
                   for r in snapshots[1:] if r["status"] == 200), "Failed upload lost records"
        assert any(f.get("properties", {}).get("trip_id") for r in snapshots for f in r["body"].get("locations", [])), "Trip data missing from upload"
        wait_for(lambda: find("Current location"), "Current location annotation missing")
        assert find("Live"), "Trip timeline missing"
        checks.extend(["Simulated route reaches local server with at least six distinct coordinates",
                       "503 failure preserves records for successful retry", "Trip records carry trip metadata and timeline is live",
                       "Current location annotation is present"])

        def single_map():
            maps = [e for e in state() if e.get("subrole") == "AXMapArea"]
            assert len(maps) == 1, f"Expected one map, found {len(maps)}"

        single_map()
        timeline = [e for e in state() if e.get("type") == "Button"
                    and re.search(r"\d{1,2}:\d{2}:\d{2}", e.get("AXLabel") or "")
                    and 0 <= e["frame"]["x"] < 300]
        assert timeline, "No recorded points in trip timeline"
        frame = timeline[0]["frame"]
        ui("tap", str(round(frame["x"] + frame["width"] / 2)), str(round(frame["y"] + frame["height"] / 2)))
        wait_for(lambda: find("Trip point"), "Historical trip marker missing")
        assert find("Live", "Button"), "Historical selection did not offer return to Live"
        def freeze_route():
            if route.poll() is None:
                route.terminate()
                route.wait(timeout=5)
            # The simulator keeps the scenario running after the simctl process exits.
            with sqlite3.connect(history_path) as db:
                latitude, longitude = db.execute(
                    "SELECT latitude, longitude FROM points ORDER BY timestamp DESC, id DESC LIMIT 1"
                ).fetchone()
            run("xcrun", "simctl", "location", udid, "set", f"{latitude},{longitude}")

        def check_historical_camera(marker_label):
            # The camera rises only enough to keep a selected point clear of an open drawer, so
            # markers move together, vertically and by a bounded amount, at the same scale.
            # Replay hides the live dot, so only markers on screen are compared.
            labels = tuple(label for label in ("Current location", marker_label)
                           if find(label, "GenericElement" if label == "Current location" else None))
            assert marker_label in labels, f"{marker_label} missing before the drawer moved"

            def centers():
                return {label: marker_center(find(label, "GenericElement" if label == "Current location" else None)["frame"])
                        for label in labels}

            before = centers()
            for step, action in (("collapse", lambda: drag_panel(700)), ("expansion", lambda: tap("Controls panel"))):
                action()
                after = centers()
                deltas = [(after[label][0] - before[label][0], after[label][1] - before[label][1]) for label in labels]
                assert all(abs(dx) <= 1 and abs(dy) <= 60 for dx, dy in deltas) and abs(deltas[0][1] - deltas[-1][1]) <= 1, \
                    f"Markers moved apart, sideways or too far on historical {step}: {deltas}"

        freeze_route()
        # The live dot glides to the frozen fix, so wait until it holds still.
        last_frame = None
        stable_since = time.monotonic()
        wait_for(map_settled, "Current location did not settle after the route froze")
        check_historical_camera("Trip point")
        checks.append("Trip scrub camera holds position and scale while the drawer resizes")
        tap("Tracker")
        single_map()
        assert find("Stop Tracking", "Button")
        assert not find("Trip point"), "Trip marker remained on Tracker"
        tap("Trip")
        single_map()
        assert find("Trip point"), "Tab switch lost the selected trip point"
        tap("Live")
        wait_for(lambda: find("Current location"), "Live did not restore user location")
        assert not find("Trip point"), "Live left historical marker visible"
        checks.append("One map switches panels and preserves trip timeline selection")

        # Keep longitude constant so the marker's horizontal position tests the camera.
        freeze_route()
        route = subprocess.Popen(["xcrun", "simctl", "location", udid, "start", "--speed=0.1", "--interval=1",
                                  "45.5182,-122.6724", "45.5183,-122.6724"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tap("Tracker")
        # Location details start collapsed.
        if find("Show location details", "Button"):
            tap("Show location details")
        wait_for(lambda: find("45.5182, -122.6724"), "Tracker did not display the injected location")
        checks.append("Tracker displays the updated simulator coordinates")
        freeze_route()
        ruler = find("Location history ruler")["frame"]
        x = round(ruler["x"] + ruler["width"] / 2)
        y = round(ruler["y"] + ruler["height"] / 2)
        ui("swipe", str(x), str(y), str(x + 120), str(y), "--duration", "0.8", "--delta", "5")
        wait_for(lambda: find("Recorded point"), "Replay marker missing")
        time.sleep(2)
        check_historical_camera("Recorded point")
        checks.append("Replay camera holds position and scale while the drawer resizes")
        # Only the ruler's Live action leaves replay.
        tap("Return to Live")
        tap("Trip")
        tap("Show My Location")
        ui("swipe", "180", "260", "260", "260", "--duration", "0.6")
        time.sleep(1)
        marker = find("Current location")
        assert marker, "Current location missing after short pan"
        pan_x = marker["frame"]["x"]
        tap("Tracker")
        tap("Trip")
        single_map()
        marker = find("Current location")
        assert marker and abs(marker["frame"]["x"] - pan_x) < 8, "Tab switch reset the panned map"
        checks.append("Switching Tracker and Trip preserves the panned map position")

        tap("Stop Trip")
        wait_for(lambda: find("Start Trip", "Button"), "Trip did not end")
        def trip_summary_sent():
            with lock:
                return any(f.get("properties", {}).get("type") == "trip"
                           for request in requests if request["status"] == 200
                           for f in request["body"].get("locations", []))
        wait_for(trip_summary_sent, "Trip-end flush did not deliver the summary")
        checks.append("Trip-end flush delivers the summary without another location")
        tap("Tracker")
        assert find("Stop Tracking", "Button"), "Trip did not restore earlier tracking state"
        tap("Stop Tracking")
        tap("Stop Tracking", last=True)
        wait_for(lambda: find("Start Tracking", "Button"), "Confirmed stop did not stop tracking")
        checks.append("Ending trip restores tracking; explicit stop confirmation stops it")
        environment = dict(os.environ, SIM="Overland Fake Route", SIM_UDID=udid,
                           IDB_COMPANION=f"localhost:{port}", CAPTURE_SCREENSHOTS="0")
        subprocess.run(["python3", str(Path(__file__).with_name("idb_ui_test.py"))],
                       env=environment, check=True, timeout=240)
        checks.append("Settings navigation and exact numeric editing pass; the edited value is restored")
        subprocess.run(["python3", str(Path(__file__).with_name("ui_layout_audit.py")), udid,
                        "--output", str(args.output.with_suffix(".layout.json"))],
                       env=environment, check=True, timeout=900)
        checks.append("Panel, tab gestures, Settings clearance, and accessibility text checks pass")
        completed = True
        print("PASS: " + "; ".join(checks), flush=True)
    except Exception:
        if companion:
            try:
                args.output.with_suffix(".accessibility.json").write_text(json.dumps(state(), indent=2))
            except Exception:
                pass
        raise
    finally:
        args.output.write_text(json.dumps({"checks": checks, "requests": requests}, indent=2))
        if route and route.poll() is None:
            route.terminate()
            route.wait(timeout=5)
        if companion:
            companion.terminate()
            try:
                companion.wait(timeout=5)
            except subprocess.TimeoutExpired:
                companion.kill()
                companion.wait(timeout=5)
        if runtime_stream:
            runtime_stream.terminate()
            try:
                runtime_stream.wait(timeout=5)
            except subprocess.TimeoutExpired:
                runtime_stream.kill()
                runtime_stream.wait(timeout=5)
        if runtime_log:
            runtime_log.close()
        server.shutdown()
        server.server_close()
        subprocess.run(["xcrun", "simctl", "shutdown", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if (completed or not args.keep_on_failure) and (not existing or existing["name"] == "Overland Fake Route"):
            subprocess.run(["xcrun", "simctl", "delete", udid], check=True)
            print(f"Removed isolated simulator; results: {args.output}", flush=True)
        else:
            print(f"Kept stopped simulator {udid}; results: {args.output}", flush=True)


if __name__ == "__main__":
    main()
