#!/usr/bin/env python3
"""Read a run log: the lines alone (default), or with their details and payloads.

    python3 runlog.py logs/<run>.log              what happened, one line each
    python3 runlog.py logs/<run>.log --details    every line followed by its payload, pretty-printed
    python3 runlog.py --latest                    the newest run log in logs/
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LOGS = Path(__file__).resolve().parents[4] / "logs"


def show(path: Path, details: bool) -> None:
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.lstrip()
        if not stripped.startswith("↳ "):
            print(raw)
            continue
        if not details:
            continue
        payload = stripped[2:]
        try:
            text = json.dumps(json.loads(payload), indent=2, ensure_ascii=False)
        except json.JSONDecodeError:
            text = payload
        for line in text.splitlines():
            print(" " * 16 + line)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file", nargs="?", type=Path)
    parser.add_argument("--details", action="store_true", help="show each line's details and payload")
    parser.add_argument("--latest", action="store_true", help="the newest incident run log")
    args = parser.parse_args()
    path = args.file
    if args.latest or path is None:
        runs = sorted(item for item in LOGS.glob("*.log") if not item.name.endswith("_session.log"))
        if not runs:
            print(f"no run logs in {LOGS}", file=sys.stderr)
            return 1
        path = runs[-1]
        print(f"# {path}")
    show(path, args.details)
    return 0


if __name__ == "__main__":
    sys.exit(main())
