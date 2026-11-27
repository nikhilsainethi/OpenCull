#!/usr/bin/env python3
"""Run the complete macOS suite with live output and bounded hang diagnostics."""
import argparse
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def descendants(root):
    """Only descendants of the test command we started qualify for sampling/signals."""
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True, check=True)
    rows = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    known, ordered = {root}, []
    while True:
        added = [(pid, command) for pid, parent, command in rows if parent in known and pid not in known]
        if not added:
            return ordered
        ordered.extend(added)
        known.update(pid for pid, _ in added)


def diagnose(process):
    folder = Path("ci-diagnostics")
    folder.mkdir(exist_ok=True)
    rows = descendants(process.pid)
    (folder / "test-processes.txt").write_text("\n".join(f"{pid} {command}" for pid, command in rows) + "\n")
    for pid, command in rows:
        if Path(command).name != "xctest":
            continue
        destination = folder / f"xctest-{pid}.sample.txt"
        print(f"Sampling test descendant {pid}: {destination}", flush=True)
        try:
            subprocess.run(["/usr/bin/sample", str(pid), "3", "-file", str(destination)], timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"Could not sample test descendant: {error}", flush=True)


def stop(process):
    rows = descendants(process.pid)
    # Signal the captured children before the pseudo-terminal supervisor, so no
    # xctest or SwiftPM child is left behind when that supervisor exits.
    for pid in [pid for pid, _ in reversed(rows)] + [process.pid]:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        # Recheck ancestry before escalating; never target unrelated processes.
        for pid in [pid for pid, _ in reversed(descendants(process.pid))] + [process.pid]:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    if not math.isfinite(options.timeout) or options.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    command = options.command or ["swift", "test"]
    if command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    env = os.environ.copy()
    env["NSUnbufferedIO"] = "YES"
    # macOS script gives XCTest a TTY, preventing its buffered stdout from hiding
    # the actual waiting test. script preserves the child's nonzero exit status.
    process = subprocess.Popen(["/usr/bin/script", "-q", "/dev/null", *command],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + options.timeout
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(f"\nTest command exceeded {options.timeout:g} seconds; collecting diagnostics before failing.", flush=True)
                diagnose(process)
                stop(process)
                return 124
            for key, _ in selector.select(timeout=min(0.2, remaining)):
                chunk = os.read(key.fileobj.fileno(), 65_536)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
        return process.wait(timeout=max(0.1, deadline - time.monotonic()))
    except KeyboardInterrupt:
        stop(process)
        return 130
    except subprocess.TimeoutExpired:
        diagnose(process)
        stop(process)
        return 124
    finally:
        selector.close()
        process.stdout.close()


if __name__ == "__main__":
    sys.exit(main())
