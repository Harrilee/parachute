#!/usr/bin/env python3
"""Run a packaging command with a timeout; terminate only its own process group."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--timeout', type=float, required=True)
parser.add_argument('--log', type=Path, required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ['--'] else args.command
if not command or args.timeout <= 0:
    parser.error('A command and positive timeout are required')
args.log.parent.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
with args.log.open('wb') as log:
    def record(message):
        line = (message + '\n').encode()
        log.write(line)
        log.flush()
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()

    record(json.dumps({'event': 'started', 'command': Path(command[0]).name, 'timeoutSeconds': args.timeout}))
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
        code = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        # Record process names only, never command arguments or environment.
        listing = subprocess.run(['ps', '-axo', 'pid,ppid,pgid,stat,etime,comm'], text=True, capture_output=True)
        for line in listing.stdout.splitlines():
            columns = line.split(None, 5)
            if len(columns) == 6 and columns[2] == str(process.pid):
                record('Timed-out process: ' + line)
        os.killpg(process.pid, signal.SIGTERM)
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
sys.exit(code)
