#!/usr/bin/env python3
"""Privacy scan: nothing host-specific may reach the repository or a package.

    python tools/scan.py             # working tree (tracked and untracked files)
    python tools/scan.py --history   # every commit, message and author (before going public)

Three sources of forbidden content:
  1. generic patterns below (private IPs, e-mail addresses, credentials, and
     controller device IDs in calls, API paths and log tags - only the
     placeholder IDs in PLACEHOLDER_IDS may appear there),
  2. the values in your .env files (controller address, user, password, and
     HC3_DEV_QA_ID as a whole number),
  3. your private deny lists ../.scan-deny.txt and .scan-deny.txt (git-ignored):
     one literal per line - room names, device names, serial numbers.
tools/scan-allow.txt lists literals that may appear despite matching a pattern.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qa import ROOT, load_env  # noqa: E402

PATTERNS = [
    ("private IPv4 (10.x)", r"\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
    ("private IPv4 (172.16-31.x)", r"\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"),
    ("private IPv4 (192.168.x)", r"\b192\.168\.\d{1,3}\.\d{1,3}\b"),
    ("MAC address", r"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b"),
    ("e-mail address", r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}\b"),
    ("credential assignment",
     r"(?i)\b(?:password|passwd|pwd|api_?key|token|secret)\b\s*[:=]\s*[\"'][^\"']{3,}[\"']"),
    ("basic auth header", r"(?i)authorization\s*[:=]\s*[\"']?basic\s+[A-Za-z0-9+/=]{8,}"),
]
# Places where a controller device ID appears; group 1 is the ID.
DEVICE_ID_PATTERNS = [
    ("device ID in a fibaro call", r"\b(?:fibaro\.\w+|hub\.call)\(\s*(\d{2,})"),
    ("device ID in an API path", r"/(?:devices|quickApp|quickApp/export|plugins/restart)/(\d{2,})\b"),
    ("device ID in a URL parameter", r"(?i)\bdevice_?id=(\d{2,})\b"),
    ("device ID in a log tag", r"\b[A-Z][A-Z0-9]{2,}_(\d{2,})\b"),
    ("device ID in text", r"(?i)\b(?:device|quickapp)(?:\s+id|id)?\s*[:=#]?\s*\(?(\d{3,})\b"),
    ("device ID constant", r"\b\w+\s*=\s*(\d{2,})\s*--[^\\\n]*\bdevice\b"),
]
# IDs that examples and tests use instead of real ones.
PLACEHOLDER_IDS = {"100", "123", "1234"}
# Addresses GitHub itself writes into commits (merge committer, bot sign-off).
GITHUB_ADDRESSES = ("noreply@github.com", "support@github.com", "users.noreply.github.com")
SKIP_DIRS = {".git", "dist", ".venv", "venv", "__pycache__", "node_modules"}
SKIP_FILES = {".env", ".scan-deny.txt"}


def read_lines(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines = (line.strip() for line in path.read_text(encoding="utf-8").splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def deny_literals() -> list[tuple[str, str]]:
    """(label, literal) pairs; labels never contain the secret itself.
    Numbers (device IDs) are matched as whole numbers only."""
    denied = []
    for key, value in load_env().items():
        if value.isdigit():
            if len(value) >= 2:
                denied.append((f"value of .env {key}", value))
            continue
        if len(value) < 4:
            continue
        if key.endswith("_URL"):
            host = urlparse(value).hostname
            if host:
                denied.append((f"host from .env {key}", host))
            continue
        denied.append((f"value of .env {key}", value))
    for path in (ROOT.parent / ".scan-deny.txt", ROOT / ".scan-deny.txt"):
        denied += [(f"deny list entry '{line}'", line) for line in read_lines(path)]
    return denied


class Scanner:
    def __init__(self):
        self.allowed = read_lines(ROOT / "tools" / "scan-allow.txt")
        self.denied = [(label, re.compile(rf"(?<![\d.]){re.escape(literal)}(?![\d.])") if literal.isdigit()
                        else literal.lower()) for label, literal in deny_literals()]
        self.patterns = [(label, re.compile(p)) for label, p in PATTERNS]
        self.id_patterns = [(label, re.compile(p)) for label, p in DEVICE_ID_PATTERNS]
        self.findings: list[str] = []

    def line(self, where: str, text: str) -> None:
        lowered = text.lower()
        for label, literal in self.denied:
            if literal.search(text) if isinstance(literal, re.Pattern) else literal in lowered:
                self.findings.append(f"{where}: {label}")
        for label, pattern in self.patterns:
            for match in pattern.finditer(text):
                allowed = (*self.allowed, *GITHUB_ADDRESSES)
                if not any(a in match.group(0) for a in allowed):
                    self.findings.append(f"{where}: {label}: {match.group(0)}")
        for label, pattern in self.id_patterns:
            for match in pattern.finditer(text):
                if match.group(1) not in PLACEHOLDER_IDS and match.group(0) not in self.allowed:
                    self.findings.append(f"{where}: {label}: {match.group(0)}")

    def text(self, where: str, text: str) -> None:
        for number, line in enumerate(text.splitlines(), 1):
            self.line(f"{where}:{number}", line)


def git(*args: str) -> str | None:
    try:
        result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.decode("utf-8", errors="replace")


def worktree_files() -> list[Path]:
    listed = git("ls-files", "--cached", "--others", "--exclude-standard")
    if listed is not None:
        paths = [ROOT / p for p in listed.splitlines() if p]
    else:
        paths = [p for p in ROOT.rglob("*") if p.is_file()]
    return [p for p in paths
            if p.is_file() and p.name not in SKIP_FILES
            and not SKIP_DIRS.intersection(p.relative_to(ROOT).parts)]


def scan_worktree(scanner: Scanner) -> int:
    files = worktree_files()
    for path in files:
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        scanner.text(path.relative_to(ROOT).as_posix(), content)
    return len(files)


def scan_history(scanner: Scanner) -> int:
    identities = git("log", "--all", "--format=%an <%ae>%n%cn <%ce>")
    if identities is None:
        raise SystemExit("ERROR: --history needs a Git repository")
    for identity in sorted(set(identities.splitlines())):
        scanner.line("commit identity", identity)
    log = git("log", "--all", "-p", "--no-color", "--format=@@commit %h%n%B") or ""
    commit, count = "?", 0
    for line in log.splitlines():
        if line.startswith("@@commit "):
            commit, count = line.split()[1], count + 1
        elif line.startswith(("+++", "---", "diff ", "index ", "@@")):
            continue
        elif not line.startswith(("-", " ")):
            scanner.line(f"commit {commit}", line.lstrip("+"))
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--history", action="store_true", help="scan the whole Git history")
    args = parser.parse_args()

    scanner = Scanner()
    if args.history:
        what = f"{scan_history(scanner)} commits"
    else:
        what = f"{scan_worktree(scanner)} files"

    if scanner.findings:
        print(f"PRIVACY SCAN FAILED ({what}):", file=sys.stderr)
        for finding in sorted(set(scanner.findings)):
            print(f"  {finding}", file=sys.stderr)
        print("\nRemove the data. Add a literal to tools/scan-allow.txt only for a genuine "
              "false positive, never to silence real data.", file=sys.stderr)
        return 1
    print(f"privacy scan clean ({what})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
