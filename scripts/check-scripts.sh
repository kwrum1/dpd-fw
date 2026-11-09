#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# check-scripts.sh - run `sh -n` on every shell script in the tree.
#
# This is the fast, dependency-free half of the CI `shell` job: a build host
# without shellcheck can still catch a missing `fi`/`done`/quote before an
# image build. CI additionally runs `shellcheck -S warning`.
#
# Included: every tracked `*.sh` file, plus extensionless files whose first
# line starts with `#!/bin/sh` (the OpenWrt init/hotplug style). Outside a git
# work tree the script falls back to `find`.
#
# usage: sh scripts/check-scripts.sh

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/dpd-sh.XXXXXX") || exit 1
trap 'rm -rf -- "${tmpd:?}"' EXIT HUP INT TERM
list=$tmpd/list
err=$tmpd/err
: >"$list"

# add FILE if it is an extensionless script that declares /bin/sh
add_if_sh() {
	[ -f "$1" ] || return 0
	first=$(head -n 1 "$1" 2>/dev/null || true)
	case $first in
	'#!/bin/sh'* | '#!/usr/bin/env sh'*) printf '%s\n' "$1" >>"$list" ;;
	esac
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git ls-files '*.sh' >>"$list"
	git ls-files | while IFS= read -r f; do
		case $f in
		*.sh) continue ;;
		esac
		add_if_sh "$f"
	done
else
	find . -path ./.git -prune -o -type f -name '*.sh' -print >>"$list"
	find . -path ./.git -prune -o -type f ! -name '*.*' -print |
		while IFS= read -r f; do
			add_if_sh "$f"
		done
fi

LC_ALL=C sort -u -o "$list" "$list"

total=0
failed=0
while IFS= read -r f; do
	[ -f "$f" ] || continue
	total=$((total + 1))
	# bash-only scripts (honk/build-core.sh) cannot be parsed by `sh -n`.
	first=$(head -n 1 "$f" 2>/dev/null || true)
	case $first in
	'#!/bin/bash'* | '#!/usr/bin/env bash'*) interp=bash ;;
	*) interp=sh ;;
	esac
	if $interp -n "$f" 2>"$err"; then
		:
	else
		failed=$((failed + 1))
		printf 'FAIL: %s (%s -n)\n' "$f" "$interp" >&2
		sed 's/^/  /' "$err" >&2
	fi
done <"$list"

if [ "$failed" -ne 0 ]; then
	printf 'check-scripts: %d of %d script(s) failed sh -n\n' \
		"$failed" "$total" >&2
	exit 1
fi

printf 'check-scripts: %d script(s) pass sh -n\n' "$total"
