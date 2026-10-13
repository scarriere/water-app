"""Tests for the standalone water tracker."""

from datetime import date, datetime, timedelta
import io
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import water


class BottleTests(unittest.TestCase):
    def test_graduations_and_goal(self):
        drawing = water.bottle(0)
        for mark in (0, 500, 1000, 1500, 2000, 2500, 3000):
            self.assertIn(f"{mark:,} ml ---", drawing)
        self.assertIn("GOAL 2.7 L >", drawing)

    def test_glass_fills_exact_amount_with_partial_surface(self):
        drawing = water.bottle(355)
        self.assertEqual(drawing.count("|" + "#" * water.WIDTH + "|"), 1)
        self.assertEqual(drawing.count("|" + "~" * water.WIDTH + "|"), 1)
        colored = water.bottle(355, color=True)
        self.assertIn(water.BLUE + "#" * water.WIDTH + water.RESET, colored)
        self.assertIn(water.BLUE + "~" * water.WIDTH + water.RESET, colored)
        self.assertNotIn(water.BLUE + "2,500 ml", colored)
        self.assertIn("355 / 2,700 ml", water.screen(355, date.today()))
        self.assertIn("Daily goal reached!", water.screen(2840, date.today()))
        self.assertIn("bottle display capped", water.screen(3195, date.today()))
        rendered = water.screen(355, date.today(), pi_tokens=100_000)
        self.assertIn("PI OUTPUT (ILLUSTRATIVE)", rendered)
        self.assertIn("Pi output: 100,000 tokens -> ~70 ml (0.7 ml/1k; illustrative)", rendered)
        self.assertEqual(len(rendered.splitlines()), 24)
        self.assertEqual(len(rendered.splitlines()[4]), 75)
        self.assertEqual(water.pi_bottle_scale(85_820), (120_000, 20_000))
        scaled = water.screen(355, date.today(), color=True, pi_tokens=122_600_000)
        self.assertIn("120 L ---", scaled)
        self.assertIn("Pi output: 122,600,000 tokens -> ~85.8 L", scaled)
        self.assertIn(water.TOKEN_COLOR, scaled)
        self.assertEqual(len(scaled.splitlines()), 24)

    def test_stream_and_animation_end_at_355(self):
        self.assertIn("|" + " " * 9 + "||" + " " * 9 + "|", water.bottle(0, pouring=True))
        with patch.object(water, "display") as display, patch.object(water.time, "sleep"), patch.object(
            water.sys, "stdout", io.StringIO()
        ):
            water.animate(0, 355, date.today())
        self.assertEqual(display.call_count, 12)
        self.assertIn("Today: 355 / 2,700 ml", display.call_args.args[0])


class PiTokenTests(unittest.TestCase):
    def test_pi_jsonl_totals_and_incremental_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = root / "project" / "session.jsonl"
            session.parent.mkdir()
            today = date.today()
            stamp = datetime.now().astimezone().isoformat()
            yesterday = (datetime.now().astimezone() - timedelta(days=1)).isoformat()

            def entry(kind, usage, when=stamp, role="assistant"):
                data = {"type": kind, "timestamp": when}
                if kind == "message":
                    data["message"] = {"role": role, "usage": usage}
                else:
                    data["usage"] = usage
                return json.dumps(data).encode() + b"\n"

            with session.open("wb") as f:
                f.write(entry("message", {"input": 300, "output": 1000, "cacheRead": 50_000,
                                          "totalTokens": 51_300}))
                f.write(entry("message", {"input": 30, "output": 20, "cacheRead": 50}, role="toolResult"))
                f.write(entry("compaction", {"output": 120, "cacheRead": 80, "totalTokens": 200}))
                f.write(entry("branch_summary", {"output": 60, "totalTokens": 100}))
                f.write(entry("message", {"cacheRead": 9000, "totalTokens": 9000}))
                f.write(entry("message", {"output": 5000}, role="user"))
                f.write(entry("message", {"output": 9000}, when=yesterday))
            tracker = water.PiTokenTracker(root)
            self.assertEqual(tracker.poll(today), 1200)
            self.assertEqual(tracker.poll(today), 1200)  # Do not double-count unchanged files.
            addition = entry("message", {"output": 600, "cacheWrite": 1000, "totalTokens": 1600})
            with session.open("ab") as f:
                f.write(addition[:-1])  # Pi may still be writing the last line.
            self.assertEqual(tracker.poll(today), 1200)
            with session.open("ab") as f:
                f.write(b"\n")
            self.assertEqual(tracker.poll(today), 1800)

            old_file = root / "yesterday.jsonl"
            old_file.write_bytes(entry("message", {"output": 8000}))
            old = datetime.combine(today - timedelta(days=1), datetime.min.time()).timestamp()
            os.utime(old_file, (old, old))
            self.assertEqual(tracker.poll(today), 1800)
            self.assertEqual(tracker.poll(today + timedelta(days=1)), 0)
            session.unlink()
            self.assertEqual(tracker.poll(today), 0)

    def test_missing_session_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            tracker = water.PiTokenTracker(Path(directory) / "nonexistent")
            self.assertEqual(tracker.poll(date.today()), 0)

    def test_interactive_pi_refreshes_without_a_keypress(self):
        with tempfile.TemporaryDirectory() as directory:
            sessions = Path(directory) / "pi-sessions"
            sessions.mkdir()
            master, slave = pty.openpty()
            process = subprocess.Popen(
                [sys.executable, str(Path(water.__file__)), "--no-animation"],
                stdin=slave, stdout=slave, stderr=slave,
                env={**os.environ, "XDG_STATE_HOME": directory,
                     "PI_CODING_AGENT_SESSION_DIR": str(sessions)},
            )
            os.close(slave)

            def read_until(needle):
                output = b""
                deadline = time.monotonic() + 8
                while needle not in output and time.monotonic() < deadline:
                    readable, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
                    if readable:
                        output += os.read(master, 4096)
                self.assertIn(needle, output)

            try:
                read_until(b"Pi output: 0 tokens")
                stamp = datetime.now().astimezone().isoformat()
                (sessions / "new.jsonl").write_text(json.dumps({
                    "type": "message", "timestamp": stamp,
                    "message": {"role": "assistant", "usage": {"output": 1_000, "cacheRead": 2_000,
                                                              "totalTokens": 3_000}},
                }) + "\n")
                read_until(b"Pi output: 1,000 tokens")
                os.write(master, b"q")
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)


class StateTests(unittest.TestCase):
    def test_daily_state_and_reset_on_new_date(self):
        with tempfile.TemporaryDirectory() as directory:
            today = date.today()
            with patch.dict(os.environ, {"XDG_STATE_HOME": directory}):
                path = water.state_path(today)
                tomorrow_path = water.state_path(today + timedelta(days=1))
            self.assertEqual(water.load_today(path, today), 0)
            water.save_today(path, today, 355)
            self.assertEqual(water.load_today(path, today), 355)
            self.assertEqual(water.load_today(tomorrow_path, today + timedelta(days=1)), 0)
            self.assertEqual(json.loads(path.read_text())["ml"], 355)
            self.assertIn(today.isoformat(), path.name)

    def test_invalid_state_does_not_get_silently_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "today.json"
            path.write_text('{"date": "x", "ml": -5}')
            with self.assertRaises(ValueError):
                water.load_today(path, date.today())

    def test_command_line_add_and_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "XDG_STATE_HOME": directory,
                   "PI_CODING_AGENT_SESSION_DIR": str(Path(directory) / "sessions")}
            def run(*args):
                return subprocess.run(
                    [sys.executable, str(Path(water.__file__)), *args],
                    env=env, capture_output=True, text=True, check=True,
                ).stdout

            first = run("--add", "--no-animation")
            self.assertIn("Pi output: 0 tokens", first)
            self.assertIn("355 / 2,700 ml", first)
            self.assertIn("710 / 2,700 ml", run("--add", "--no-animation"))
            self.assertIn("710 / 2,700 ml", run())
            path = Path(directory) / "water-cli" / f"{date.today().isoformat()}.json"
            logged = json.loads(path.read_text())
            self.assertEqual(logged["ml"], 710)
            self.assertEqual(len(logged["drinks"]), 2)
            self.assertTrue(all(drink["ml"] == 355 and drink["at"].endswith("Z") for drink in logged["drinks"]))
            self.assertEqual(len({drink["id"] for drink in logged["drinks"]}), 2)
            self.assertIn("355 / 2,700 ml", run("--remove"))
            self.assertEqual(len(json.loads(path.read_text())["drinks"]), 1)
            self.assertIn("0 / 2,700 ml", run("--remove"))
            self.assertEqual(json.loads(path.read_text())["drinks"], [])
            failed = subprocess.run([sys.executable, str(Path(water.__file__)), "--remove"],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1)
            self.assertIn("No glass to remove", failed.stderr)
            self.assertEqual(json.loads(path.read_text())["ml"], 0)
            self.assertIn("355 / 2,700 ml", run("--add", "--no-animation"))
            self.assertIn("0 / 2,700 ml", run("--reset"))
            self.assertEqual(json.loads(path.read_text()), {"date": date.today().isoformat(), "ml": 0, "drinks": []})

    def test_add_preserves_existing_app_drinks_and_legacy_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "water-cli" / f"{date.today().isoformat()}.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"date": date.today().isoformat(), "ml": 355,
                                        "drinks": [{"at": "2025-12-17T19:33:20Z", "ml": 355}]}))
            with patch.dict(os.environ, {"XDG_STATE_HOME": directory}):
                self.assertEqual(water.save_today(path, date.today(), drink_at="2025-12-17T20:00:00Z"), 710)
            record = json.loads(path.read_text())
            self.assertEqual(record["ml"], 710)
            self.assertEqual(len(record["drinks"]), 2)
            self.assertNotIn("id", record["drinks"][0])
            self.assertIn("id", record["drinks"][1])

            path.write_text(json.dumps({"date": date.today().isoformat(), "ml": 1065}))
            self.assertEqual(water.save_today(path, date.today(), drink_at="2025-12-17T20:00:00Z"), 1420)
            self.assertEqual(len(json.loads(path.read_text())["drinks"]), 1)

    def test_remove_last_glass_keeps_other_drinks_and_legacy_amount(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "today.json"
            today = date.today()
            drinks = [
                {"at": "2025-12-17T12:00:00Z", "ml": 355},
                {"at": "2025-12-17T12:30:00Z", "ml": 200},
                {"at": "2025-12-17T13:00:00Z", "ml": 355},
            ]
            path.write_text(json.dumps({"date": today.isoformat(), "ml": 1265, "drinks": drinks}))
            self.assertEqual(water.remove_glass(path, today), 910)
            self.assertEqual(json.loads(path.read_text())["drinks"], drinks[:2])
            self.assertEqual(water.remove_glass(path, today), 555)
            self.assertEqual(json.loads(path.read_text())["drinks"], [drinks[1]])
            self.assertEqual(water.remove_glass(path, today), 200)  # Untimed legacy 355 ml.
            unchanged = path.read_bytes()
            self.assertIsNone(water.remove_glass(path, today))
            self.assertEqual(path.read_bytes(), unchanged)

    def test_cli_reads_pi_sessions_without_exposing_message_content(self):
        with tempfile.TemporaryDirectory() as directory:
            sessions = Path(directory) / "pi-sessions"
            sessions.mkdir()
            stamp = datetime.now().astimezone().isoformat()
            (sessions / "sample.jsonl").write_text(json.dumps({
                "type": "message", "timestamp": stamp,
                "message": {"role": "assistant", "usage": {"output": 100_000,
                            "cacheRead": 900_000, "totalTokens": 1_000_000},
                            "content": "PRIVATE SESSION CONTENT"},
            }) + "\n")
            output = subprocess.run(
                [sys.executable, str(Path(water.__file__))],
                env={**os.environ, "XDG_STATE_HOME": directory,
                     "PI_CODING_AGENT_SESSION_DIR": str(sessions)},
                capture_output=True, text=True, check=True,
            ).stdout
            self.assertIn("Pi output: 100,000 tokens -> ~70 ml", output)
            self.assertNotIn("1,000,000 tokens", output)
            self.assertNotIn("PRIVATE SESSION CONTENT", output)

    def test_one_keypress_adds_and_saves_without_enter(self):
        with tempfile.TemporaryDirectory() as directory:
            master, slave = pty.openpty()
            process = subprocess.Popen(
                [sys.executable, str(Path(water.__file__)), "--no-animation"],
                stdin=slave, stdout=slave, stderr=slave,
                env={**os.environ, "XDG_STATE_HOME": directory,
                     "PI_CODING_AGENT_SESSION_DIR": str(Path(directory) / "sessions")},
            )
            os.close(slave)

            def read_until(needle):
                output = b""
                deadline = time.monotonic() + 5
                while needle not in output and time.monotonic() < deadline:
                    readable, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
                    if readable:
                        output += os.read(master, 4096)
                self.assertIn(needle, output)
                return output

            try:
                read_until(b"[q] Quit")
                os.write(master, b"a")  # No newline / Enter key.
                updated = read_until(b"Today: 355 / 2,700 ml")
                self.assertIn(water.BLUE.encode(), updated)
                path = Path(directory) / "water-cli" / f"{date.today().isoformat()}.json"
                self.assertEqual(json.loads(path.read_text())["ml"], 355)
                os.write(master, b"r")  # One keypress undoes the glass.
                read_until(b"Today: 0 / 2,700 ml")
                self.assertEqual(json.loads(path.read_text())["drinks"], [])
                os.write(master, b"q")
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                os.close(master)


if __name__ == "__main__":
    unittest.main()
