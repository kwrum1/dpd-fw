#!/bin/sh
# Remove everything tests/netns/setup.sh created and restore br-lan's MTU.
#
#   sh tests/netns/teardown.sh
#
# Safe to run twice and after a crashed setup: missing objects are ignored.
# Only names with the dpd/dpdtest prefix and the two firewall sections
# (firewall.dpd_test, firewall.dpd_test_fwd) are touched.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

STATE_FILE=${STATE_FILE:-/tmp/dpd-netns.state}

state_get() {
	[ -r "$STATE_FILE" ] || return 0
	sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1
}

CLIENT_NS=${CLIENT_NS:-$(state_get CLIENT_NS)}
SERVER_NS=${SERVER_NS:-$(state_get SERVER_NS)}
LAN_BRIDGE=${LAN_BRIDGE:-$(state_get LAN_BRIDGE)}
LAN_MTU_ORIG=${LAN_MTU_ORIG:-$(state_get LAN_MTU_ORIG)}
MTU_RAISED=${MTU_RAISED:-$(state_get MTU_RAISED)}
WAN_DUMMY=${WAN_DUMMY:-$(state_get WAN_DUMMY)}
DUMMY_DEV=${DUMMY_DEV:-$(state_get DUMMY_DEV)}
SERVER_BRIDGE=${SERVER_BRIDGE:-$(state_get SERVER_BRIDGE)}

CLIENT_NS=${CLIENT_NS:-dpd-ns-client}
SERVER_NS=${SERVER_NS:-dpd-ns-server}
LAN_BRIDGE=${LAN_BRIDGE:-br-lan}
MTU_RAISED=${MTU_RAISED:-0}
WAN_DUMMY=${WAN_DUMMY:-0}
DUMMY_DEV=${DUMMY_DEV:-dpdtest0}
SERVER_BRIDGE=${SERVER_BRIDGE:-dpdtestbr}

CLIENT_VETH_HOST=dpdc0
SERVER_VETH_HOST=dpds0

case "${1:-}" in
-h | --help)
	cat <<'EOF'
usage: teardown.sh

Removes the namespaces, veths, dummy uplink, firewall zone and restores the
br-lan MTU saved by setup.sh. Safe to run twice.
EOF
	exit 0
	;;
esac

[ "$(id -u)" = 0 ] || {
	echo "teardown.sh: must run as root" >&2
	exit 1
}
command -v ip >/dev/null 2>&1 || {
	echo "teardown.sh: ip not found" >&2
	exit 1
}

kill_ns() {
	ns=$1
	ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns" || return 0
	for pid in $(ip netns pids "$ns" 2>/dev/null); do
		kill "$pid" 2>/dev/null || true
	done
	ip netns del "$ns" 2>/dev/null || true
	echo "teardown.sh: removed namespace $ns"
}

kill_ns "$CLIENT_NS"
kill_ns "$SERVER_NS"

ip link del "$CLIENT_VETH_HOST" 2>/dev/null || true
ip link del "$SERVER_VETH_HOST" 2>/dev/null || true
# Prefix check only: never delete a user-selected real interface.
case "$DUMMY_DEV" in
dpdtest*) ip link del "$DUMMY_DEV" 2>/dev/null || true ;;
esac
case "$SERVER_BRIDGE" in
dpdtest*) ip link del "$SERVER_BRIDGE" 2>/dev/null || true ;;
esac

if [ "$MTU_RAISED" = 1 ] && [ -n "$LAN_MTU_ORIG" ] && [ -d "/sys/class/net/$LAN_BRIDGE" ]; then
	ip link set "$LAN_BRIDGE" mtu "$LAN_MTU_ORIG" 2>/dev/null || true
	echo "teardown.sh: restored $LAN_BRIDGE MTU to $LAN_MTU_ORIG"
fi

if command -v uci >/dev/null 2>&1; then
	uci -q delete firewall.dpd_test 2>/dev/null || true
	uci -q delete firewall.dpd_test_fwd 2>/dev/null || true
	uci commit firewall 2>/dev/null || true
	[ -e /etc/init.d/firewall ] && /etc/init.d/firewall reload 2>/dev/null || true
	echo "teardown.sh: removed firewall.dpd_test"
fi

rm -f "$STATE_FILE"
echo "teardown.sh: done"
