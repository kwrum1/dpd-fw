#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# feed-index.sh - make this repository consumable as an OpenWrt feed.
#
# `scripts/feeds` only looks for a Makefile in the *direct children* of a feed
# root. This tree is nested by layer (bpf/core, plugins/*, userspace/*,
# openwrt/*), so a src-link/src-git feed pointed at the checkout finds no
# packages. This script creates the missing flat level as symlinks:
#
#   openwrt/feed/index/dpd-fastpath  ->  ../../bpf/core
#   openwrt/feed/index/router-acl    ->  ../../plugins/dpd-acl
#   ...
#
# The link names are the PKG_NAME values, so two source directories that would
# collide by basename (plugins/dpd-acl vs openwrt/meta/dpd-acl) stay distinct
# (router-acl vs dpd-acl).
#
# The index is generated state: it is gitignored and can be recreated at any
# time. Package edits are visible immediately (symlinks), but re-run the script
# after adding or renaming a package directory.
#
# usage:
#   sh scripts/feed-index.sh [-o DIR] [--print]
#
#   -o DIR     output directory (default: openwrt/feed/index); recreated
#   --print    print "package<TAB>directory" and create nothing

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
OUT=$ROOT/openwrt/feed/index
PRINT=0

usage() {
	cat <<'EOF'
usage: sh scripts/feed-index.sh [-o DIR] [--print]

  -o DIR     output directory (default: openwrt/feed/index); recreated
  --print    print "package<TAB>directory" and create nothing
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	-o | --output)
		[ $# -ge 2 ] || { usage >&2; exit 2; }
		OUT=$2
		shift 2
		;;
	--print)
		PRINT=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'feed-index: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
done

case $OUT in
/*) ;;
*) OUT=$PWD/$OUT ;;
esac

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/dpd-feed.XXXXXX") || exit 1
trap 'rm -rf -- "${tmpd:?}"' EXIT HUP INT TERM
candidates=$tmpd/candidates
packages=$tmpd/packages

# The package directories of this tree. Globs that match nothing stay literal
# and are dropped by the Makefile test below.
{
	printf '%s\n' "$ROOT/bpf/core"
	for d in "$ROOT"/userspace/*; do printf '%s\n' "$d"; done
	for d in "$ROOT"/plugins/*; do printf '%s\n' "$d"; done
	for d in "$ROOT"/openwrt/meta/*; do printf '%s\n' "$d"; done
	printf '%s\n' "$ROOT/openwrt/luci-app-dpd"
} >"$candidates"

: >"$packages"
while IFS= read -r dir; do
	[ -f "$dir/Makefile" ] || continue
	name=$(sed -n 's/^PKG_NAME[[:space:]]*[:?+]*=[[:space:]]*//p' "$dir/Makefile" | head -n 1)
	name=$(printf '%s' "$name" | sed 's/[[:space:]]*$//')
	[ -n "$name" ] || name=$(basename "$dir")
	case $name in
	*[!A-Za-z0-9_.+-]*)
		printf 'feed-index: skip %s: unusable PKG_NAME %s\n' "$dir" "$name" >&2
		continue
		;;
	esac
	if awk -F '	' -v n="$name" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$packages"; then
		printf 'feed-index: skip %s: duplicate package name %s\n' "$dir" "$name" >&2
		continue
	fi
	printf '%s\t%s\n' "$name" "$dir" >>"$packages"
done <"$candidates"

LC_ALL=C sort -o "$packages" "$packages"

count=$(wc -l <"$packages" | tr -d '[:space:]')
if [ "$count" -eq 0 ]; then
	printf 'feed-index: no package directories found under %s\n' "$ROOT" >&2
	exit 1
fi

if [ "$PRINT" -eq 1 ]; then
	while IFS='	' read -r name dir; do
		printf '%s\t%s\n' "$name" "$dir"
	done <"$packages"
	exit 0
fi

case $OUT in
"" | / | "$ROOT" | "$ROOT/")
	printf 'feed-index: refusing to use %s as the output directory\n' "$OUT" >&2
	exit 2
	;;
esac

rm -rf -- "${OUT:?}"
mkdir -p -- "$OUT"

while IFS='	' read -r name dir; do
	ln -s -- "$dir" "$OUT/$name"
done <"$packages"

printf 'feed-index: %s package(s) linked in %s\n' "$count" "$OUT"
printf '\nNext, from the OpenWrt tree (absolute path as shown above):\n'
printf '  echo "src-link dpd-fw %s" >> feeds.conf.default\n' "$OUT"
printf '  ./scripts/feeds update dpd-fw\n'
printf '  ./scripts/feeds install -a -p dpd-fw\n'
printf '\nOr install a single package: ./scripts/feeds install dpd-fastpath\n'
