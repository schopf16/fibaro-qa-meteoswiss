#!/usr/bin/env python3
"""Run the offline tests on a real Lua 5.3 interpreter - the HC3's version.

    python tools/run_tests.py            # all tests/test_*.lua
    python tools/run_tests.py test_app   # only files whose name contains "test_app"

Every test file gets a fresh interpreter with the HC3 sandbox imitated: no
require, io, dofile, loadfile, package or debug, and only the harmless os.*
functions. Code that relies on them fails here before it fails on the HC3.
Needs `pip install -r requirements-dev.txt` (lupa).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qa import ROOT, QaError, collect_files, load_manifest  # noqa: E402

try:
    import lupa.lua53 as lupa
except ImportError:
    sys.exit("ERROR: lupa is missing - run: pip install -r requirements-dev.txt")

TESTS = ROOT / "tests"

SANDBOX = """
io, require, dofile, loadfile, package, debug = nil, nil, nil, nil, nil, nil
os = { time = os.time, date = os.date, clock = os.clock, difftime = os.difftime }
"""


def to_python(value):
    if lupa.lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [to_python(value[k]) for k in range(1, len(keys) + 1)]
    return {str(k): to_python(v) for k, v in value.items()}


def returns(result) -> tuple:
    """The first two Lua return values; lupa returns a tuple only for several values."""
    values = result if isinstance(result, tuple) else (result,)
    return (values + (None, None))[:2]


def run_file(test_file: Path, manifest: dict, files: list[dict]) -> tuple[int, list[str]]:
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    load, traceback = g.load, g.debug.traceback

    def execute(source: str, chunk_name: str, run: bool = True) -> None:
        fn, err = returns(load(source, "@" + chunk_name))
        if fn is None:
            raise QaError(f"cannot load {chunk_name}: {err}")
        if run:
            fn()

    execute((TESTS / "lib" / "testing.lua").read_text(encoding="utf-8"), "tests/lib/testing.lua")
    g.json = lua.table_from({
        "encode": lambda value: json.dumps(to_python(value), ensure_ascii=False),
        "decode": lambda text: lua.table_from(json.loads(text), recursive=True),
    })
    g.MANIFEST = lua.table_from(manifest, recursive=True)
    lua.execute(SANDBOX)
    execute((TESTS / "lib" / "hc3_stub.lua").read_text(encoding="utf-8"), "tests/lib/hc3_stub.lua")

    for f in files:
        # main only defines QuickApp methods; compile it to catch syntax errors.
        execute(f["content"], f"{f['name']}.lua", run=not f["isMain"])

    execute(test_file.read_text(encoding="utf-8"), test_file.relative_to(ROOT).as_posix())

    failures = []
    cases = g.TESTS
    for i in range(1, len(cases) + 1):
        case = cases[i]
        g.resetStub()
        success, err = returns(g.xpcall(case.fn, traceback))
        if not success:
            failures.append(f"{test_file.name}: {case.name}\n    {str(err).replace(chr(10), chr(10) + '    ')}")
    return len(cases), failures


def main() -> int:
    selector = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        manifest = load_manifest()
        files = collect_files(manifest)
        total, failures = 0, []
        for test_file in sorted(TESTS.glob("test_*.lua")):
            if selector in test_file.name:
                count, failed = run_file(test_file, manifest, files)
                total += count
                failures += failed
    except (QaError, lupa.LuaError) as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    print(f"{total - len(failures)}/{total} tests passed on {lupa.LuaRuntime().eval('_VERSION')}")
    return 1 if failures or total == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
