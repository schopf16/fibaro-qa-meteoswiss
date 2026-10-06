#!/usr/bin/env python3
"""Print the CHANGELOG.md section of one version (used by the release workflow).

    python tools/release_notes.py 1.2.0
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"


def section(version: str) -> str | None:
    text = CHANGELOG.read_text(encoding="utf-8")
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
    if not match:
        return None
    body = re.sub(r"^\[[^\]]+\]:\s+\S+\s*$", "", match.group(1), flags=re.M)
    return body.strip()


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    notes = section(sys.argv[1])
    if not notes:
        print(f"ERROR: CHANGELOG.md has no section '## [{sys.argv[1]}]'", file=sys.stderr)
        return 1
    print(notes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
