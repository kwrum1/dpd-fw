#!/bin/sh
# Run one DPD netns scenario and print one CSV row.
#
#   tests/netns/run.sh ping
#   tests/netns/run.sh --size 64 --flows 10 --seconds 10 udp
#   tests/netns/run.sh --size 1500 --seconds 30 tcp-download
#   tests/netns/run.sh full-cone
#   tests/netns/run.sh --force nat-recreate
#
# CSV (one header row unless --no-header):
#   scenario,size,flows,mbps,pps,cpu_pct,retrans,ts
#
# `size` is the ICMP payload / UDP datagram size, and for TCP it is passed to
# iperf3 as -l (the shell engine uses it as the dd block size). TCP packet
# boundaries are still MSS/MTU driven; use iperf3 for precise frame-size work.
#
# Engines:
#   auto    iperf3 when present, otherwise busybox nc/dd/timeout
#   shell   nc + dd + timeout only (functional, not line-rate)
#   iperf3  requires iperf3 on both sides (same namespace host)
#
# full-cone and nat-recreate are gates, not throughput numbers:
#   full-cone     mbps=1.000 means the second peer got through, 0.000 means it
#                 did not (einat full-cone inactive or the packet was dropped)
#   nat-recreate  sends two small UDP datagrams across a dpdctl epoch bump (or a
#                 conntrack delete with --force); mbps/pps describe that flow
#
# Exit status is 0 unless --strict is given and the scenario gate failed.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

CLIENT_NS=${CLIENT_NS:-dpd-ns-client}
SERVER_NS=${SERVER_NS:-dpd-ns-server}
CLIENT_IP=${CLIENT_IP:-192.168.10.200}
SERVER_IP=${SERVER_IP:-203.0.113.2}
SERVER_PEER_IP=${SERVER_PEER_IP:-203.0.113.3}
PORT_BASE=${PORT_BASE:-5301}
FC_SRC_PORT=${FC_SRC_PORT:-40000}
FC_A_PORT=${FC_A_PORT:-9000}
FC_B_PORT=${FC_B_PORT:-9001}
NR_PORT=${NR_PORT:-9100}
NR_SRC_PORT=${NR_SRC_PORT:-41000}

SIZE=1500
DURATION=10
FLOWS=1
ENGINE=auto
HEADER=1
STRICT=0
FORCE=0
SCENARIO=

WORK=/tmp/dpd-netns-run.$$
PIDS=
FAIL=0

usage() {
	cat <<'EOF'
usage: run.sh [options] <scenario>

scenarios:
  ping            ICMP echo, size = payload
  tcp-download    server -> client (iperf3 -R when available)
  tcp-upload      client -> server
  udp             client -> server datagrams
  full-cone       second peer test (two server addresses; gate)
  nat-recreate    UDP across a flow-cache epoch bump (gate)

options:
  --size N        payload / datagram / block size (default 1500)
  --seconds N     test duration (default 10)
  --flows N       parallel flows (default 1)
  --engine E      auto | shell | iperf3 (default auto)
  --port N        base port (default 5301)
  --no-header     do not print the CSV header
  --strict        exit 1 when the scenario gate failed
  --force         nat-recreate: allow a scoped conntrack delete
  -h, --help      this text

Environment: CLIENT_NS, SERVER_NS, CLIENT_IP, SERVER_IP, SERVER_PEER_IP
(see tests/netns/setup.sh for the addresses).
EOF
}

die() {
	echo "run.sh: $*" >&2
	exit 2
}

have() {
	command -v "$1" >/dev/null 2>&1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--size)
		[ $# -ge 2 ] || die "--size wants a value"
		SIZE=$2
		shift 2
		;;
	--seconds)
		[ $# -ge 2 ] || die "--seconds wants a value"
		DURATION=$2
		shift 2
		;;
	--flows)
		[ $# -ge 2 ] || die "--flows wants a value"
		FLOWS=$2
		shift 2
		;;
	--engine)
		[ $# -ge 2 ] || die "--engine wants a value"
		ENGINE=$2
		shift 2
		;;
	--port)
		[ $# -ge 2 ] || die "--port wants a value"
		PORT_BASE=$2
		shift 2
		;;
	--no-header)
		HEADER=0
		shift
		;;
	--strict)
		STRICT=1
		shift
		;;
	--force)
		FORCE=1
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
		[ -z "$SCENARIO" ] || die "only one scenario per run"
		SCENARIO=$1
		shift
		;;
	esac
done

case "$SCENARIO" in
ping | tcp-download | tcp-upload | udp | full-cone | nat-recreate) ;;
'') usage >&2; exit 2 ;;
*) die "unknown scenario '$SCENARIO'" ;;
esac
case "$SIZE" in '' | *[!0-9]*) die "--size must be a positive integer" ;; esac
case "$DURATION" in '' | *[!0-9]*) die "--seconds must be a positive integer" ;; esac
case "$FLOWS" in '' | *[!0-9]*) die "--flows must be a positive integer" ;; esac
case "$PORT_BASE" in '' | *[!0-9]*) die "--port must be a positive integer" ;; esac
[ "$SIZE" -gt 0 ] || die "--size must be > 0"
[ "$DURATION" -gt 0 ] || die "--seconds must be > 0"
[ "$FLOWS" -gt 0 ] || die "--flows must be > 0"

case "$ENGINE" in auto | shell | iperf3) ;; *) die "bad --engine '$ENGINE'" ;; esac

have ip || die "ip not found"
ip netns exec "$CLIENT_NS" true 2>/dev/null ||
	die "namespace $CLIENT_NS missing; run tests/netns/setup.sh first"
ip netns exec "$SERVER_NS" true 2>/dev/null ||
	die "namespace $SERVER_NS missing; run tests/netns/setup.sh first"

case "$SCENARIO" in
tcp-download | tcp-upload | udp)
	if [ "$ENGINE" = auto ]; then
		if have iperf3; then ENGINE=iperf3; else ENGINE=shell; fi
	fi
	if [ "$ENGINE" = iperf3 ]; then
		have iperf3 || die "iperf3 not found"
	else
		have nc || die "nc not found"
		have timeout || die "timeout not found (busybox)"
		[ "$FLOWS" -gt 50 ] &&
			echo "run.sh: shell engine with $FLOWS flows is process-heavy; install iperf3" >&2
	fi
	;;
*)
	have nc || die "nc not found"
	have timeout || die "timeout not found (busybox)"
	;;
esac

mkdir -p "$WORK" || die "cannot create $WORK"

cleanup() {
	for p in $PIDS; do
		kill "$p" 2>/dev/null || true
	done
	rm -rf "$WORK"
}
trap 'cleanup' 0 1 2 15

now_ns() {
	if date +%N >/dev/null 2>&1; then
		n=$(date +%s%N 2>/dev/null || true)
		case "$n" in
		'' | *[!0-9]*) ;;
		*)
			printf '%s' "$n"
			return 0
			;;
		esac
	fi
	printf '%s000000000' "$(date +%s)"
}

now_ts() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s
}

elapsed_s() {
	awk -v a="$1" -v b="$2" 'BEGIN{d=(b-a)/1000000000; if(d<=0)d=0.001; printf "%.3f", d}'
}

cpu_read() {
	awk '/^cpu /{t=0; for(i=2;i<=NF;i++)t+=$i; print t " " ($5+$6); exit}' /proc/stat
}

cpu_pct() {
	awk -v a="$1" -v b="$2" 'BEGIN{
		split(a,x," "); split(b,y," ");
		dt=y[1]-x[1]; di=y[2]-x[2];
		if (dt<=0) print "0.0"; else printf "%.1f", 100*(dt-di)/dt
	}'
}

retrans_in() {
	v=$(ip netns exec "$1" awk '/^Tcp:/{print $13; exit}' /proc/net/snmp 2>/dev/null || true)
	case "$v" in '' | *[!0-9]*) v=0 ;; esac
	printf '%s' "$v"
}

retrans_delta() {
	awk -v a="$1" -v b="$2" 'BEGIN{d=b-a; if(d<0)d=0; printf "%d", d}'
}

fmt3() {
	awk -v v="$1" 'BEGIN{printf "%.3f", v+0}'
}

fmt1() {
	awk -v v="$1" 'BEGIN{printf "%.1f", v+0}'
}

mbps_of() { # bytes, seconds
	awk -v b="$1" -v s="$2" 'BEGIN{printf "%.3f", (s>0)?(b*8/s/1e6):0}'
}

pps_of() { # bytes, seconds, packet size
	awk -v b="$1" -v s="$2" -v z="$3" 'BEGIN{printf "%.1f", (s>0 && z>0)?(b/z/s):0}'
}

pps_from_mbps() { # mbps, packet size
	awk -v m="$1" -v z="$2" 'BEGIN{printf "%.1f", (z>0)?(m*125000/z):0}'
}

sum_bytes() {
	total=0
	for f in "$@"; do
		[ -f "$f" ] || continue
		v=$(cat "$f" 2>/dev/null || echo 0)
		case "$v" in '' | *[!0-9]*) v=0 ;; esac
		total=$((total + v))
	done
	printf '%s' "$total"
}

wait_pids() {
	for p in $1; do
		wait "$p" 2>/dev/null || true
	done
}

kill_pids() {
	for p in $1; do
		kill "$p" 2>/dev/null || true
	done
}

emit_row() { # mbps pps cpu retrans
	printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$SCENARIO" "$SIZE" "$FLOWS" "$1" "$2" "$3" "$4" "$(now_ts)"
}

[ "$HEADER" = 1 ] && printf 'scenario,size,flows,mbps,pps,cpu_pct,retrans,ts\n'

# --------------------------------------------------------------------- ping
do_ping() {
	# busybox ping wants an integer interval; one probe per second keeps the
	# scenario portable and the duration honest.
	count=$DURATION
	[ "$count" -lt 1 ] && count=1

	cpu0=$(cpu_read)
	t0=$(now_ns)
	out=$(ip netns exec "$CLIENT_NS" ping -c "$count" -s "$SIZE" -i 1 -W 2 "$SERVER_IP" 2>&1 || true)
	t1=$(now_ns)
	cpu1=$(cpu_read)

	counts=$(printf '%s\n' "$out" | awk '
		/packets transmitted/ {
			for (i = 1; i <= NF; i++) {
				if ($i == "transmitted," || $i == "transmitted")
					tx = $(i-1)
				if ($i == "received," || $i == "received")
					rx = $(i-1)
			}
			print (tx+0) " " (rx+0)
			exit
		}')
	tx=${counts%% *}
	rx=${counts##* }
	case "$tx" in '' | *[!0-9]*) tx=0 ;; esac
	case "$rx" in '' | *[!0-9]*) rx=0 ;; esac

	sec=$(elapsed_s "$t0" "$t1")
	mbps=$(mbps_of "$((rx * SIZE))" "$sec")
	pps=$(awk -v n="$rx" -v s="$sec" 'BEGIN{printf "%.1f", (s>0)?(n/s):0}')
	cpu=$(cpu_pct "$cpu0" "$cpu1")

	if [ "$tx" -gt "$rx" ]; then
		echo "run.sh: ping loss $((tx - rx))/$tx" >&2
	fi
	if [ "$rx" = 0 ]; then
		echo "run.sh: ping gate failed (no replies)" >&2
		FAIL=1
	fi
	emit_row "$mbps" "$pps" "$cpu" 0
}

# ------------------------------------------------------ shell TCP/UDP engine
do_shell_tcp() {
	direction=$1
	spids=
	cpids=
	i=0

	if [ "$direction" = download ]; then
		while [ "$i" -lt "$FLOWS" ]; do
			port=$((PORT_BASE + i))
			ip netns exec "$SERVER_NS" sh -c \
				"timeout $((DURATION + 4)) dd if=/dev/zero bs=$SIZE 2>/dev/null | nc -l -p $port >/dev/null" &
			spids="$spids $!"
			PIDS="$PIDS $!"
			i=$((i + 1))
		done
		sleep 1

		cpu0=$(cpu_read)
		r0=$(retrans_in "$SERVER_NS")
		t0=$(now_ns)
		i=0
		while [ "$i" -lt "$FLOWS" ]; do
			port=$((PORT_BASE + i))
			ip netns exec "$CLIENT_NS" sh -c \
				"timeout $DURATION nc $SERVER_IP $port | wc -c > $WORK/dl.$i" &
			cpids="$cpids $!"
			PIDS="$PIDS $!"
			i=$((i + 1))
		done
		wait_pids "$cpids"
		t1=$(now_ns)
		r1=$(retrans_in "$SERVER_NS")
		cpu1=$(cpu_read)
		kill_pids "$spids"
		wait_pids "$spids"
		bytes=$(sum_bytes "$WORK"/dl.*)
	else
		while [ "$i" -lt "$FLOWS" ]; do
			port=$((PORT_BASE + i))
			ip netns exec "$SERVER_NS" sh -c \
				"timeout $((DURATION + 4)) nc -l -p $port | wc -c > $WORK/ul.$i" &
			spids="$spids $!"
			PIDS="$PIDS $!"
			i=$((i + 1))
		done
		sleep 1

		cpu0=$(cpu_read)
		r0=$(retrans_in "$CLIENT_NS")
		t0=$(now_ns)
		i=0
		while [ "$i" -lt "$FLOWS" ]; do
			port=$((PORT_BASE + i))
			ip netns exec "$CLIENT_NS" sh -c \
				"timeout $DURATION dd if=/dev/zero bs=$SIZE 2>/dev/null | nc $SERVER_IP $port" &
			cpids="$cpids $!"
			PIDS="$PIDS $!"
			i=$((i + 1))
		done
		wait_pids "$cpids"
		wait_pids "$spids"
		t1=$(now_ns)
		r1=$(retrans_in "$CLIENT_NS")
		cpu1=$(cpu_read)
		bytes=$(sum_bytes "$WORK"/ul.*)
	fi

	sec=$(elapsed_s "$t0" "$t1")
	mbps=$(mbps_of "$bytes" "$sec")
	pps=$(pps_of "$bytes" "$sec" "$SIZE")
	cpu=$(cpu_pct "$cpu0" "$cpu1")
	retr=$(retrans_delta "$r0" "$r1")
	if [ "$bytes" = 0 ]; then
		echo "run.sh: $SCENARIO transferred 0 bytes (gate failed)" >&2
		FAIL=1
	fi
	emit_row "$mbps" "$pps" "$cpu" "$retr"
}

do_shell_udp() {
	spids=
	cpids=
	i=0
	while [ "$i" -lt "$FLOWS" ]; do
		port=$((PORT_BASE + i))
		ip netns exec "$SERVER_NS" sh -c \
			"timeout $((DURATION + 3)) nc -u -l -p $port | wc -c > $WORK/udp.$i" &
		spids="$spids $!"
		PIDS="$PIDS $!"
		i=$((i + 1))
	done
	sleep 1

	cpu0=$(cpu_read)
	t0=$(now_ns)
	i=0
	while [ "$i" -lt "$FLOWS" ]; do
		port=$((PORT_BASE + i))
		# One read = one datagram. A shell loop is deliberately simple; use
		# iperf3 when pps matters.
		ip netns exec "$CLIENT_NS" sh -c \
			"timeout $DURATION sh -c 'while :; do dd if=/dev/zero bs=$SIZE count=1 2>/dev/null; done' | nc -u $SERVER_IP $port" &
		cpids="$cpids $!"
		PIDS="$PIDS $!"
		i=$((i + 1))
	done
	wait_pids "$cpids"
	t1=$(now_ns)
	cpu1=$(cpu_read)
	# UDP has no FIN, so the receivers end on their own timeout. Their wc
	# output is only complete after that.
	wait_pids "$spids"

	bytes=$(sum_bytes "$WORK"/udp.*)
	sec=$(elapsed_s "$t0" "$t1")
	mbps=$(mbps_of "$bytes" "$sec")
	pps=$(pps_of "$bytes" "$sec" "$SIZE")
	cpu=$(cpu_pct "$cpu0" "$cpu1")
	if [ "$bytes" = 0 ]; then
		echo "run.sh: udp transferred 0 bytes (gate failed)" >&2
		FAIL=1
	fi
	emit_row "$mbps" "$pps" "$cpu" 0
}

# -------------------------------------------------------------- iperf3 engine
do_iperf3() {
	port=$PORT_BASE
	extra=
	case "$SCENARIO" in
	tcp-download) extra="-R" ;;
	tcp-upload) extra= ;;
	udp) extra="-u -b 0" ;;
	esac
	[ "$SIZE" -gt 0 ] && extra="$extra -l $SIZE"

	ip netns exec "$SERVER_NS" iperf3 -s -1 -p "$port" >"$WORK/iperf-server.log" 2>&1 &
	spid=$!
	PIDS="$PIDS $spid"
	sleep 1

	rns=$CLIENT_NS
	[ "$SCENARIO" = tcp-download ] && rns=$SERVER_NS
	cpu0=$(cpu_read)
	r0=$(retrans_in "$rns")
	t0=$(now_ns)
	# shellcheck disable=SC2086
	ip netns exec "$CLIENT_NS" iperf3 -c "$SERVER_IP" -p "$port" \
		-t "$DURATION" -P "$FLOWS" $extra -f m >"$WORK/iperf.log" 2>&1
	rc=$?
	t1=$(now_ns)
	r1=$(retrans_in "$rns")
	cpu1=$(cpu_read)
	kill "$spid" 2>/dev/null || true
	wait "$spid" 2>/dev/null || true

	mbps=$(awk '/Mbits\/sec/ {
			for (i = 1; i <= NF; i++)
				if ($i == "Mbits/sec")
					v = $(i-1)
		} END{printf "%.3f", v+0}' "$WORK/iperf.log")
	retr=$(awk '/Mbits\/sec/ {
			for (i = 1; i <= NF; i++)
				if ($i == "Mbits/sec" && $(i+1) ~ /^[0-9]+$/)
					v = $(i+1)
		} END{printf "%d", v+0}' "$WORK/iperf.log")
	cpu=$(cpu_pct "$cpu0" "$cpu1")
	pps=$(pps_from_mbps "$mbps" "$SIZE")

	if [ "$SCENARIO" = udp ]; then
		retr=0
	elif [ "$retr" = 0 ]; then
		retr=$(retrans_delta "$r0" "$r1")
	fi
	if [ "$rc" != 0 ] || [ "$mbps" = "0.000" ]; then
		echo "run.sh: iperf3 failed (rc=$rc), see $WORK/iperf.log" >&2
		FAIL=1
	fi
	emit_row "$mbps" "$pps" "$cpu" "$retr"
}

# ---------------------------------------------------------------- full-cone
do_full_cone() {
	ct=/proc/net/nf_conntrack
	[ -r "$ct" ] || ct=/proc/net/ip_conntrack
	if [ ! -r "$ct" ]; then
		echo "run.sh: no conntrack table; cannot locate the NAT mapping" >&2
		emit_row "0.000" "0.0" "0.0" 0
		FAIL=1
		return
	fi

	# Peer A listens so the first datagram creates a real conntrack entry
	# instead of eliciting ICMP port-unreachable.
	ip netns exec "$SERVER_NS" sh -c \
		"timeout 3 nc -u -l -p $FC_A_PORT >/dev/null" &
	apid=$!
	PIDS="$PIDS $apid"
	sleep 1

	# Create a binding with peer A (.2:9000) and learn the external port from
	# the reply tuple of our own conntrack entry.
	ip netns exec "$CLIENT_NS" sh -c \
		"printf 'dpd-cone' | nc -u -p $FC_SRC_PORT $SERVER_IP $FC_A_PORT" \
		>/dev/null 2>&1 || true
	# Give the one-shot sender time to close before the listener rebinds the
	# same source port.
	sleep 2
	wait "$apid" 2>/dev/null || true

	map=$(awk -v cip="$CLIENT_IP" -v sp="$FC_SRC_PORT" -v dp="$FC_A_PORT" '
		{
			if ($3 != "udp")
				next
			hit = 0; sport_ok = 0; dport_ok = 0
			for (i = 1; i <= NF; i++) {
				if ($i == "src=" cip) hit = 1
				if ($i == "sport=" sp) sport_ok = 1
				if ($i == "dport=" dp) dport_ok = 1
			}
			if (!hit || !sport_ok || !dport_ok)
				next
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^dst=/) {
					v = $i; sub("dst=", "", v); wan = v
				}
				if ($i ~ /^dport=/) {
					v = $i; sub("dport=", "", v); mp = v
				}
			}
		}
		END { if (mp != "") print wan " " mp }' "$ct" 2>/dev/null)
	wan=${map%% *}
	mapped=${map##* }
	if [ -z "$map" ] || [ -z "$wan" ] || [ -z "$mapped" ]; then
		echo "run.sh: no NAT mapping for $CLIENT_IP:$FC_SRC_PORT (is masquerade on?)" >&2
		emit_row "0.000" "0.0" "0.0" 0
		FAIL=1
		return
	fi
	case "$wan" in *[!0-9.]*)
		echo "run.sh: odd external address '$wan'" >&2
		emit_row "0.000" "0.0" "0.0" 0
		FAIL=1
		return
		;;
	esac

	rm -f "$WORK/fc.recv"
	ip netns exec "$CLIENT_NS" sh -c \
		"timeout 4 nc -u -l -p $FC_SRC_PORT > $WORK/fc.recv" &
	lpid=$!
	PIDS="$PIDS $lpid"
	sleep 1

	cpu0=$(cpu_read)
	# Peer B is a different source IP and port. A restricted-cone mapping
	# drops this; a full-cone mapping delivers it to the client socket.
	# Prefer a /32 route with a source hint, which works on busybox nc builds
	# without -s; fall back to -s when the route cannot be installed.
	if ip netns exec "$SERVER_NS" ip route replace "$wan/32" dev eth0 \
		src "$SERVER_PEER_IP" 2>/dev/null; then
		ip netns exec "$SERVER_NS" sh -c \
			"printf 'peer-b' | nc -u -p $FC_B_PORT -w 1 $wan $mapped" \
			>/dev/null 2>&1 || true
		ip netns exec "$SERVER_NS" ip route del "$wan/32" 2>/dev/null || true
	else
		ip netns exec "$SERVER_NS" sh -c \
			"printf 'peer-b' | nc -u -s $SERVER_PEER_IP -p $FC_B_PORT -w 1 $wan $mapped" \
			>/dev/null 2>&1 || true
	fi

	wait "$lpid" 2>/dev/null || true
	t1=$(now_ns)
	cpu1=$(cpu_read)
	got=$(wc -c <"$WORK/fc.recv" 2>/dev/null || echo 0)
	cpu=$(cpu_pct "$cpu0" "$cpu1")

	if [ "$got" -gt 0 ] 2>/dev/null; then
		echo "run.sh: full-cone PASS (peer $SERVER_PEER_IP:$FC_B_PORT -> $wan:$mapped)" >&2
		emit_row "1.000" "1.0" "$cpu" 0
	else
		echo "run.sh: full-cone FAIL (peer B packet was not delivered)" >&2
		emit_row "0.000" "0.0" "$cpu" 0
		FAIL=1
	fi
}

# -------------------------------------------------------------- nat-recreate
do_nat_recreate() {
	rm -f "$WORK/nr.recv"
	ip netns exec "$SERVER_NS" sh -c \
		"timeout 5 nc -u -l -p $NR_PORT > $WORK/nr.recv" &
	lpid=$!
	PIDS="$PIDS $lpid"
	sleep 1

	cpu0=$(cpu_read)
	t0=$(now_ns)
	ip netns exec "$CLIENT_NS" sh -c \
		"printf 'one' | nc -u -p $NR_SRC_PORT $SERVER_IP $NR_PORT" \
		>/dev/null 2>&1 || true
	sleep 1

	bumped=0
	if [ -x /usr/sbin/dpdctl ] && /usr/sbin/dpdctl bump >/dev/null 2>&1; then
		bumped=1
	elif [ "$FORCE" = 1 ] && have conntrack; then
		if conntrack -D -p udp --orig-src "$CLIENT_IP" --orig-dst "$SERVER_IP" \
			--orig-port-src "$NR_SRC_PORT" --orig-port-dst "$NR_PORT" >/dev/null 2>&1; then
			bumped=1
		fi
	else
		echo "run.sh: no dpdctl bump (and no --force conntrack delete); cannot invalidate the flow" >&2
	fi

	sleep 1
	ip netns exec "$CLIENT_NS" sh -c \
		"printf 'two' | nc -u -p $NR_SRC_PORT $SERVER_IP $NR_PORT" \
		>/dev/null 2>&1 || true
	wait "$lpid" 2>/dev/null || true
	t1=$(now_ns)
	cpu1=$(cpu_read)

	got=$(wc -c <"$WORK/nr.recv" 2>/dev/null || echo 0)
	sec=$(elapsed_s "$t0" "$t1")
	mbps=$(mbps_of "$got" "$sec")
	pps=$(awk -v s="$sec" 'BEGIN{printf "%.1f", (s>0)?(2/s):0}')
	cpu=$(cpu_pct "$cpu0" "$cpu1")

	if [ "$bumped" = 1 ] && [ "$got" -ge 6 ] 2>/dev/null; then
		echo "run.sh: nat-recreate PASS ($got bytes after epoch bump)" >&2
	else
		echo "run.sh: nat-recreate FAIL (bumped=$bumped bytes=$got)" >&2
		FAIL=1
	fi
	emit_row "$mbps" "$pps" "$cpu" 0
}

case "$SCENARIO" in
ping) do_ping ;;
tcp-download) if [ "$ENGINE" = iperf3 ]; then do_iperf3; else do_shell_tcp download; fi ;;
tcp-upload) if [ "$ENGINE" = iperf3 ]; then do_iperf3; else do_shell_tcp upload; fi ;;
udp) if [ "$ENGINE" = iperf3 ]; then do_iperf3; else do_shell_udp; fi ;;
full-cone) do_full_cone ;;
nat-recreate) do_nat_recreate ;;
esac

if [ "$STRICT" = 1 ] && [ "$FAIL" = 1 ]; then
	exit 1
fi
exit 0
