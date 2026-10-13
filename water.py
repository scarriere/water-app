#!/usr/bin/env python3
"""A small, dependency-free daily water tracker."""

import argparse
import fcntl
from contextlib import contextmanager
from datetime import date, datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import select
import sys
import tempfile
import termios
import time
import tty
import uuid

GOAL_ML = 2700
GLASS_ML = 355
BOTTLE_ML = 3000
ROWS = 15
WIDTH = 20
BLUE = "\033[94m"
TOKEN_COLOR = "\033[95m"
RESET = "\033[0m"
TOKEN_WATER_ML_PER_1000 = 0.7  # Illustrative conversion, not measured water use.
PI_REFRESH_SECONDS = 5
BOTTLE_DISPLAY_WIDTH = 14 + WIDTH + 2
ANSI_COLOR = re.compile(r"\033\[[0-9;]*m")


class PiTokenTracker:
    """Read today's reported Pi output tokens from append-only session JSONL files."""

    def __init__(self, root=None):
        config = Path(os.environ.get("PI_CODING_AGENT_DIR") or Path.home() / ".pi" / "agent")
        self.root = Path(root or os.environ.get("PI_CODING_AGENT_SESSION_DIR") or config / "sessions")
        self.day = None
        self.files = {}
        self.total = 0

    @staticmethod
    def tokens_for_entry(entry, today):
        timestamp = entry.get("timestamp")
        if not isinstance(timestamp, str):
            return 0
        try:
            recorded = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            if recorded.tzinfo is None or recorded.astimezone().date() != today:
                return 0
        except ValueError:
            return 0

        kind = entry.get("type")
        if kind == "message":
            message = entry.get("message")
            if not isinstance(message, dict) or message.get("role") not in ("assistant", "toolResult"):
                return 0
            usage = message.get("usage")
        elif kind in ("compaction", "branch_summary"):
            usage = entry.get("usage")
        else:
            return 0
        if not isinstance(usage, dict):
            return 0
        # Pi reports output separately from input and cached tokens.
        reported = usage.get("output")
        return reported if type(reported) is int and reported >= 0 else 0

    def poll(self, today):
        if self.day != today:
            self.day, self.files = today, {}
        start_of_day = datetime.combine(today, datetime.min.time()).timestamp()
        seen = set()
        if not self.root.is_dir():
            self.files.clear()
            self.total = 0
            return 0
        for path in self.root.rglob("*.jsonl"):
            try:
                stat = path.stat()
                if stat.st_mtime < start_of_day:
                    continue
                seen.add(path)
                state = self.files.get(path)
                if state is None or state["inode"] != stat.st_ino or stat.st_size < state["offset"]:
                    state = {"inode": stat.st_ino, "offset": 0, "size": -1, "mtime": -1, "tokens": 0}
                if (state["size"], state["mtime"]) != (stat.st_size, stat.st_mtime_ns):
                    with path.open("rb") as session:
                        session.seek(state["offset"])
                        while True:
                            position = session.tell()
                            line = session.readline()
                            if not line or not line.endswith(b"\n"):
                                state["offset"] = position  # Retry an incomplete last line later.
                                break
                            state["offset"] = session.tell()
                            try:
                                entry = json.loads(line)
                                if isinstance(entry, dict):
                                    state["tokens"] += self.tokens_for_entry(entry, today)
                            except (ValueError, UnicodeDecodeError):
                                continue
                    state["size"], state["mtime"] = stat.st_size, stat.st_mtime_ns
                self.files[path] = state
            except OSError:
                continue  # A session may be deleted or rotated during a refresh.
        for path in self.files.keys() - seen:
            del self.files[path]
        self.total = sum(state["tokens"] for state in self.files.values())
        return self.total


def pi_bottle_scale(ml):
    """Select readable 1/2/2.5/5 increments instead of capping a busy Pi day at 3 L."""
    if ml <= BOTTLE_ML:
        return BOTTLE_ML, 500
    magnitude = 10 ** math.floor(math.log10(ml / 6))
    for factor in (1, 2, 2.5, 5, 10):
        step = int(factor * magnitude)
        if step * 6 >= ml:
            return step * 6, step
    raise AssertionError("Pi bottle scale could not be calculated")


def volume_label(ml):
    if ml >= 10_000:
        return f"{ml / 1_000:,.0f} L"
    return f"{ml:,.0f} ml"


def state_path(day=None):
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    return base / "water-cli" / f"{(day or date.today()).isoformat()}.json"


def load_record(path, today):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"date": today.isoformat(), "ml": 0, "drinks": []}
    if not isinstance(data, dict) or not isinstance(data.get("date"), str) or (
        type(data.get("ml")) is not int or data["ml"] < 0
    ):
        raise ValueError(f"Invalid water tracker data in {path}")
    drinks = data.get("drinks", [])  # Files from before reminders have only date + ml.
    if not isinstance(drinks, list):
        raise ValueError(f"Invalid water tracker data in {path}")
    logged = 0
    ids = set()
    for drink in drinks:
        if (
            not isinstance(drink, dict)
            or type(drink.get("ml")) is not int
            or drink["ml"] <= 0
            or not isinstance(drink.get("at"), str)
        ):
            raise ValueError(f"Invalid water tracker data in {path}")
        try:
            timestamp = datetime.fromisoformat(drink["at"].replace("Z", "+00:00"))
            if timestamp.tzinfo is None:
                raise ValueError("Timestamp must have a timezone")
        except ValueError as exc:
            raise ValueError(f"Invalid water tracker data in {path}") from exc
        if "id" in drink:
            try:
                identifier = str(uuid.UUID(drink["id"]))
            except (ValueError, TypeError, AttributeError) as exc:
                raise ValueError(f"Invalid water tracker data in {path}") from exc
            if identifier in ids:
                raise ValueError(f"Invalid water tracker data in {path}")
            ids.add(identifier)
        logged += drink["ml"]
        if logged > data["ml"]:
            raise ValueError(f"Invalid water tracker data in {path}")
    if data["date"] != today.isoformat():
        return {"date": today.isoformat(), "ml": 0, "drinks": []}
    return {"date": data["date"], "ml": data["ml"], "drinks": drinks}


def load_today(path, today):
    return load_record(path, today)["ml"]


def write_record(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Replace atomically so an interrupted write cannot destroy the day's total.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=".today-", delete=False
        ) as file:
            temporary = Path(file.name)
            json.dump(data, file)
            file.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


@contextmanager
def day_lock(path):
    """Coordinate read-modify-write with the macOS app (atomic rename alone is insufficient)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def save_today(path, today, ml=None, drink_at=None):
    with day_lock(path):
        data = load_record(path, today)
        if drink_at is not None:
            data["ml"] += GLASS_ML
            data["drinks"].append({"at": drink_at, "ml": GLASS_ML, "id": str(uuid.uuid4())})
        else:
            if type(ml) is not int or ml < 0:
                raise ValueError("The saved water amount must be a non-negative integer")
            data["ml"] = ml
            if ml == 0:
                data["drinks"] = []
        write_record(path, data)
        return data["ml"]


def remove_glass(path, today):
    """Undo the newest logged glass, or an untimed legacy glass if necessary."""
    with day_lock(path):
        data = load_record(path, today)
        if data["ml"] < GLASS_ML:
            return None
        index = next(
            (i for i in range(len(data["drinks"]) - 1, -1, -1)
             if data["drinks"][i]["ml"] == GLASS_ML),
            None,
        )
        if index is not None:
            data["drinks"].pop(index)
        elif data["ml"] - sum(drink["ml"] for drink in data["drinks"]) < GLASS_ML:
            return None  # Only non-glass drinks remain; don't discard their history.
        data["ml"] -= GLASS_ML
        write_record(path, data)
        return data["ml"]


def bottle(ml, pouring=False, color=False, fill_color=BLUE, show_goal=True,
           capacity_ml=BOTTLE_ML, mark_step=500):
    """Draw a scaled bottle; a ~ row shows a partially filled slice."""
    def water(text):
        return f"{fill_color}{text}{RESET}" if color else text

    pad = " " * 14
    stream = " " * (WIDTH // 2 - 1) + "||" + " " * (WIDTH // 2 - 1)
    lines = [
        pad + "         ____",
        pad + ("        |" + water(" || ") + "|" if pouring else "        |____|"),
        pad + ("   /" + water("      ||      ") + "\\" if pouring else "   /              \\"),
        f"{(volume_label(capacity_ml) + ' ---'):>13} +{'-' * WIDTH}+",
    ]
    row_ml = capacity_ml / ROWS
    marks = {
        round((capacity_ml - mark) / row_ml - 0.5): mark
        for mark in range(mark_step, capacity_ml, mark_step)
    }
    shown = min(ml, capacity_ml)
    for row in range(ROWS):
        high = capacity_ml - row * row_ml
        low = high - row_ml
        if shown >= high:
            inside = "#" * WIDTH
        elif shown > low:
            inside = "~" * WIDTH
        elif pouring:
            inside = stream
        else:
            inside = " " * WIDTH
        if shown > low or pouring:
            inside = water(inside)

        center = high - row_ml / 2
        if show_goal and center == GOAL_ML:
            label = "GOAL 2.7 L >"
        elif row in marks:
            label = f"{volume_label(marks[row])} ---"
        else:
            label = ""
        lines.append(f"{label:>13} |{inside}|")
    lines.append(f"{'0 ml ---':>13} +{'-' * WIDTH}+")
    return "\n".join(lines)


def screen(ml, today, pouring=False, color=False, pi_tokens=0):
    remaining = GOAL_ML - ml
    progress = f"{ml:,} / {GOAL_ML:,} ml ({ml / GOAL_ML:.0%})"
    status = f"{remaining:,} ml to go" if remaining > 0 else "Daily goal reached!"
    if ml > BOTTLE_ML:
        status += " (bottle display capped at 3 L)"
    equivalent_ml = pi_tokens * TOKEN_WATER_ML_PER_1000 / 1_000
    pi_capacity, pi_step = pi_bottle_scale(equivalent_ml)
    left = bottle(ml, pouring, color).splitlines()
    right = bottle(equivalent_ml, color=color, fill_color=TOKEN_COLOR,
                   show_goal=False, capacity_ml=pi_capacity, mark_step=pi_step).splitlines()
    bottles = "\n".join(
        left_line + " " * (BOTTLE_DISPLAY_WIDTH - len(ANSI_COLOR.sub("", left_line)) + 3) + right_line
        for left_line, right_line in zip(left, right)
    )
    labels = (
        f"{('WATER ' + today.isoformat()):^{BOTTLE_DISPLAY_WIDTH}}"
        f"   {'PI OUTPUT (ILLUSTRATIVE)':^{BOTTLE_DISPLAY_WIDTH}}"
    )
    pi_amount = f"{equivalent_ml / 1_000:,.1f} L" if equivalent_ml >= 10_000 else f"{equivalent_ml:,.0f} ml"
    pi_status = f"Pi output: {pi_tokens:,} tokens -> ~{pi_amount} ({TOKEN_WATER_ML_PER_1000} ml/1k; illustrative)"
    return (
        f"{labels}\n{bottles}\nToday: {progress} - {status}\n{pi_status}\n"
        "[a] Add (+355 ml)  [r] Remove (-355 ml)  [q] Quit"
    )


def display(text, interactive):
    if interactive:
        sys.stdout.write("\033[H\033[2J" + text)
        sys.stdout.flush()
    else:
        print(text, flush=True)


def animate(start, end, today, color=True, pi_tokens=0):
    # Show a stream from the bottle neck while the water rises to the exact total.
    sys.stdout.write("\033[?25l")
    try:
        for step in range(1, 13):
            amount = start + (end - start) * step // 12
            display(screen(amount, today, pouring=True, color=color, pi_tokens=pi_tokens), interactive=True)
            time.sleep(0.055)
    finally:
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()


@contextmanager
def single_key_mode():
    """Read one key at a time without echo; always restore terminal settings."""
    fd = sys.stdin.fileno()
    previous = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, previous)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Track daily water alongside Pi token usage in two ASCII bottles.",
        epilog=("Pi usage sums today's reported output tokens (excluding input and cache) across saved sessions. "
                f"The right bottle uses an illustrative {TOKEN_WATER_ML_PER_1000} ml per 1,000 tokens, "
                "not measured water use. "
                "Set PI_CODING_AGENT_SESSION_DIR to override Pi's session directory."),
    )
    parser.add_argument("--add", action="store_true", help="add one 355 ml glass and exit")
    parser.add_argument("--remove", action="store_true", help="remove one 355 ml glass and exit")
    parser.add_argument("--reset", action="store_true", help="reset today's total to zero")
    parser.add_argument("--no-animation", action="store_true", help="skip the pouring animation")
    args = parser.parse_args(argv)
    if sum((args.add, args.remove, args.reset)) > 1:
        parser.error("--add, --remove, and --reset cannot be used together")

    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    color = interactive and "NO_COLOR" not in os.environ
    try:
        today = datetime.now().astimezone().date()
        path = state_path(today)
        ml = load_today(path, today)
        tracker = PiTokenTracker()
        pi_tokens = tracker.poll(today)
        if args.reset:
            ml = 0
            save_today(path, today, ml)
        if args.add or args.remove:
            now = datetime.now().astimezone()
            if now.date() != today:
                today = now.date()
                path = state_path(today)
                ml = load_today(path, today)
                pi_tokens = tracker.poll(today)
            if args.add:
                timestamp = now.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
                new_ml = save_today(path, today, drink_at=timestamp)
                if interactive and not args.no_animation:
                    animate(ml, new_ml, today, color=color, pi_tokens=pi_tokens)
            else:
                new_ml = remove_glass(path, today)
                if new_ml is None:
                    print("No glass to remove today.", file=sys.stderr)
                    return 1
            ml = new_ml

        pi_tokens = tracker.poll(today)
        if args.add or args.remove or args.reset or not interactive:
            display(screen(ml, today, color=color, pi_tokens=pi_tokens), interactive)
            return 0

        with single_key_mode():
            display(screen(ml, today, color=color, pi_tokens=pi_tokens), interactive=True)
            while True:
                ready, _, _ = select.select([sys.stdin], [], [], PI_REFRESH_SECONDS)
                now = datetime.now().astimezone()
                if now.date() != today:
                    today = now.date()
                    path = state_path(today)
                    ml = load_today(path, today)
                    pi_tokens = tracker.poll(today)
                    display(screen(ml, today, color=color, pi_tokens=pi_tokens), interactive=True)
                if not ready:
                    new_tokens = tracker.poll(today)
                    new_ml = load_today(path, today)
                    if new_tokens != pi_tokens or new_ml != ml:
                        pi_tokens, ml = new_tokens, new_ml
                        display(screen(ml, today, color=color, pi_tokens=pi_tokens), interactive=True)
                    continue
                choice = sys.stdin.read(1).lower()
                if choice in ("q", ""):
                    return 0
                if choice in ("a", "r"):
                    if choice == "a":
                        timestamp = now.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
                        new_ml = save_today(path, today, drink_at=timestamp)
                        if not args.no_animation:
                            animate(ml, new_ml, today, color=color, pi_tokens=pi_tokens)
                    else:
                        new_ml = remove_glass(path, today)
                        if new_ml is None:
                            print("\nNo glass to remove today.")
                            continue
                    ml = new_ml
                    pi_tokens = tracker.poll(today)
                    display(screen(ml, today, color=color, pi_tokens=pi_tokens), interactive=True)
    except KeyboardInterrupt:
        print("\nBye!")
        return 130
    except (OSError, ValueError) as exc:
        print(f"water: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
