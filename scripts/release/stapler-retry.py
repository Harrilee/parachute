#!/usr/bin/env python3
"""Retry only explicit transient NSURLError failures from Apple's stapler."""

import argparse
import re
import subprocess
import sys
import time


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
    parser.add_argument("operation", choices=("staple", "validate"))
    parser.add_argument("path")
    args = parser.parse_args()
    return run_stapler(args.operation, args.path)


if __name__ == "__main__":
    sys.exit(main())
