#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# verify-ppe-abi.sh - the two dpd_ppe_state definitions must agree.
#
# dpdfwd deliberately does not include bpf/core/src/dpd_common.h: the daemon
# talks to the datapath through dpdctl and the pinned maps only, and pulling in
# linux/bpf.h to share six constants would couple the control plane to a
# specific kernel UAPI. The cost of that boundary is a duplicated enum, so this
# script guards it: if someone adds or renumbers a state on one side, CI fails
# here instead of the daemon silently writing a state the datapath reads as
# something else.
#
# usage: sh scripts/verify-ppe-abi.sh
# exit: 0 ok, 1 mismatch

set -u

case "$0" in
*/*) here=$(cd -- "$(dirname -- "$0")" && pwd) ;;
*)   here=$(pwd) ;;
esac
if [ -f "$here/bpf/core/src/dpd_common.h" ]; then
	ROOT=$here
elif [ -f "$here/../bpf/core/src/dpd_common.h" ]; then
	ROOT=$(cd -- "$here/.." && pwd)
else
	echo "FAIL: cannot locate the source tree from $here" >&2
	exit 1
fi

COMMON=$ROOT/bpf/core/src/dpd_common.h
PLUGIN=$ROOT/userspace/dpdfwd/src/dpd_plugin.h
BPF=$ROOT/bpf/core/src/dpd_fastpath.bpf.c

for f in "$COMMON" "$PLUGIN" "$BPF"; do
	[ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# Extract NAME=value pairs from an enum, resolving implicit auto-increment.
# Written in Python because the shell/awk version got the "explicit = N, then
# the next name auto-increments from N" case wrong (it emitted the previous
# value for the following name), which would have hidden a real mismatch.
enum_pairs() {
	python3 - "$1" "$2" <<'PY'
import re, sys
path, name = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8', errors='replace').read()
m = re.search(r'enum\s+%s\s*\{(.*?)\}' % re.escape(name), text, re.S)
if not m:
    sys.exit(1)
cur = 0
out = []
for line in m.group(1).splitlines():
    line = line.split('/*')[0].strip().rstrip(',')
    if not line:
        continue
    if '=' in line:
        k, v = line.split('=', 1)
        cur = int(v.strip(), 0)
    else:
        k = line
    out.append('%s=%d' % (k.strip(), cur))
    cur += 1
print('\n'.join(out))
PY
}

a=$(enum_pairs "$COMMON" dpd_ppe_state)
b=$(enum_pairs "$PLUGIN" dpd_ppe_state)

if [ -z "$a" ] || [ -z "$b" ]; then
	echo "FAIL: enum dpd_ppe_state not found in one of the headers" >&2
	exit 1
fi

if [ "$a" = "$b" ]; then
	echo "ok:   dpd_ppe_state identical ($(printf '%s\n' "$a" | wc -l) values)"
	printf '%s\n' "$a" | sed 's/^/      /'
else
	echo "FAIL: enum dpd_ppe_state differs between the two headers" >&2
	echo "--- bpf/core/src/dpd_common.h ---" >&2
	printf '%s\n' "$a" >&2
	echo "--- userspace/dpdfwd/src/dpd_plugin.h ---" >&2
	printf '%s\n' "$b" >&2
	exit 1
fi

if grep -q 'dpd_ppe_yield(cfg, fval, age, st)' "$BPF"; then
	echo "ok:   the hit path calls dpd_ppe_yield()"
else
	echo "FAIL: dpd_fastpath.bpf.c no longer calls dpd_ppe_yield()" >&2
	exit 1
fi

for c in ST_PPE_YIELD ST_PPE_GRACE; do
	if grep -q "$c" "$COMMON"; then
		echo "ok:   $c defined"
	else
		echo "FAIL: $c missing from dpd_common.h" >&2
		exit 1
	fi
done

echo "verify-ppe-abi: OK"
