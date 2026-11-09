#!/bin/sh
# IPv6 routed-path scenario for DPD.
#
#   sh tests/netns/ipv6.sh
#   sh tests/netns/ipv6.sh --client6 fd00:10::2/64 --peer6 fd00:20::3/64
#   sh tests/netns/ipv6.sh --dry-run
#
# The script adds one ULA /64 on each side of the router:
#
#   client ns                    router                       server ns
#   fd00:10::2/64 -- veth -- br-lan fd00:10::1/64
#                              dpds0 fd00:20::1/64 -- veth -- fd00:20::3/64
#
# It pings the peer, then runs a TCP transfer large enough to cross
# dpd_cfg.accel_after_pkts (default 32). A pass means:
#   - ping6 got replies (routing/forwarding through br-lan and dpd_test),
#   - dpd_stats.v6_ok grew (DPD actually took over an IPv6 packet),
#   - at least two new AF_INET6 entries appeared in dpd_flows (forward
#     learned, and the reverse entry seeded with it).
#
# IPv6 is routed-only here: there is no NAT66. DPD accelerates only
# LAN->WAN TCP/UDP without extension headers or fragments; replies stay on
# the stack because conntrack is authoritative for them.
#
# Exit: 0 PASS or --dry-run, 1 FAIL, 2 usage/setup, 3 SKIP (no IPv6).
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

CLIENT_NS=${CLIENT_NS:-dpd-ns-client}
SERVER_NS=${SERVER_NS:-dpd-ns-server}
CLIENT_IP=${CLIENT_IP:-192.168.10.200}
SERVER_IP=${SERVER_IP:-203.0.113.2}
STATE_FILE=${STATE_FILE:-/tmp/dpd-netns.state}
CLIENT6=${CLIENT6:-fd00:10::2/64}
PEER6=${PEER6:-fd00:20::3/64}
CLIENT6_DEV=${CLIENT6_DEV:-eth0}
SERVER6_DEV=${SERVER6_DEV:-eth0}
TCP_PORT=${TCP_PORT:-5401}
TCP_BYTES=${TCP_BYTES:-262144}
TIMEOUT=${TIMEOUT:-8}
DPDCTL=${DPDCTL:-dpdctl}

DRY_RUN=0
WORK=/tmp/dpd-netns-ipv6.$$
PIDS=

fwd_orig=
fwd_changed=0
lan6_added=0
srv6_added=0

usage() {
	cat <<'EOF'
usage: ipv6.sh [options]

  --client6 ADDR/64   client ULA (default fd00:10::2/64)
  --peer6 ADDR/64     WAN-side peer ULA (default fd00:20::3/64)
  --dry-run           print the commands and exit without changing anything
  -h, --help          this text

The two /64s must differ. The gateways are derived from the addresses
(fd00:10::2 -> fd00:10::1) and added temporarily to br-lan and to the
server-side device found from the route to SERVER_IP.

Environment: CLIENT_NS, SERVER_NS, CLIENT_IP, SERVER_IP, STATE_FILE,
CLIENT6, PEER6, CLIENT6_DEV, SERVER6_DEV, TCP_PORT, TCP_BYTES, TIMEOUT,
DPDCTL.

A skip (exit 3) means the environment has no IPv6: IPv6 is disabled in a
namespace, the kernel has no IPv6, DPD's ipv6 option is off, or the peer
cannot be configured. A fail (exit 1) means IPv6 was configured but the
traffic or the DPD counters did not behave as required.
EOF
}

die() {
	echo "ipv6.sh: $*" >&2
	exit 2
}

skip() {
	echo "ipv6: SKIP ($*)"
	exit 3
}

fail() {
	echo "ipv6: FAIL ($*)" >&2
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

step() {
	printf '[%s] %s\n' "$1" "$2"
}

show_py() {
	ns=$1
	code=$2
	suffix=$3
	shift 3
	printf 'ip netns exec %s python3 -' "$ns"
	for a in "$@"; do
		printf ' %s' "$a"
	done
	printf " <<'PY'%s\n" "$suffix"
	printf '%s\n' "$code"
	printf 'PY\n'
}

# Drop the /prefix, then replace the host part with ::1. For a /64 ULA
# (fd00:10::2 -> fd00:10::1) that is always inside the same prefix.
gw_of() {
	case "$1" in
	*::*) printf '%s::1' "${1%::*}" ;;
	*) printf '%s:1' "${1%:*}" ;;
	esac
}

state_get() {
	[ -r "$STATE_FILE" ] || return 0
	sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1
}

dev_for() {
	ip -o route get "$1" 2>/dev/null | awk '{
		for (i = 1; i <= NF; i++)
			if ($i == "dev") { print $(i + 1); exit }
	}'
}

v6_ok() {
	"$DPDCTL" stats 2>/dev/null | awk '$2 == "v6_ok" { print $3; exit }'
}

v6_flows() {
	"$DPDCTL" flows -a 2>/dev/null |
		awk '$2 == "fam=10" { n++ } END { print n + 0 }'
}

PY_TCP_SRV='
import socket, sys
port = int(sys.argv[1])
timeout = float(sys.argv[2])
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("::", port))
s.listen(1)
s.settimeout(timeout)
try:
	c, a = s.accept()
except OSError:
	print("accept-timeout")
	sys.exit(1)
n = 0
while True:
	d = c.recv(65536)
	if not d:
		break
	n += len(d)
print("bytes", n)
'

PY_TCP_CLI='
import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
left = int(sys.argv[3])
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.settimeout(8.0)
s.connect((host, port))
buf = b"x" * 65536
while left > 0:
	n = min(left, len(buf))
	s.sendall(buf[:n])
	left -= n
s.shutdown(socket.SHUT_WR)
s.close()
'

while [ $# -gt 0 ]; do
	case "$1" in
	--client6)
		[ $# -ge 2 ] || die "--client6 wants a value"
		CLIENT6=$2
		shift 2
		;;
	--peer6)
		[ $# -ge 2 ] || die "--peer6 wants a value"
		PEER6=$2
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		usage >&2
		exit 2
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

CLIENT6_ADDR=${CLIENT6%%/*}
PEER6_ADDR=${PEER6%%/*}
case "$CLIENT6" in */*) CLIENT6_PFX=${CLIENT6##*/} ;; *) CLIENT6_PFX=64 ;; esac
case "$PEER6" in */*) PEER6_PFX=${PEER6##*/} ;; *) PEER6_PFX=64 ;; esac

case "$CLIENT6_ADDR" in *:*) ;; *) die "--client6 must be an IPv6 address" ;; esac
case "$PEER6_ADDR" in *:*) ;; *) die "--peer6 must be an IPv6 address" ;; esac
case "$CLIENT6_ADDR$PEER6_ADDR" in
*[!0-9A-Fa-f:]*) die "IPv6 addresses must contain only hex digits and colons" ;;
esac
case "$CLIENT6_PFX" in '' | *[!0-9]*) die "--client6 prefix must be numeric" ;; esac
case "$PEER6_PFX" in '' | *[!0-9]*) die "--peer6 prefix must be numeric" ;; esac
[ "$CLIENT6_PFX" = 64 ] || die "--client6 must use /64"
[ "$PEER6_PFX" = 64 ] || die "--peer6 must use /64"

CLIENT6_GW=$(gw_of "$CLIENT6_ADDR")
PEER6_GW=$(gw_of "$PEER6_ADDR")
[ "$CLIENT6_GW" != "$PEER6_GW" ] ||
	die "--client6 and --peer6 must be in different /64s"

for n in "$TCP_PORT" "$TCP_BYTES" "$TIMEOUT"; do
	case "$n" in '' | *[!0-9]*) die "TCP_PORT, TCP_BYTES and TIMEOUT must be integers" ;; esac
done
[ "$TCP_PORT" -ge 1 ] && [ "$TCP_PORT" -le 65535 ] ||
	die "TCP_PORT must be 1..65535"
[ "$TCP_BYTES" -gt 0 ] || die "TCP_BYTES must be > 0"
[ "$TIMEOUT" -gt 0 ] || die "TIMEOUT must be > 0"

# Read-only discovery is safe in --dry-run; fall back to setup.sh's names.
LAN_DEV=$(dev_for "$CLIENT_IP")
SERVER_DEV=$(dev_for "$SERVER_IP")
LAN_DEV=${LAN_DEV:-$(state_get LAN_BRIDGE)}
SERVER_DEV=${SERVER_DEV:-$(state_get SERVER_DEV)}
LAN_DEV=${LAN_DEV:-br-lan}
SERVER_DEV=${SERVER_DEV:-dpds0}

if [ "$DRY_RUN" = 1 ]; then
	echo "ipv6.sh: DRY RUN, nothing will be changed"
	echo "  client socket: $CLIENT6_ADDR/$CLIENT6_PFX on $CLIENT6_DEV (ns $CLIENT_NS)"
	echo "  peer socket:   $PEER6_ADDR/$PEER6_PFX on $SERVER6_DEV (ns $SERVER_NS)"
	echo "  router sides:  $CLIENT6_GW/64 on $LAN_DEV, $PEER6_GW/64 on $SERVER_DEV"

	step 1/6 "add IPv6 addresses and host routes"
	echo "ip netns exec $CLIENT_NS ip -6 addr replace $CLIENT6_ADDR/64 dev $CLIENT6_DEV nodad"
	echo "ip netns exec $SERVER_NS ip -6 addr replace $PEER6_ADDR/64 dev $SERVER6_DEV nodad"
	echo "ip -6 addr replace $CLIENT6_GW/64 dev $LAN_DEV nodad"
	echo "ip -6 addr replace $PEER6_GW/64 dev $SERVER_DEV nodad"
	echo "ip netns exec $CLIENT_NS ip -6 route replace $PEER6_ADDR/128 via $CLIENT6_GW dev $CLIENT6_DEV"
	echo "ip netns exec $SERVER_NS ip -6 route replace $CLIENT6_ADDR/128 via $PEER6_GW dev $SERVER6_DEV"

	step 2/6 "enable forwarding (the live run saves and restores the old value)"
	echo "echo 1 > /proc/sys/net/ipv6/conf/all/forwarding"

	step 3/6 "ping the peer"
	if have ping6; then
		echo "ip netns exec $CLIENT_NS ping6 -c 3 -W 2 $PEER6_ADDR"
	else
		echo "ip netns exec $CLIENT_NS ping -6 -c 3 -W 2 $PEER6_ADDR"
	fi

	step 4/6 "check DPD's IPv6 switch and take the flow/counter baseline"
	echo "dpdctl show | awk '\$1 == \"ipv6\" { print \$2 }'   # must print 1"
	echo "dpdctl stats | awk '\$2 == \"v6_ok\" { print \$3 }'"
	echo "dpdctl flows -a | awk '\$2 == \"fam=10\" { n++ } END { print n + 0 }'"

	step 5/6 "TCP transfer of $TCP_BYTES bytes from $CLIENT6_ADDR to $PEER6_ADDR"
	if have iperf3; then
		echo "ip netns exec $SERVER_NS iperf3 -s -1 -6 -p $TCP_PORT &"
		echo "ip netns exec $CLIENT_NS iperf3 -6 -c $PEER6_ADDR -p $TCP_PORT -n $TCP_BYTES"
	elif have python3; then
		show_py "$SERVER_NS" "$PY_TCP_SRV" " &" "$TCP_PORT" "$TIMEOUT"
		show_py "$CLIENT_NS" "$PY_TCP_CLI" "" \
			"$PEER6_ADDR" "$TCP_PORT" "$TCP_BYTES"
	elif have nc && have timeout; then
		echo "ip netns exec $SERVER_NS sh -c 'timeout $((TIMEOUT + 6)) nc -l -p $TCP_PORT >/dev/null' &"
		echo "ip netns exec $CLIENT_NS sh -c 'dd if=/dev/zero bs=1024 count=$((TCP_BYTES / 1024)) 2>/dev/null | timeout $TIMEOUT nc $PEER6_ADDR $TCP_PORT'"
		echo "  # install iperf3 or python3: busybox nc may listen on IPv4 only"
	else
		echo "  # no iperf3, python3 or nc found; install one to run the transfer"
	fi

	step 6/6 "read the counters again"
	echo "dpdctl stats | awk '\$2 == \"v6_ok\" { print \$3 }'"
	echo "dpdctl flows -a | awk '\$2 == \"fam=10\" { n++ } END { print n + 0 }'"
	echo "  PASS needs: ping replies > 0, v6_ok delta > 0, fam=10 flow delta >= 2"
	echo "ipv6: DRY-RUN (no address, sysctl, route or counter was changed)"
	exit 0
fi

[ "$(id -u)" = 0 ] || die "must run as root"
have ip || die "ip not found (install ip-full)"
ip netns exec "$CLIENT_NS" true 2>/dev/null ||
	die "namespace $CLIENT_NS missing; run tests/netns/setup.sh first"
ip netns exec "$SERVER_NS" true 2>/dev/null ||
	die "namespace $SERVER_NS missing; run tests/netns/setup.sh first"

# IPv6 is per-network-namespace. A missing proc file means the kernel (or
# this namespace) has no IPv6 at all; disable_ipv6=1 is the other skip.
root_state=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) ||
	root_state=missing
case "$root_state" in
missing | '')
	skip "the router namespace has no IPv6 (no /proc/sys/net/ipv6; kernel built without IPv6?)"
	;;
1)
	skip "IPv6 is disabled on the router (net.ipv6.conf.all.disable_ipv6=1)"
	;;
esac
for ns in "$CLIENT_NS" "$SERVER_NS"; do
	state=$(ip netns exec "$ns" cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) ||
		state=missing
	case "$state" in
	missing | '')
		skip "namespace $ns has no IPv6 (no /proc/sys/net/ipv6; kernel built without IPv6?)"
		;;
	1)
		skip "IPv6 is disabled in $ns (net.ipv6.conf.all.disable_ipv6=1)"
		;;
	esac
done

have "$DPDCTL" || skip "dpdctl not found; cannot read v6_ok or dpd_flows"
"$DPDCTL" show >/dev/null 2>&1 ||
	skip "dpdctl cannot read dpd_cfg (is dpd-fastpath loaded?)"

dpd_enable=$("$DPDCTL" show 2>/dev/null | awk '$1 == "enable" { print $2; exit }')
dpd_mode=$("$DPDCTL" show 2>/dev/null | awk '$1 == "mode" { print $2; exit }')
dpd_ipv6=$("$DPDCTL" show 2>/dev/null | awk '$1 == "ipv6" { print $2; exit }')

[ "$dpd_enable" = 1 ] || skip "DPD is disabled (enable=0)"
case "$dpd_mode" in
off | observe)
	skip "DPD mode is '$dpd_mode'; v6_ok cannot grow"
	;;
esac
case "$dpd_ipv6" in
1) ;;
'') skip "dpdctl show has no ipv6 field (object older than ABI 10?)" ;;
*)
	skip "DPD IPv6 acceleration is off (ipv6=$dpd_ipv6); set option ipv6 '1' or run dpdctl set ipv6 1"
	;;
esac

if have ping6; then
	PING="ping6"
elif have ping; then
	PING="ping -6"
else
	skip "ping6 not found"
fi

ENGINE=
if have iperf3; then
	ENGINE=iperf3
elif have python3; then
	ENGINE=python3
elif have nc && have timeout; then
	ENGINE=nc
fi
[ -n "$ENGINE" ] ||
	skip "need iperf3, python3, or nc+timeout for the TCP transfer"

mkdir -p "$WORK" || die "cannot create $WORK"

cleanup() {
	for p in ${PIDS:-}; do
		kill "$p" 2>/dev/null || true
	done
	for p in ${PIDS:-}; do
		wait "$p" 2>/dev/null || true
	done
	ip netns exec "${CLIENT_NS:-dpd-ns-client}" ip -6 route del \
		"${PEER6_ADDR:-fd00:20::3}/128" >/dev/null 2>&1 || true
	ip netns exec "${SERVER_NS:-dpd-ns-server}" ip -6 route del \
		"${CLIENT6_ADDR:-fd00:10::2}/128" >/dev/null 2>&1 || true
	ip netns exec "${CLIENT_NS:-dpd-ns-client}" ip -6 addr del \
		"${CLIENT6_ADDR:-fd00:10::2}/${CLIENT6_PFX:-64}" \
		dev "${CLIENT6_DEV:-eth0}" >/dev/null 2>&1 || true
	ip netns exec "${SERVER_NS:-dpd-ns-server}" ip -6 addr del \
		"${PEER6_ADDR:-fd00:20::3}/${PEER6_PFX:-64}" \
		dev "${SERVER6_DEV:-eth0}" >/dev/null 2>&1 || true
	if [ "${fwd_changed:-0}" = 1 ] && [ -n "${fwd_orig:-}" ]; then
		printf '%s\n' "$fwd_orig" \
			> /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
	fi
	if [ "${lan6_added:-0}" = 1 ]; then
		ip -6 addr del "${CLIENT6_GW:-fd00:10::1}/${CLIENT6_PFX:-64}" \
			dev "${LAN_DEV:-br-lan}" >/dev/null 2>&1 || true
	fi
	if [ "${srv6_added:-0}" = 1 ]; then
		ip -6 addr del "${PEER6_GW:-fd00:20::1}/${PEER6_PFX:-64}" \
			dev "${SERVER_DEV:-dpds0}" >/dev/null 2>&1 || true
	fi
	rm -rf "${WORK:-/tmp/dpd-netns-ipv6.$$}"
}
trap 'cleanup' 0 1 2 15

step 1/6 "add IPv6 addresses and host routes"
ip netns exec "$CLIENT_NS" ip -6 addr replace \
	"$CLIENT6_ADDR/$CLIENT6_PFX" dev "$CLIENT6_DEV" nodad ||
	skip "cannot assign $CLIENT6_ADDR to $CLIENT6_DEV in $CLIENT_NS"
ip netns exec "$SERVER_NS" ip -6 addr replace \
	"$PEER6_ADDR/$PEER6_PFX" dev "$SERVER6_DEV" nodad ||
	skip "peer $SERVER_NS has no usable IPv6 (cannot assign $PEER6_ADDR)"

if ! ip -6 addr show dev "$LAN_DEV" 2>/dev/null |
	grep -qF "inet6 $CLIENT6_GW/"; then
	ip -6 addr replace "$CLIENT6_GW/$CLIENT6_PFX" dev "$LAN_DEV" nodad ||
		skip "cannot assign $CLIENT6_GW to $LAN_DEV"
	lan6_added=1
fi
if ! ip -6 addr show dev "$SERVER_DEV" 2>/dev/null |
	grep -qF "inet6 $PEER6_GW/"; then
	ip -6 addr replace "$PEER6_GW/$PEER6_PFX" dev "$SERVER_DEV" nodad ||
		skip "cannot assign $PEER6_GW to $SERVER_DEV"
	srv6_added=1
fi

ip netns exec "$CLIENT_NS" ip -6 route replace \
	"$PEER6_ADDR/128" via "$CLIENT6_GW" dev "$CLIENT6_DEV" ||
	skip "cannot route $PEER6_ADDR via $CLIENT6_GW in $CLIENT_NS"
ip netns exec "$SERVER_NS" ip -6 route replace \
	"$CLIENT6_ADDR/128" via "$PEER6_GW" dev "$SERVER6_DEV" ||
	skip "cannot route $CLIENT6_ADDR via $PEER6_GW in $SERVER_NS"

step 2/6 "enable IPv6 forwarding"
fwd_orig=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)
case "$fwd_orig" in '' | *[!0-9]*) fwd_orig=0 ;; esac
if [ "$fwd_orig" != 1 ]; then
	echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null ||
		skip "cannot enable net.ipv6.conf.all.forwarding"
	fwd_changed=1
fi

step 3/6 "ping6 $PEER6_ADDR from $CLIENT_NS"
# shellcheck disable=SC2086
ping_out=$(ip netns exec "$CLIENT_NS" $PING -c 3 -W 2 "$PEER6_ADDR" 2>&1)
ping_rc=$?
ping_rx=$(printf '%s\n' "$ping_out" | awk '
	/packets transmitted/ {
		for (i = 1; i <= NF; i++)
			if ($i == "received," || $i == "received") {
				# busybox: "3 packets received"; iputils: "3 received"
				if ($(i - 1) ~ /^[0-9]+$/)
					print $(i - 1)
				else if ($(i - 2) ~ /^[0-9]+$/)
					print $(i - 2)
				exit
			}
	}')
case "$ping_rx" in '' | *[!0-9]*) ping_rx=0 ;; esac
if [ "$ping_rc" != 0 ]; then
	printf '%s\n' "$ping_out" | sed 's/^/  ping6: /' >&2
	fail "no ping6 replies from $PEER6_ADDR (check fw4 lan->dpd_test and IPv6 forwarding)"
fi
if [ "$ping_rx" = 0 ]; then
	echo "  ping6: replies (summary not parsed; exit status was 0)"
else
	printf '  ping6: %s replies\n' "$ping_rx"
fi

step 4/6 "check DPD IPv6 and take the baseline"
v6_before=$(v6_ok)
case "$v6_before" in '' | *[!0-9]*) skip "dpdctl stats has no v6_ok counter" ;; esac
flow_before=$(v6_flows)

step 5/6 "TCP $TCP_BYTES bytes from $CLIENT6_ADDR to $PEER6_ADDR ($ENGINE)"
case "$ENGINE" in
iperf3)
	ip netns exec "$SERVER_NS" iperf3 -s -1 -6 -p "$TCP_PORT" \
		>"$WORK/iperf-server.log" 2>&1 &
	SPID=$!
	PIDS="$PIDS $SPID"
	sleep 1
	ip netns exec "$CLIENT_NS" iperf3 -6 -c "$PEER6_ADDR" \
		-p "$TCP_PORT" -n "$TCP_BYTES" >"$WORK/iperf-client.log" 2>&1
	tcp_rc=$?
	kill "$SPID" 2>/dev/null || true
	wait "$SPID" 2>/dev/null || true
	;;
python3)
	printf '%s\n' "$PY_TCP_SRV" |
		ip netns exec "$SERVER_NS" python3 - "$TCP_PORT" "$TIMEOUT" \
			>"$WORK/tcp-server.log" 2>&1 &
	SPID=$!
	PIDS="$PIDS $SPID"
	sleep 1
	printf '%s\n' "$PY_TCP_CLI" |
		ip netns exec "$CLIENT_NS" python3 - "$PEER6_ADDR" \
			"$TCP_PORT" "$TCP_BYTES" >"$WORK/tcp-client.log" 2>&1
	tcp_rc=$?
	kill "$SPID" 2>/dev/null || true
	wait "$SPID" 2>/dev/null || true
	;;
nc)
	ip netns exec "$SERVER_NS" sh -c \
		"timeout $((TIMEOUT + 6)) nc -l -p $TCP_PORT >/dev/null" &
	SPID=$!
	PIDS="$PIDS $SPID"
	sleep 1
	ip netns exec "$CLIENT_NS" sh -c \
		"dd if=/dev/zero bs=1024 count=$((TCP_BYTES / 1024)) 2>/dev/null | timeout $TIMEOUT nc $PEER6_ADDR $TCP_PORT"
	tcp_rc=$?
	kill "$SPID" 2>/dev/null || true
	wait "$SPID" 2>/dev/null || true
	;;
esac

if [ "$tcp_rc" != 0 ]; then
	echo "  iperf/transfer rc=$tcp_rc" >&2
	[ -f "$WORK/iperf-client.log" ] &&
		sed 's/^/  iperf3: /' "$WORK/iperf-client.log" >&2
	[ -f "$WORK/tcp-client.log" ] &&
		sed 's/^/  tcp: /' "$WORK/tcp-client.log" >&2
	fail "$ENGINE TCP transfer failed (busybox nc may be IPv4-only; use iperf3 or python3)"
fi
if [ "$ENGINE" = python3 ]; then
	srv_bytes=$(awk '/^bytes /{print $2; exit}' "$WORK/tcp-server.log" 2>/dev/null)
	[ -n "$srv_bytes" ] && printf '  server received %s bytes\n' "$srv_bytes"
fi
sleep 1

step 6/6 "read v6_ok and the AF_INET6 flow entries"
v6_after=$(v6_ok)
case "$v6_after" in '' | *[!0-9]*) fail "cannot read v6_ok after the transfer" ;; esac
flow_after=$(v6_flows)
v6_delta=$((v6_after - v6_before))
flow_delta=$((flow_after - flow_before))
printf '  v6_ok %s -> %s (delta %s)\n' "$v6_before" "$v6_after" "$v6_delta"
printf '  fam=10 flows %s -> %s (delta %s)\n' \
	"$flow_before" "$flow_after" "$flow_delta"

if [ "$v6_delta" -le 0 ]; then
	fail "v6_ok did not grow; DPD did not take over an IPv6 packet (see dpdctl stats | grep -E 'v6_ok|v6_skip')"
fi
if [ "$flow_delta" -lt 2 ]; then
	fail "expected forward+reverse AF_INET6 flow entries (delta $flow_delta); see dpdctl flows -a"
fi

echo "ipv6: PASS (ping6 ok; v6_ok +$v6_delta; AF_INET6 flows +$flow_delta)"
exit 0
