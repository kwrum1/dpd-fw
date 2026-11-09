#!/bin/sh
# Endpoint-Independent Filtering (EIF / full-cone NAT) check for DPD + einat.
#
#   sh tests/netns/full-cone.sh --mapped-port 20001
#   sh tests/netns/full-cone.sh --mapped-port 20001 --external-ip 198.18.0.1
#   sh tests/netns/full-cone.sh --dry-run --mapped-port 20001
#
# The client creates a UDP mapping by sending to peer A, then an unrelated
# peer B (different IP and port) sends to the mapping's external tuple. With
# endpoint-independent filtering the datagram must reach the client socket.
#
# einat allocates the external port, so this script never guesses it:
# pass --mapped-port. To find it, inspect einat's binding map for the
# client's internal tuple:
#
#   bpftool map dump name map_binding
#
# The ORIG binding (flags bit 0) has key.from_addr/key.from_port = the
# client tuple, key.l4proto = 17 (UDP), and value.to_addr/value.to_port =
# the external tuple. `logread | grep dpd-einat-sync` only confirms that
# the mirror is running; it does not print individual ports. Alternatively
# run the script once: step 3 reports the tuple peer A observed, and the
# failure message tells you which --mapped-port/--external-ip to use. The
# UDP binding normally survives long enough for the corrected re-run.
#
# The sender/receiver is a small inline python3 socket program (busybox nc
# is not assumed to implement -u). Without python3 the script exits 2;
# --dry-run still prints the exact commands and sends no packets.
#
# Exit: 0 PASS or --dry-run, 1 FAIL, 2 usage/prerequisite.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

CLIENT_NS=${CLIENT_NS:-dpd-ns-client}
SERVER_NS=${SERVER_NS:-dpd-ns-server}
CLIENT_IP=${CLIENT_IP:-192.168.10.200}
SERVER_IP=${SERVER_IP:-203.0.113.2}
SERVER_PEER_IP=${SERVER_PEER_IP:-203.0.113.3}
# setup.sh masquerades via 203.0.113.1. On the ESXi lab einat's WAN address
# is 198.18.0.1, hence the --external-ip example in the README.
EXTERNAL_IP=${EXTERNAL_IP:-203.0.113.1}
EIF_CLIENT_PORT=${EIF_CLIENT_PORT:-40000}
EIF_A_PORT=${EIF_A_PORT:-9000}
EIF_B_PORT=${EIF_B_PORT:-9001}
TIMEOUT=${TIMEOUT:-6}

MAPPED_PORT=
DRY_RUN=0
WORK=/tmp/dpd-netns-full-cone.$$
PIDS=

usage() {
	cat <<'EOF'
usage: full-cone.sh --mapped-port PORT [options]

  --mapped-port PORT   einat's external port for CLIENT_IP:EIF_CLIENT_PORT
                       (required; the script does not guess it)
  --external-ip ADDR   external address to send to (default 203.0.113.1,
                       i.e. SERVER_GW from setup.sh; 198.18.0.1 on the lab)
  --dry-run            print the commands and exit without sending packets
  -h, --help           this text

Environment: CLIENT_NS, SERVER_NS, CLIENT_IP, SERVER_IP, SERVER_PEER_IP,
EXTERNAL_IP, EIF_CLIENT_PORT, EIF_A_PORT, EIF_B_PORT, TIMEOUT.

Finding the port (einat allocates it on the first outbound packet):
  bpftool map dump name map_binding
  # key.from_addr/from_port = internal tuple, key.l4proto = 17, flags bit 0
  # value.to_addr/to_port   = external tuple
  logread | grep dpd-einat-sync   # confirms the mirror is alive, not ports

If the tuple differs from the supplied --mapped-port/--external-ip, step 3
prints the tuple it observed and exits 1; re-run with those values.
EOF
}

die() {
	echo "full-cone.sh: $*" >&2
	exit 2
}

have() {
	command -v "$1" >/dev/null 2>&1
}

step() {
	printf '[%s] %s\n' "$1" "$2"
}

needs_port() {
	cat >&2 <<EOF
full-cone.sh: needs --mapped-port PORT

einat allocates the external port. This script will not guess it.

Find the ORIG binding for the internal tuple $CLIENT_IP:$EIF_CLIENT_PORT
(proto 17 = UDP) and read value.to_port / value.to_addr:

  bpftool map dump name map_binding

The dpd-einat-sync log (logread | grep dpd-einat-sync) shows that bindings
are being mirrored, but not their individual ports.

Alternatively, run once and read step 3: it prints the external tuple peer A
actually saw, then re-run with --mapped-port PORT --external-ip ADDR.

There is no default port: without it the printed commands would be wrong, so
even --dry-run refuses to run without --mapped-port.
EOF
	exit 2
}

# show_py prints one runnable command with its code as a quoted heredoc.
#   show_py NS CODE SUFFIX ARG...
# SUFFIX is appended after <<'PY' (for example " >/tmp/x.log 2>&1 &").
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

# One-shot listener for peer A. It exits after the first datagram so the
# caller can tell "probe arrived" from "still waiting".
PY_LISTEN='
import socket, sys
port = int(sys.argv[1])
timeout = float(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", port))
s.settimeout(timeout)
try:
	data, addr = s.recvfrom(2048)
except OSError:
	print("timeout")
	sys.exit(1)
print("rx", addr[0], addr[1], data.decode("latin1"))
'

# The client binds the same port that is expected to have the mapping, sends
# the probe that creates it, then blocks waiting for peer B. Receiving from
# A would also count here, but A only listens; the first inbound datagram is
# therefore B's and EIF is exactly what made it arrive.
PY_CLIENT='
import socket, sys
port = int(sys.argv[1])
peer = sys.argv[2]
pport = int(sys.argv[3])
timeout = float(sys.argv[4])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", port))
s.sendto(b"dpd-eif-probe", (peer, pport))
s.settimeout(timeout)
try:
	data, addr = s.recvfrom(2048)
except OSError:
	print("timeout")
	sys.exit(1)
print("rx", addr[0], addr[1], data.decode("latin1"))
s.sendto(data, addr)
'

# Peer B: different source address and port from peer A. Binding the source
# makes the peer identity unambiguous even when the host has several addresses.
PY_SEND='
import socket, sys
src = sys.argv[1]
port = int(sys.argv[2])
dst = sys.argv[3]
dport = int(sys.argv[4])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((src, port))
s.sendto(b"dpd-eif-from-b", (dst, dport))
s.settimeout(3.0)
try:
	data, addr = s.recvfrom(2048)
	print("echo", data.decode("latin1"))
except OSError:
	print("echo-timeout")
'

while [ $# -gt 0 ]; do
	case "$1" in
	--mapped-port)
		[ $# -ge 2 ] || die "--mapped-port wants a value"
		MAPPED_PORT=$2
		shift 2
		;;
	--external-ip)
		[ $# -ge 2 ] || die "--external-ip wants a value"
		EXTERNAL_IP=$2
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

[ -n "$MAPPED_PORT" ] || needs_port
case "$MAPPED_PORT" in
'' | *[!0-9]*)
	die "--mapped-port must be an integer"
	;;
esac
[ "$MAPPED_PORT" -ge 1 ] && [ "$MAPPED_PORT" -le 65535 ] ||
	die "--mapped-port must be 1..65535"
for p in "$EIF_CLIENT_PORT" "$EIF_A_PORT" "$EIF_B_PORT"; do
	case "$p" in '' | *[!0-9]*) die "ports must be integers" ;; esac
	[ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "ports must be 1..65535"
done
case "$TIMEOUT" in '' | *[!0-9]*) die "TIMEOUT must be an integer" ;; esac
[ "$TIMEOUT" -gt 0 ] || die "TIMEOUT must be > 0"
[ -n "$EXTERNAL_IP" ] || die "--external-ip must not be empty"

cleanup() {
	for p in $PIDS; do
		kill "$p" 2>/dev/null || true
	done
	for p in $PIDS; do
		wait "$p" 2>/dev/null || true
	done
	rm -rf "$WORK"
}
trap 'cleanup' 0 1 2 15

if [ "$DRY_RUN" = 1 ]; then
	echo "full-cone.sh: DRY RUN, no packets will be sent"
	step 1/5 "peer A listens on $SERVER_IP:$EIF_A_PORT (namespace $SERVER_NS)"
	show_py "$SERVER_NS" "$PY_LISTEN" " &" "$EIF_A_PORT" "$TIMEOUT"
	step 2/5 "client $CLIENT_IP:$EIF_CLIENT_PORT probes $SERVER_IP:$EIF_A_PORT, then waits"
	show_py "$CLIENT_NS" "$PY_CLIENT" " &" \
		"$EIF_CLIENT_PORT" "$SERVER_IP" "$EIF_A_PORT" "$((TIMEOUT + 4))"
	step 3/5 "verify peer A saw source $EXTERNAL_IP:$MAPPED_PORT (the mapping)"
	echo "  # peer A should print: rx $EXTERNAL_IP $MAPPED_PORT dpd-eif-probe"
	step 4/5 "peer B $SERVER_PEER_IP:$EIF_B_PORT sends to $EXTERNAL_IP:$MAPPED_PORT"
	show_py "$SERVER_NS" "$PY_SEND" "" \
		"$SERVER_PEER_IP" "$EIF_B_PORT" "$EXTERNAL_IP" "$MAPPED_PORT"
	step 5/5 "client must receive dpd-eif-from-b from $SERVER_PEER_IP"
	echo "  # client should print: rx $SERVER_PEER_IP $EIF_B_PORT dpd-eif-from-b"
	echo "full-cone: DRY-RUN (no packets sent)"
	exit 0
fi

have ip || die "ip not found"
ip netns exec "$CLIENT_NS" true 2>/dev/null ||
	die "namespace $CLIENT_NS missing; run tests/netns/setup.sh first"
ip netns exec "$SERVER_NS" true 2>/dev/null ||
	die "namespace $SERVER_NS missing; run tests/netns/setup.sh first"
if ! have python3; then
	echo "full-cone.sh: python3 is required for the inline UDP sender/receiver" >&2
	echo "  busybox nc -u is not assumed to exist on the target. Install python3," >&2
	echo "  or use --dry-run to print the equivalent commands and run them by hand." >&2
	exit 2
fi

mkdir -p "$WORK" || die "cannot create $WORK"

step 1/5 "peer A listens on $SERVER_IP:$EIF_A_PORT (namespace $SERVER_NS)"
printf '%s\n' "$PY_LISTEN" |
	ip netns exec "$SERVER_NS" python3 - "$EIF_A_PORT" "$TIMEOUT" \
		>"$WORK/peer-a.log" 2>&1 &
APID=$!
PIDS="$PIDS $APID"
sleep 1

step 2/5 "client $CLIENT_IP:$EIF_CLIENT_PORT probes $SERVER_IP:$EIF_A_PORT, then waits"
printf '%s\n' "$PY_CLIENT" |
	ip netns exec "$CLIENT_NS" python3 - "$EIF_CLIENT_PORT" "$SERVER_IP" \
		"$EIF_A_PORT" "$((TIMEOUT + 4))" >"$WORK/client.log" 2>&1 &
CPID=$!
PIDS="$PIDS $CPID"

# Give the probe time to cross DPD/einat and reach peer A.
sleep 2
wait "$APID" 2>/dev/null || true

a_line=$(awk '/^rx /{print $2 " " $3; exit}' "$WORK/peer-a.log" 2>/dev/null)
if [ -z "$a_line" ]; then
	sed 's/^/  peer-a: /' "$WORK/peer-a.log" >&2 2>/dev/null || true
	echo "full-cone: FAIL (peer A did not receive the probe; no mapping was confirmed)" >&2
	exit 1
fi
set -- $a_line
a_ip=${1:-}
a_port=${2:-}
step 3/5 "peer A saw probe from $a_ip:$a_port"

if [ "$a_ip" != "$EXTERNAL_IP" ] || [ "$a_port" != "$MAPPED_PORT" ]; then
	echo "full-cone: FAIL (mapping is $a_ip:$a_port, not $EXTERNAL_IP:$MAPPED_PORT)" >&2
	echo "full-cone: re-run with --mapped-port $a_port --external-ip $a_ip" >&2
	exit 1
fi

step 4/5 "peer B $SERVER_PEER_IP:$EIF_B_PORT sends to $EXTERNAL_IP:$MAPPED_PORT"
printf '%s\n' "$PY_SEND" |
	ip netns exec "$SERVER_NS" python3 - "$SERVER_PEER_IP" "$EIF_B_PORT" \
		"$EXTERNAL_IP" "$MAPPED_PORT" >"$WORK/peer-b.log" 2>&1
b_rc=$?

wait "$CPID" 2>/dev/null || true

c_line=$(awk '/^rx /{print $2 " " $3 " " $4; exit}' "$WORK/client.log" 2>/dev/null)
set -- $c_line
c_ip=${1:-}
c_port=${2:-}
c_data=${3:-}
if [ -n "$c_ip" ]; then
	step 5/5 "client received '$c_data' from $c_ip:$c_port"
else
	step 5/5 "client received nothing"
fi

if [ "$c_ip" = "$SERVER_PEER_IP" ] && [ "$c_data" = "dpd-eif-from-b" ]; then
	echo "full-cone: PASS (EIF: $SERVER_PEER_IP:$EIF_B_PORT -> $EXTERNAL_IP:$MAPPED_PORT reached $CLIENT_IP:$EIF_CLIENT_PORT)"
	exit 0
fi

echo "full-cone: FAIL (peer B datagram was not delivered; see $WORK/client.log)" >&2
if [ "$b_rc" != 0 ]; then
	echo "full-cone: peer B also failed (rc=$b_rc); see $WORK/peer-b.log" >&2
fi
echo "full-cone: check that einat full-cone is enabled and the binding is still current" >&2
sed 's/^/  client: /' "$WORK/client.log" >&2 2>/dev/null || true
exit 1
