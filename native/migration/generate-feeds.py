#!/usr/bin/env python3
"""Generate the permanent first-native-update feeds; never point these at newer builds."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
for architecture in ("arm64", "x64"):
    payload = {
        "currentRelease": "0.4.0",
        "releases": [{
            "version": "0.4.0",
            "updateTo": {
                "version": "0.4.0",
                "name": "Parachute 0.4.0",
                "notes": "The native macOS version of Parachute.",
                "url": "https://github.com/Harrilee/parachute/releases/download/v0.4.0/"
                       f"Parachute-native-{architecture}-0.4.0.zip",
            },
        }],
    }
    (args.output / f"electron-migration-{architecture}.json").write_text(
        json.dumps(payload, indent=2) + "\n")
