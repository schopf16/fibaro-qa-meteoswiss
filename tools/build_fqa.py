#!/usr/bin/env python3
"""Build the distributable .fqa from the repository.

    python tools/build_fqa.py           # validate, scan, build dist/<repo>-<version>.fqa
    python tools/build_fqa.py --check   # validate and scan only

The package is always built from qa.manifest.json and src/. Never export a
QuickApp from a controller instead: an export carries that controller's own
variable values (addresses, credentials) into the package.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qa import ROOT, QaError, build_fqa, collect_files, load_manifest, repo_name, validate  # noqa: E402
from scan import Scanner, scan_worktree  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="validate and scan without writing")
    args = parser.parse_args()

    try:
        manifest = load_manifest()
        problems = validate(manifest)
        if problems:
            raise QaError("manifest check failed:\n  " + "\n  ".join(problems))
        files = collect_files(manifest)
    except QaError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1

    scanner = Scanner()
    count = scan_worktree(scanner)
    fqa = build_fqa(manifest, files)
    scanner.text("built .fqa", json.dumps(fqa, indent=1, ensure_ascii=False))
    if scanner.findings:
        print("PRIVACY SCAN FAILED - refusing to build:", file=sys.stderr)
        for finding in sorted(set(scanner.findings)):
            print(f"  {finding}", file=sys.stderr)
        return 1
    print(f"manifest valid, privacy scan clean ({count} files)")

    if args.check:
        return 0
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    target = dist / f"{repo_name(manifest)}-{manifest['version']}.fqa"
    target.write_text(json.dumps(fqa, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"built {target.relative_to(ROOT).as_posix()} ({len(files)} files, {target.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
