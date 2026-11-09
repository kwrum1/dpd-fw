#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# keep-settings.sh - protect the DPD plugin UCI files across an in-place
# upgrade.
#
# The meta packages deliberately keep the old implementation package names and
# the old UCI file names (router_acl, router_qos, ebpf_mwan, ...).  Nothing is
# migrated or renamed; this helper only records which protected files existed
# before an upgrade and checks that they are still there and non-empty.
#
# Usage:
#   keep-settings.sh list       print the protected config files
#   keep-settings.sh snapshot   record the files that exist right now
#   keep-settings.sh check      exit 1 if a snapshotted file vanished or is empty
#
# `check` is meant to be called from a package postinst or from the
# uci-defaults script:
#   /usr/lib/dpd/keep-settings.sh check || logger -t dpd "..."
#
# The first check on a system that has no baseline is a no-op: there is
# nothing to compare against yet.  The uci-defaults script takes a snapshot
# afterwards, so the next upgrade does have a baseline.

set -u

STATE_DIR=/etc/dpd/keep-settings
STATE_FILE=$STATE_DIR/state

# Implementation config files.  These names are old on purpose and must not be
# renamed; see docs/P3-PLUGINS.md.
PROTECTED="
/etc/config/router_acl
/etc/config/router_qos
/etc/config/ebpf_mwan
/etc/config/dpd_fastpath
/etc/config/einat
/etc/config/honk
/etc/config/dpd_napi
"

log() {
	if command -v logger >/dev/null 2>&1; then
		logger -t dpd "$*"
	fi
}

warn() {
	printf 'keep-settings: %s\n' "$*" >&2
	log "keep-settings: $*"
}

list_files() {
	for f in $PROTECTED; do
		printf '%s\n' "$f"
	done
}

snapshot() {
	mkdir -p "$STATE_DIR" || return 1
	: > "$STATE_FILE.tmp" || return 1
	for f in $PROTECTED; do
		[ -e "$f" ] && printf '%s\n' "$f" >> "$STATE_FILE.tmp"
	done
	mv "$STATE_FILE.tmp" "$STATE_FILE"
}

check() {
	rc=0

	if [ -f "$STATE_FILE" ]; then
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			if [ ! -e "$f" ]; then
				warn "protected config vanished: $f"
				rc=1
			elif [ ! -s "$f" ]; then
				warn "protected config is empty: $f"
				rc=1
			fi
		done < "$STATE_FILE"
	else
		printf 'keep-settings: no baseline yet, run snapshot after this boot\n' >&2
	fi

	# A protected file that is present now must never be empty, even if it
	# appeared after the last snapshot.  Skip the ones the state loop above
	# already reported.
	for f in $PROTECTED; do
		[ -e "$f" ] || continue
		[ -s "$f" ] && continue
		grep -Fqx "$f" "$STATE_FILE" 2>/dev/null && continue
		warn "protected config is empty: $f"
		rc=1
	done

	return "$rc"
}

case "${1:-}" in
	list)
		list_files
		;;
	snapshot)
		snapshot
		;;
	check)
		check
		;;
	*)
		printf 'usage: %s {list|snapshot|check}\n' "$0" >&2
		exit 2
		;;
esac
