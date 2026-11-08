#!/bin/sh
# P5 upgrade/rollback drill. Run on a test router from a shell.
#
#   tests/upgrade-rollback.sh /tmp/dpd-*.ipk ...
#
# It backs up the DPD/honk config, installs the given packages, restarts the
# plugins, verifies that the datapath still answers and that the gate did not
# silently degrade, and restores the config if a check fails. The actual
# firmware rollback remains `sysupgrade` to the previous release; this drill is
# for the package/config layer.
set -eu

BACKUP=/tmp/dpd-p5-backup
mkdir -p "$BACKUP"
for f in /etc/config/dpd_fastpath /etc/config/dpd_honk /etc/config/dpd_observe /etc/config/dpd_napi /etc/config/honk /etc/honk; do
	[ -e "$f" ] && cp -a "$f" "$BACKUP/" || true
done
/usr/sbin/dpdctl status -j > "$BACKUP/status.before.json" 2>/dev/null || true

restore() {
	for f in dpd_fastpath dpd_honk dpd_observe dpd_napi honk; do
		[ -e "$BACKUP/$f" ] && cp -a "$BACKUP/$f" /etc/config/ || true
	done
	[ -e "$BACKUP/honk" ] && cp -a "$BACKUP/honk" /etc/honk || true
	/etc/init.d/dpd-fastpath restart 2>/dev/null || true
	/etc/init.d/dpd-honk restart 2>/dev/null || true
	/etc/init.d/dpd-observe restart 2>/dev/null || true
}

fail() {
	echo "FAIL: $*" >&2
	restore
	exit 1
}

echo "=== install ==="
if command -v opkg >/dev/null 2>&1; then
	for pkg in "$@"; do opkg install "$pkg" || fail "opkg install $pkg"; done
elif command -v apk >/dev/null 2>&1; then
	for pkg in "$@"; do apk add --no-network --allow-untrusted "$pkg" || fail "apk add $pkg"; done
else
	fail "no package manager"
fi

/etc/init.d/dpd-fastpath restart 2>/dev/null || true
/etc/init.d/dpd-honk restart 2>/dev/null || true
/etc/init.d/dpd-observe restart 2>/dev/null || true
sleep 4

echo "=== verify ==="
/usr/sbin/dpdctl status -j > "$BACKUP/status.after.json" 2>/dev/null || fail "dpdctl status"
abi=$(jsonfilter -i "$BACKUP/status.after.json" -e '@.abi' 2>/dev/null || true)
[ -n "$abi" ] || fail "no ABI in status"
attached=$(jsonfilter -i "$BACKUP/status.after.json" -e '@.attached' 2>/dev/null || true)
[ "$attached" = "true" ] || fail "datapath not attached"

mode=$(jsonfilter -i "$BACKUP/status.after.json" -e '@.cfg.mode' 2>/dev/null || true)
[ -n "$mode" ] || fail "no datapath mode"

[ -s /var/run/dpd/observe.json ] || fail "dpd-observe did not write observe.json"
[ -s /var/run/dpd/honk.json ] || fail "dpd-honk did not write honk.json"

echo "PASS: abi=$abi attached=$attached mode=$mode"
