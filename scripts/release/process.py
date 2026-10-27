#!/usr/bin/env python3
"""Bound release processes and retry only explicit transient Apple ticket errors."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time


def run_bounded(command, timeout, log_path):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with log_path.open('wb') as log:
        def record(message):
            line = (message + '\n').encode()
            log.write(line)
            log.flush()
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()

        record(json.dumps({'event': 'started', 'command': Path(command[0]).name, 'timeoutSeconds': timeout}))
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)

        def copy_output():
            for line in iter(process.stdout.readline, b''):
                log.write(line)
                log.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()

        reader = threading.Thread(target=copy_output, daemon=True)
        reader.start()
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Record process names only, never command arguments or environment.
            listing = subprocess.run(['ps', '-axo', 'pid,ppid,pgid,stat,etime,comm'], text=True, capture_output=True)
            for line in listing.stdout.splitlines():
                columns = line.split(None, 5)
                if len(columns) == 6 and columns[2] == str(process.pid):
                    record('Timed-out process: ' + line)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            # A helper may outlive the group leader; always close the owned group.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            code = 124
        reader.join(timeout=3)
        record(json.dumps({'event': 'finished', 'exitCode': code, 'elapsedSeconds': round(time.monotonic() - started, 2)}))
    return code


TRANSIENT_NETWORK_CODES = {-1001, -1003, -1004, -1005, -1006, -1009}
NETWORK_ERROR = re.compile(r"(?:Error\s+)?Domain=NSURLErrorDomain\s+Code=(-?\d+)\b")


def run_stapler(operation, path):
    command = ["xcrun", "stapler", operation, str(path)]
    for attempt in range(1, 5):
        print(f"stapler {operation}: attempt {attempt}/4", flush=True)
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=120, check=False)
        except subprocess.TimeoutExpired as error:
            if error.stdout:
                print(error.stdout.decode("utf-8", errors="replace"), end="", flush=True)
            print("stapler exceeded its 120-second deadline; validation failed.", file=sys.stderr)
            return 124
        output = result.stdout.decode("utf-8", errors="replace")
        print(output, end="", flush=True)
        if result.returncode == 0:
            return 0
        # EX_NOHOST (68) is also used for nonnetwork ticket errors. Never retry
        # based on the exit code alone, nor suppress failed ticket validation.
        codes = {int(value) for value in NETWORK_ERROR.findall(output)}
        retryable = result.returncode == 68 and bool(codes) and codes <= TRANSIENT_NETWORK_CODES
        if not retryable or attempt == 4:
            return result.returncode if result.returncode > 0 else 1
        delay = (15, 45, 90)[attempt - 1]
        print(f"Transient Apple ticket-server network error; retrying in {delay} seconds.", flush=True)
        time.sleep(delay)
    raise AssertionError("unreachable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    bounded = actions.add_parser("run", help="Run one command with a process-group deadline")
    bounded.add_argument("--timeout", type=float, required=True)
    bounded.add_argument("--log", type=Path, required=True)
    bounded.add_argument("command", nargs=argparse.REMAINDER)
    for operation in ("staple", "validate"):
        actions.add_parser(operation).add_argument("path")
    args = parser.parse_args()
    if args.action == "run":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command or args.timeout <= 0:
            parser.error("A command and positive timeout are required")
        return run_bounded(command, args.timeout, args.log)
    return run_stapler(args.action, args.path)


if __name__ == "__main__":
    sys.exit(main())
