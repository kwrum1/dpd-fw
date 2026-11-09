#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# verify-abi.sh - the invariants an ABI bump must keep.
#
# Used by the CI `abi` job and runnable by hand on a build host. It does not
# need clang: it reads the source tree, and optionally a built object.
#
# Checks
#   1. DPD_ABI_VERSION in bpf/core/src/dpd_common.h is a number, and
#      docs/ARCHITECTURE.md names the same ABI (the newest numeric ABI the doc
#      talks about must be the header's value; a doc that still describes the
#      previous ABI fails). If the doc names no ABI at all, that check is
#      skipped with a note.
#   2. DPD_SEC_L2/DPD_SEC_L3 are "classifier/l2"/"classifier/l3" and the BPF
#      program attaches with SEC(DPD_SEC_L2)/SEC(DPD_SEC_L3). With --obj the
#      compiled object is also checked for those section names.
#   3. Every enumerator of enum dpd_stat_idx (ST__MAX excluded) has the same
#      name, at the same index, in dpdctl.c's stat_name() array. A counter that
#      is counted but not named (or named in the wrong slot) is a silent
#      misreport in `dpdctl stats`.
#
# usage:
#   sh scripts/verify-abi.sh [--doc FILE] [--obj FILE] [--installed FILE]
#
#   --doc FILE        architecture document (default docs/ARCHITECTURE.md)
#   --obj FILE        built dpd_fastpath.bpf.o; checks real section names
#   --installed FILE  installed ABI stamp (e.g. /usr/lib/dpd/abi); must match
#
# Exit status: 0 all checks passed, 1 at least one failed, 2 usage error.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
COMMON=$ROOT/bpf/core/src/dpd_common.h
CTL=$ROOT/bpf/core/src/dpdctl.c
BPF=$ROOT/bpf/core/src/dpd_fastpath.bpf.c
DOC=$ROOT/docs/ARCHITECTURE.md
OBJ=
INSTALLED=

usage() {
	cat <<'EOF'
usage: sh scripts/verify-abi.sh [--doc FILE] [--obj FILE] [--installed FILE]

  --doc FILE        architecture document (default docs/ARCHITECTURE.md)
  --obj FILE        built dpd_fastpath.bpf.o; checks real section names
  --installed FILE  installed ABI stamp (e.g. /usr/lib/dpd/abi)
EOF
}

bad=0
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	bad=$((bad + 1))
}
note() {
	printf 'note: %s\n' "$*"
}
ok() {
	printf 'ok:   %s\n' "$*"
}

while [ $# -gt 0 ]; do
	case $1 in
	--doc)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		DOC=$2
		shift 2
		;;
	--obj)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		OBJ=$2
		shift 2
		;;
	--installed)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		INSTALLED=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'verify-abi: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

for f in "$COMMON" "$CTL" "$BPF"; do
	[ -f "$f" ] || fail "missing source file: $f"
done
[ -f "$DOC" ] || note "no $DOC; ABI/document comparison skipped"

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/dpd-abi.XXXXXX") || exit 1
trap 'rm -rf -- "${tmpd:?}"' EXIT HUP INT TERM

# ---------------------------------------------------------------- 1. ABI stamp
abi=$(sed -n 's/^#define[[:space:]]\{1,\}DPD_ABI_VERSION[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' "$COMMON" | head -n 1)
if [ -z "$abi" ]; then
	fail "bpf/core/src/dpd_common.h has no numeric '#define DPD_ABI_VERSION'"
else
	ok "DPD_ABI_VERSION = $abi"
fi

if [ -n "$abi" ] && [ -f "$DOC" ]; then
	doc_abis=$(grep -oiE 'abi([[:space:]_-]?version)?[[:space:]]*[=:]?[[:space:]]*[0-9]+' "$DOC" |
		grep -oE '[0-9]+$' | LC_ALL=C sort -n -u)
	if [ -z "$doc_abis" ]; then
		note "$DOC names no numeric ABI; skipping the document comparison"
	else
		doc_max=$(printf '%s\n' "$doc_abis" | tail -n 1)
		if [ "$doc_max" = "$abi" ]; then
			ok "$DOC names ABI $abi"
		elif [ "$doc_max" -lt "$abi" ]; then
			fail "$DOC names ABI $doc_max as the newest ABI but bpf/core/src/dpd_common.h is $abi: add the ABI $abi note to the document"
		else
			fail "$DOC names ABI $doc_max, newer than bpf/core/src/dpd_common.h ($abi): the document is ahead of the code"
		fi
		printf '%s\n' "$doc_abis" | while IFS= read -r n; do
			[ "$n" = "$abi" ] || note "$DOC also mentions ABI $n (another revision)"
		done
	fi
fi

if [ -n "$INSTALLED" ]; then
	if [ ! -r "$INSTALLED" ]; then
		fail "installed ABI stamp $INSTALLED is not readable"
	else
		installed=$(tr -dc '0-9' <"$INSTALLED")
		if [ "$installed" = "$abi" ]; then
			ok "$INSTALLED matches the header ($installed)"
		else
			shown=$(printf '%s' "$installed" | cut -c1-16)
			fail "$INSTALLED says '${shown:-<empty>}' but the header says '${abi:-<empty>}'"
		fi
	fi
fi

# ------------------------------------------------------------ 2. section names
sec_l2=$(sed -n 's/^#define[[:space:]]\{1,\}DPD_SEC_L2[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' "$COMMON" | head -n 1)
sec_l3=$(sed -n 's/^#define[[:space:]]\{1,\}DPD_SEC_L3[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' "$COMMON" | head -n 1)

if [ "$sec_l2" = "classifier/l2" ]; then
	ok "DPD_SEC_L2 = $sec_l2"
else
	fail "DPD_SEC_L2 is '${sec_l2:-<missing>}', expected 'classifier/l2'"
fi
if [ "$sec_l3" = "classifier/l3" ]; then
	ok "DPD_SEC_L3 = $sec_l3"
else
	fail "DPD_SEC_L3 is '${sec_l3:-<missing>}', expected 'classifier/l3'"
fi

if [ -f "$BPF" ]; then
	grep -Fq 'SEC(DPD_SEC_L2)' "$BPF" ||
		fail "bpf/core/src/dpd_fastpath.bpf.c does not attach with SEC(DPD_SEC_L2)"
	grep -Fq 'SEC(DPD_SEC_L3)' "$BPF" ||
		fail "bpf/core/src/dpd_fastpath.bpf.c does not attach with SEC(DPD_SEC_L3)"
fi

if [ -n "$OBJ" ]; then
	dump=
	if [ ! -f "$OBJ" ]; then
		fail "object $OBJ does not exist"
	elif command -v llvm-objdump >/dev/null 2>&1; then
		dump=$(llvm-objdump -h "$OBJ")
	elif command -v readelf >/dev/null 2>&1; then
		dump=$(readelf -S -W "$OBJ")
	else
		fail "no llvm-objdump or readelf to inspect $OBJ"
	fi
	if [ -n "$dump" ]; then
		for sec in "$sec_l2" "$sec_l3"; do
			case $sec in
			classifier/l2 | classifier/l3)
				if printf '%s\n' "$dump" | grep -Fq "$sec"; then
					ok "object $OBJ has section $sec"
				else
					fail "object $OBJ has no section $sec"
				fi
				;;
			esac
		done
	fi
fi

# -------------------------------------------------------------- 3. stat names
awk '
	/^enum[[:space:]]+dpd_stat_idx[[:space:]]*\{/ { inside = 1; next }
	inside && /^\};/ { inside = 0; next }
	!inside { next }
	{
		line = $0
		sub(/\/\*.*$/, "", line)
		if (line ~ /^[[:space:]]*\*/) next
		if (match(line, /^[[:space:]]*ST_[A-Z0-9_]+/)) {
			name = substr(line, RSTART, RLENGTH)
			sub(/^[[:space:]]+/, "", name)
			print name
		}
	}
' "$COMMON" | grep -vx 'ST__MAX' >"$tmpd/enum"

sed -n '/static const char \*n\[ST__MAX\]/,/^[[:space:]]*};/p' "$CTL" |
	grep -o '"[A-Za-z0-9_]*"' | tr -d '"' >"$tmpd/names"

n_enum=$(wc -l <"$tmpd/enum" | tr -d '[:space:]')
n_names=$(wc -l <"$tmpd/names" | tr -d '[:space:]')

if [ "$n_enum" -eq 0 ]; then
	fail "could not parse 'enum dpd_stat_idx' in $COMMON"
elif [ "$n_names" -eq 0 ]; then
	fail "could not find the stat_name() name array in $CTL"
elif [ "$n_enum" -ne "$n_names" ]; then
	fail "enum dpd_stat_idx has $n_enum counters (ST__MAX excluded) but dpdctl.c stat_name() has $n_names names"
else
	dup=$(LC_ALL=C sort "$tmpd/names" | uniq -d)
	if [ -n "$dup" ]; then
		fail "duplicate counter name(s) in stat_name(): $(printf '%s' "$dup" | tr '\n' ' ')"
	fi
	paste "$tmpd/enum" "$tmpd/names" >"$tmpd/pairs"
	if ! awk -F '	' '
		{
			want = tolower($1)
			sub(/^st_/, "", want)
			if ($2 != want) {
				printf "  index %d: enum %s wants \"%s\", stat_name() has \"%s\"\n", NR - 1, $1, want, $2
				bad = 1
			}
		}
		END { exit bad ? 1 : 0 }
	' "$tmpd/pairs" >&2; then
		fail "stat_name() does not map enum dpd_stat_idx positionally"
	else
		ok "all $n_enum ST_* counters have a name in stat_name()"
	fi
fi

if [ "$bad" -ne 0 ]; then
	printf 'verify-abi: FAILED (%d check(s))\n' "$bad" >&2
	exit 1
fi

printf 'verify-abi: OK (abi=%s, sections %s/%s, %s counters)\n' \
	"${abi:-?}" "${sec_l2:-?}" "${sec_l3:-?}" "${n_enum:-?}"
