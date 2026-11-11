#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# check-vantage-patch.sh - the Vantage dashboard patch must produce valid JS.
#
# Handles.sh runs patch-vantage-overview.py against the theme cloned at build
# time. If the injected JavaScript were malformed the build would still be
# green (it is a text patch, not a compile) and the page would break at
# runtime in the browser. This extracts the injected block and syntax-checks it.
#
# usage: sh scripts/check-vantage-patch.sh
# exit: 0 ok, 1 malformed, 77 skipped (no node)

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
PY=$ROOT/../Scripts/patch-vantage-overview.py
[ -f "$PY" ] || PY=$ROOT/Scripts/patch-vantage-overview.py

if [ ! -f "$PY" ]; then
	echo "check-vantage-patch: patcher not found" >&2
	exit 1
fi

if ! command -v node >/dev/null 2>&1; then
	echo "check-vantage-patch: node not available, skipping"
	exit 77
fi

python3 - "$PY" <<'PY'
import importlib.util, io, subprocess, sys

spec = importlib.util.spec_from_file_location("pv", sys.argv[1])
pv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pv)

chip = pv.CHIP_NEW
start = chip.index("}));") + len("}));")
end = chip.index("\t},", start)
block = chip[start:end]

harness = ("'use strict';\n"
           "function E(t,a,k){return {tag:t,attrs:a,kids:k};}\n"
           "function icon(n){return n;}\n"
           "var self = { el: { health: { appendChild: function(){} } },\n"
           "  ebpf: null, paint: function() {\n" + block + "\n} };\n")
path = "/tmp/dpd-vantage-injected.js"
io.open(path, "w", encoding="utf-8").write(harness)

r = subprocess.run(["node", "--check", path], capture_output=True, text=True)
if r.returncode != 0:
    print("FAIL: injected Vantage JS does not parse:", file=sys.stderr)
    print(r.stderr[:800], file=sys.stderr)
    sys.exit(1)
print("ok:   the injected Vantage chip block parses")
sys.exit(0)
PY
rc=$?
case $rc in
0) echo "check-vantage-patch: OK" ;;
*) exit $rc ;;
esac