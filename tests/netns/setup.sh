#!/bin/sh
# Create the two-namespace DPD test bed on an OpenWrt router.
#
#   sh tests/netns/setup.sh
#   WAN_DUMMY=1 sh tests/netns/setup.sh      # server side on a dummy uplink
#   JUMBO=1 sh tests/netns/setup.sh          # raise MTUs for 9000-byte frames
#
# Topology:
#
#   client ns                     router                        server ns
#   192.168.10.200/24  --veth--  br-lan ... dpds0/203.0.113.1  --veth--  203.0.113.2/24
#                                                                        203.0.113.3/24
#
# The client veth is added as a port of br-lan, so client traffic follows the
# real input -> routing/NAT -> output path that DPD hooks. The server veth is
# either a plain device in a dedicated masquerading firewall zone, or (with
# WAN_DUMMY=1) a bridge member together with a dummy uplink, which looks like
# a second WAN to the routing code.
#
# The script is idempotent: it removes its own stale objects first and only
# touches names with the dpd/dpdtest prefix. The previous br-lan MTU is saved
# in the state file and restored by teardown.sh when JUMBO raised it.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

CLIENT_NS=${CLIENT_NS:-dpd-ns-client}
SERVER_NS=${SERVER_NS:-dpd-ns-server}
CLIENT_IP=${CLIENT_IP:-192.168.10.200}
CLIENT_PREFIX=${CLIENT_PREFIX:-24}
CLIENT_GW=${CLIENT_GW:-192.168.10.1}
SERVER_IP=${SERVER_IP:-203.0.113.2}
SERVER_PEER_IP=${SERVER_PEER_IP:-203.0.113.3}
SERVER_PREFIX=${SERVER_PREFIX:-24}
SERVER_GW=${SERVER_GW:-203.0.113.1}
LAN_BRIDGE=${LAN_BRIDGE:-br-lan}
LAN_ZONE=${LAN_ZONE:-lan}
WAN_DUMMY=${WAN_DUMMY:-0}
DUMMY_DEV=${DUMMY_DEV:-dpdtest0}
SERVER_BRIDGE=${SERVER_BRIDGE:-dpdtestbr}
MTU=${MTU:-1500}
[ "${JUMBO:-0}" = 1 ] && MTU=9000
STATE_FILE=${STATE_FILE:-/tmp/dpd-netns.state}

case "$MTU" in
'' | *[!0-9]*)
	echo "setup.sh: MTU must be an integer" >&2
	exit 2
	;;
esac
[ "$MTU" -ge 576 ] || {
	echo "setup.sh: MTU $MTU is too small" >&2
	exit 2
}

CLIENT_VETH_HOST=dpdc0
CLIENT_VETH_NS=dpdc1
SERVER_VETH_HOST=dpds0
SERVER_VETH_NS=dpds1

usage() {
	cat <<'EOF'
usage: setup.sh

Environment (all optional):
  CLIENT_NS, SERVER_NS        namespace names (default dpd-ns-client/server)
  CLIENT_IP/CLIENT_PREFIX     client address (default 192.168.10.200/24)
  CLIENT_GW                   client default gateway (default 192.168.10.1)
  SERVER_IP/SERVER_PREFIX     server address (default 203.0.113.2/24)
  SERVER_PEER_IP              second server address for full-cone (203.0.113.3)
  SERVER_GW                   router-side server gateway (203.0.113.1)
  LAN_BRIDGE                  existing LAN bridge (default br-lan)
  LAN_ZONE                    firewall zone of that bridge (default lan)
  WAN_DUMMY=1                 put the server veth on a dummy uplink/bridge
  DUMMY_DEV, SERVER_BRIDGE    names used by WAN_DUMMY (dpdtest0/dpdtestbr)
  MTU                         veth MTU (default 1500; use 9000 for jumbo)
  JUMBO=1                     shorthand for MTU=9000
  STATE_FILE                  state path (default /tmp/dpd-netns.state)

Run teardown.sh to remove the namespaces, veths, firewall zone and to restore
the br-lan MTU.
EOF
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { usage; exit 0; }

[ "$(id -u)" = 0 ] || {
	echo "setup.sh: must run as root" >&2
	exit 1
}
command -v ip >/dev/null 2>&1 || {
	echo "setup.sh: ip not found (install ip-full)" >&2
	exit 1
}

case "$CLIENT_IP$SERVER_IP$SERVER_PEER_IP" in
*/*)
	echo "setup.sh: pass bare addresses, not CIDR (CLIENT_IP/SERVER_IP)" >&2
	exit 2
	;;
esac
case "$DUMMY_DEV" in
dpdtest*) ;;
*)
	echo "setup.sh: DUMMY_DEV must start with dpdtest (refusing '$DUMMY_DEV')" >&2
	exit 2
	;;
esac

MTU_RAISED=0
LAN_MTU_ORIG=
SERVER_DEV=

state_get() {
	[ -r "$STATE_FILE" ] || return 0
	sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1
}

fw_delete() {
	command -v uci >/dev/null 2>&1 || return 0
	uci -q delete firewall.dpd_test 2>/dev/null || true
	uci -q delete firewall.dpd_test_fwd 2>/dev/null || true
	uci commit firewall 2>/dev/null || true
}

cleanup_all() {
	ip netns del "$CLIENT_NS" 2>/dev/null || true
	ip netns del "$SERVER_NS" 2>/dev/null || true
	ip link del "$CLIENT_VETH_HOST" 2>/dev/null || true
	ip link del "$SERVER_VETH_HOST" 2>/dev/null || true
	# Always try the dummy-side objects: a previous run may have used
	# WAN_DUMMY=1 while the current environment does not.
	case "$DUMMY_DEV" in
	dpdtest*) ip link del "$DUMMY_DEV" 2>/dev/null || true ;;
	esac
	case "$SERVER_BRIDGE" in
	dpdtest*) ip link del "$SERVER_BRIDGE" 2>/dev/null || true ;;
	esac
	if [ "$MTU_RAISED" = 1 ] && [ -n "$LAN_MTU_ORIG" ] && [ -d "/sys/class/net/$LAN_BRIDGE" ]; then
		ip link set "$LAN_BRIDGE" mtu "$LAN_MTU_ORIG" 2>/dev/null || true
	fi
	fw_delete
	[ -e /etc/init.d/firewall ] && /etc/init.d/firewall reload 2>/dev/null || true
}

die() {
	echo "setup.sh: $*" >&2
	cleanup_all
	exit 1
}

trap 'cleanup_all; exit 1' 1 2 15

# Probe before touching anything: some `ip` builds lack netns support.
probe="dpd-ns-probe.$$"
ip netns add "$probe" 2>/dev/null || {
	echo "setup.sh: this ip does not support netns (install ip-full)" >&2
	exit 1
}
ip netns del "$probe" 2>/dev/null || true

[ -d "/sys/class/net/$LAN_BRIDGE" ] || {
	echo "setup.sh: LAN bridge '$LAN_BRIDGE' does not exist (set LAN_BRIDGE)" >&2
	exit 1
}

# Remove stale objects from a previous run (or a crashed one). Preserve a
# previous MTU raise so re-running setup with JUMBO=1 does not overwrite the
# original br-lan MTU with 9000.
PREV_RAISED=$(state_get MTU_RAISED)
PREV_ORIG=$(state_get LAN_MTU_ORIG)
cleanup_all
rm -f "$STATE_FILE"

LAN_MTU_ORIG=$(cat "/sys/class/net/$LAN_BRIDGE/mtu" 2>/dev/null || echo 1500)
if [ "$PREV_RAISED" = 1 ] && [ -n "$PREV_ORIG" ]; then
	LAN_MTU_ORIG=$PREV_ORIG
	MTU_RAISED=1
	CUR_MTU=$(cat "/sys/class/net/$LAN_BRIDGE/mtu" 2>/dev/null || echo 1500)
	if [ "$CUR_MTU" -lt "$MTU" ] 2>/dev/null; then
		ip link set "$LAN_BRIDGE" mtu "$MTU" || die "cannot raise $LAN_BRIDGE MTU to $MTU"
	fi
elif [ "$MTU" -gt "$LAN_MTU_ORIG" ] 2>/dev/null; then
	ip link set "$LAN_BRIDGE" mtu "$MTU" || die "cannot raise $LAN_BRIDGE MTU to $MTU"
	MTU_RAISED=1
fi

ip netns add "$CLIENT_NS" || die "cannot create namespace $CLIENT_NS"
ip netns add "$SERVER_NS" || die "cannot create namespace $SERVER_NS"

ip link add "$CLIENT_VETH_HOST" type veth peer name "$CLIENT_VETH_NS" ||
	die "cannot create client veth"
ip link add "$SERVER_VETH_HOST" type veth peer name "$SERVER_VETH_NS" ||
	die "cannot create server veth"
ip link set "$CLIENT_VETH_NS" netns "$CLIENT_NS" || die "cannot move client veth"
ip link set "$SERVER_VETH_NS" netns "$SERVER_NS" || die "cannot move server veth"

# ---- client namespace --------------------------------------------------
ip netns exec "$CLIENT_NS" ip link set lo up || die "client lo"
ip netns exec "$CLIENT_NS" ip link set "$CLIENT_VETH_NS" name eth0 ||
	die "cannot rename client veth"
ip netns exec "$CLIENT_NS" ip link set eth0 mtu "$MTU" up ||
	die "cannot bring up client eth0"
ip netns exec "$CLIENT_NS" ip addr replace "$CLIENT_IP/$CLIENT_PREFIX" dev eth0 ||
	die "cannot assign $CLIENT_IP"
ip netns exec "$CLIENT_NS" ip route replace default via "$CLIENT_GW" ||
	die "cannot add client default route"

# ---- server namespace --------------------------------------------------
ip netns exec "$SERVER_NS" ip link set lo up || die "server lo"
ip netns exec "$SERVER_NS" ip link set "$SERVER_VETH_NS" name eth0 ||
	die "cannot rename server veth"
ip netns exec "$SERVER_NS" ip link set eth0 mtu "$MTU" up ||
	die "cannot bring up server eth0"
ip netns exec "$SERVER_NS" ip addr replace "$SERVER_IP/$SERVER_PREFIX" dev eth0 ||
	die "cannot assign $SERVER_IP"
if [ -n "$SERVER_PEER_IP" ]; then
	ip netns exec "$SERVER_NS" ip addr replace "$SERVER_PEER_IP/$SERVER_PREFIX" dev eth0 ||
		die "cannot assign peer address $SERVER_PEER_IP"
fi
ip netns exec "$SERVER_NS" ip route replace default via "$SERVER_GW" ||
	die "cannot add server default route"

# ---- router side -------------------------------------------------------
ip link set "$CLIENT_VETH_HOST" mtu "$MTU" up || die "client veth up"
ip link set "$CLIENT_VETH_HOST" master "$LAN_BRIDGE" ||
	die "cannot add $CLIENT_VETH_HOST to $LAN_BRIDGE"

if [ "$WAN_DUMMY" = 1 ]; then
	ip link add "$SERVER_BRIDGE" type bridge || die "cannot create $SERVER_BRIDGE"
	ip link set "$SERVER_BRIDGE" mtu "$MTU" up || die "cannot bring up $SERVER_BRIDGE"
	ip link add "$DUMMY_DEV" type dummy || die "cannot create $DUMMY_DEV"
	ip link set "$DUMMY_DEV" mtu "$MTU" up || die "cannot bring up $DUMMY_DEV"
	ip link set "$DUMMY_DEV" master "$SERVER_BRIDGE" || die "dummy -> bridge"
	ip link set "$SERVER_VETH_HOST" mtu "$MTU" up || die "server veth up"
	ip link set "$SERVER_VETH_HOST" master "$SERVER_BRIDGE" || die "server veth -> bridge"
	ip addr replace "$SERVER_GW/$SERVER_PREFIX" dev "$SERVER_BRIDGE" ||
		die "cannot assign $SERVER_GW"
	SERVER_DEV=$SERVER_BRIDGE
else
	ip link set "$SERVER_VETH_HOST" mtu "$MTU" up || die "server veth up"
	ip addr replace "$SERVER_GW/$SERVER_PREFIX" dev "$SERVER_VETH_HOST" ||
		die "cannot assign $SERVER_GW"
	SERVER_DEV=$SERVER_VETH_HOST
fi

# ---- firewall ----------------------------------------------------------
# A dedicated zone keeps this out of the real lan/wan config. fw4 accepts a
# list of devices per zone; the forwarding rule allows client -> server and
# masq makes the server see the router as its peer.
if command -v uci >/dev/null 2>&1; then
	uci -q delete firewall.dpd_test || true
	uci set firewall.dpd_test=zone
	uci set firewall.dpd_test.name='dpd_test'
	uci set firewall.dpd_test.input='ACCEPT'
	uci set firewall.dpd_test.output='ACCEPT'
	uci set firewall.dpd_test.forward='ACCEPT'
	uci set firewall.dpd_test.masq='1'
	uci set firewall.dpd_test.mtu_fix='1'
	uci add_list firewall.dpd_test.device="$SERVER_DEV"
	uci -q delete firewall.dpd_test_fwd || true
	uci set firewall.dpd_test_fwd=forwarding
	uci set firewall.dpd_test_fwd.src="$LAN_ZONE"
	uci set firewall.dpd_test_fwd.dest='dpd_test'
	uci commit firewall || die "cannot commit firewall"
	[ -e /etc/init.d/firewall ] && /etc/init.d/firewall reload 2>/dev/null || true
else
	echo "setup.sh: uci not found; add $SERVER_DEV to a masquerading zone manually" >&2
fi

# ---- state -------------------------------------------------------------
{
	echo "CLIENT_NS=$CLIENT_NS"
	echo "SERVER_NS=$SERVER_NS"
	echo "CLIENT_IP=$CLIENT_IP"
	echo "SERVER_IP=$SERVER_IP"
	echo "SERVER_PEER_IP=$SERVER_PEER_IP"
	echo "LAN_BRIDGE=$LAN_BRIDGE"
	echo "LAN_MTU_ORIG=$LAN_MTU_ORIG"
	echo "MTU_RAISED=$MTU_RAISED"
	echo "MTU=$MTU"
	echo "WAN_DUMMY=$WAN_DUMMY"
	echo "DUMMY_DEV=$DUMMY_DEV"
	echo "SERVER_BRIDGE=$SERVER_BRIDGE"
	echo "SERVER_DEV=$SERVER_DEV"
} >"$STATE_FILE"
chmod 600 "$STATE_FILE" 2>/dev/null || true

probe=ok
ip netns exec "$CLIENT_NS" ping -c 1 -W 2 "$SERVER_IP" >/dev/null 2>&1 || probe=fail
[ "$probe" = ok ] || echo "setup.sh: client -> server probe failed; check firewall/DPD" >&2

cat <<EOF
client_ns=$CLIENT_NS
server_ns=$SERVER_NS
client_ip=$CLIENT_IP/$CLIENT_PREFIX
server_ip=$SERVER_IP/$SERVER_PREFIX
server_peer_ip=$SERVER_PEER_IP
server_dev=$SERVER_DEV
lan_bridge=$LAN_BRIDGE
mtu=$MTU
state=$STATE_FILE
probe=$probe
EOF

cat <<'EOF' >&2
setup.sh: done. Run a scenario, for example:
  sh tests/netns/run.sh ping
  sh tests/netns/run.sh --size 64 --flows 10 --seconds 10 udp
  sh tests/netns/teardown.sh
EOF
