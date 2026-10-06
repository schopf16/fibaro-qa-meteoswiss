#!/usr/bin/env python3
"""Upload the sources to your development QuickApp on the HC3.

    python tools/upload.py            # upload changed files
    python tools/upload.py --ui       # also replace the UI layout and the device icon
    python tools/upload.py --dry-run  # show what would change

Configuration comes from ../.env and .env (both git-ignored):
    HC3_URL, HC3_USER, HC3_PASSWORD   controller access
    HC3_DEV_QA_ID                     ID of the development QuickApp

Safety: the target's name must be the manifest name followed by " [DEV]",
so a production QuickApp can never be overwritten by accident. Code files are
written, and with --ui the UI layout; QuickApp variables (your real
configuration) and child devices are never touched. Every change restarts the
QuickApp.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qa import Hc3, QaError, build_fqa, collect_files, load_env, load_manifest, validate  # noqa: E402

DEV_SUFFIX = " [DEV]"


def upload(dry_run: bool, ui: bool) -> None:
    manifest = load_manifest()
    problems = validate(manifest)
    if problems:
        raise QaError("manifest check failed:\n  " + "\n  ".join(problems))
    files = collect_files(manifest)

    env = load_env()
    qa_id = env.get("HC3_DEV_QA_ID", "")
    if not qa_id.isdigit():
        raise QaError("set HC3_DEV_QA_ID in .env to the ID of your development QuickApp")
    hc3 = Hc3(env)

    device = hc3.request("GET", f"/api/devices/{qa_id}")
    expected = manifest["name"] + DEV_SUFFIX
    if "quickApp" not in (device or {}).get("interfaces", []):
        raise QaError(f"device {qa_id} is not a QuickApp")
    if device.get("name") != expected:
        raise QaError(f"device {qa_id} is named '{device.get('name')}', expected '{expected}'. "
                      "Rename your development QuickApp to confirm it may be overwritten.")

    remote = {f["name"]: f for f in hc3.request("GET", f"/api/quickApp/{qa_id}/files") or []}
    changed = 0
    for f in files:  # main is last, so the restart it triggers sees all other files
        current = remote.get(f["name"])
        if current is not None:
            detail = hc3.request("GET", f"/api/quickApp/{qa_id}/files/{f['name']}") or {}
            if detail.get("content") == f["content"]:
                continue
        changed += 1
        action = "update" if current is not None else "create"
        print(f"{action:6} {f['name']}")
        if dry_run:
            continue
        body = {"name": f["name"], "type": "lua", "isMain": f["isMain"],
                "isOpen": False, "content": f["content"]}
        if current is not None:
            hc3.request("PUT", f"/api/quickApp/{qa_id}/files/{f['name']}", body)
        else:
            hc3.request("POST", f"/api/quickApp/{qa_id}/files", body)

    extra = sorted(set(remote) - {f["name"] for f in files})
    if extra:
        print(f"note: files on the HC3 but not in the build (remove them by hand): {', '.join(extra)}")

    local_vars = {v["name"] for v in manifest.get("quickAppVariables", [])}
    remote_vars = {v.get("name") for v in device.get("properties", {}).get("quickAppVariables", [])}
    missing = sorted(local_vars - remote_vars)
    if missing:
        print(f"note: QuickApp variables missing on the HC3 (add them by hand): {', '.join(missing)}")

    if ui:
        layout = build_fqa(manifest, files)["initialProperties"]
        print("update UI layout")
        if not dry_run:
            properties = {
                "uiView": layout["uiView"],
                "uiCallbacks": layout["uiCallbacks"],
                "viewLayout": layout["viewLayout"],
            }
            if "deviceIcon" in layout:
                properties["deviceIcon"] = layout["deviceIcon"]
            hc3.request("PUT", f"/api/devices/{qa_id}", {"properties": properties})

    verb = "would change" if dry_run else "changed"
    print(f"{verb} {changed} of {len(files)} files on QuickApp {qa_id}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="show changes without uploading")
    parser.add_argument("--ui", action="store_true", help="also replace the UI layout from the manifest")
    args = parser.parse_args()
    try:
        upload(args.dry_run, args.ui)
    except QaError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
