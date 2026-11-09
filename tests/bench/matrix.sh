#!/bin/sh
# Drive the packet-size / flow-count matrix and write results.csv.
#
#   sh tests/bench/matrix.sh
#   sh tests/bench/matrix.sh --sizes "64 128 512 1500 9000" \
#                            --flows "1 10 100 1000" --seconds 10
#   sh tests/bench/matrix.sh --scenarios "tcp-download tcp-upload udp" --engine iperf3
#   sh tests/bench/matrix.sh --server 192.168.10.162 --out dpd.csv
#   sh tests/bench/matrix.sh --quick
#
# Default mode uses tests/netns/run.sh (run tests/netns/setup.sh first) so the
# traffic crosses the DPD hook. --server switches to a plain iperf3 client
# against an already-running iperf3 server on that address, for comparing two
# routers or a router against a host without namespaces.
#
# Output columns:
#   scenario,size,flows,mbps,pps,cpu_pct,retrans,ts
#
# Failures still produce a row (zeros) so a matrix run never leaves holes; the
# reason is appended to results.log.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

SIZES="64 128 512 1500 9000"
FLOWS="1 10 100 1000"
SCENARIOS="tcp-download tcp-upload udp"
DURATION=10
OUT=results.csv
ENGINE=auto
SERVER=
PORT=5201
CHECK_SETUP=1

SELF_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
ROOT=$(CDPATH= cd "$SELF_DIR/../.." && pwd) || exit 1
RUN=$ROOT/tests/netns/run.sh
LOG=$OUT.log
TMP=/tmp/dpd-bench.$$
mkdir -p "$TMP" || exit 1

usage() {
	cat <<'EOF'
usage: matrix.sh [options]

  --sizes "LIST"       packet/payload sizes (default "64 128 512 1500 9000")
  --flows "LIST"       flow counts (default "1 10 100 1000")
  --scenarios "LIST"   scenarios (default "tcp-download tcp-upload udp")
  --seconds N          duration per cell (default 10)
  --out FILE           CSV path (default results.csv)
  --engine E           auto | shell | iperf3 (forwarded to run.sh)
  --server HOST        use a plain iperf3 client against HOST instead of netns
  --port N             iperf3 port for --server mode (default 5201)
  --quick              sizes "64 1500", flows "1 10", 3 seconds
  --no-setup-check     do not verify that the netns pair exists
  -h, --help           this text
EOF
}

die() {
	echo "matrix.sh: $*" >&2
	exit 2
}

norm_list() {
	printf '%s' "$1" | tr ',' ' '
}

while [ $# -gt 0 ]; do
	case "$1" in
	--sizes)
		[ $# -ge 2 ] || die "--sizes wants a value"
		SIZES=$(norm_list "$2")
		shift 2
		;;
	--flows)
		[ $# -ge 2 ] || die "--flows wants a value"
		FLOWS=$(norm_list "$2")
		shift 2
		;;
	--scenarios)
		[ $# -ge 2 ] || die "--scenarios wants a value"
		SCENARIOS=$(norm_list "$2")
		shift 2
		;;
	--seconds)
		[ $# -ge 2 ] || die "--seconds wants a value"
		DURATION=$2
		shift 2
		;;
	--out)
		[ $# -ge 2 ] || die "--out wants a value"
		OUT=$2
		LOG=$OUT.log
		shift 2
		;;
	--engine)
		[ $# -ge 2 ] || die "--engine wants a value"
		ENGINE=$2
		shift 2
		;;
	--server)
		[ $# -ge 2 ] || die "--server wants a value"
		SERVER=$2
		shift 2
		;;
	--port)
		[ $# -ge 2 ] || die "--port wants a value"
		PORT=$2
		shift 2
		;;
	--quick)
		SIZES="64 1500"
		FLOWS="1 10"
		DURATION=3
		shift
		;;
	--no-setup-check)
		CHECK_SETUP=0
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
		die "unexpected argument '$1'"
		;;
	esac
done

case "$DURATION" in '' | *[!0-9]*) die "--seconds must be a positive integer" ;; esac
[ "$DURATION" -gt 0 ] || die "--seconds must be > 0"
case "$PORT" in '' | *[!0-9]*) die "--port must be a positive integer" ;; esac
case "$ENGINE" in auto | shell | iperf3) ;; *) die "bad --engine '$ENGINE'" ;; esac
for v in $SIZES; do
	case "$v" in '' | *[!0-9]*) die "bad size '$v'" ;; esac
	[ "$v" -gt 0 ] || die "bad size '$v'"
done
for v in $FLOWS; do
	case "$v" in '' | *[!0-9]*) die "bad flow count '$v'" ;; esac
	[ "$v" -gt 0 ] || die "bad flow count '$v'"
done
for v in $SCENARIOS; do
	case "$v" in
	tcp-download | tcp-upload | udp | ping) ;;
	*) die "scenario '$v' is not supported by the matrix (tcp-download|tcp-upload|udp|ping)" ;;
	esac
done
[ -n "$SIZES" ] || die "empty size list"
[ -n "$FLOWS" ] || die "empty flow list"
[ -n "$SCENARIOS" ] || die "empty scenario list"
[ -n "$OUT" ] || die "empty --out"
case "$OUT" in
*/*) mkdir -p "${OUT%/*}" 2>/dev/null || die "cannot create ${OUT%/*}" ;;
esac

if [ -n "$SERVER" ]; then
	command -v iperf3 >/dev/null 2>&1 || die "--server needs iperf3 on this host"
	[ "$ENGINE" != shell ] || die "--server cannot use --engine shell"
	for v in $SCENARIOS; do
		[ "$v" = ping ] && die "ping is only available in netns mode"
	done
else
	[ -f "$RUN" ] || die "missing $RUN"
	if [ "$CHECK_SETUP" = 1 ]; then
		have_ip=0
		command -v ip >/dev/null 2>&1 && have_ip=1
		if [ "$have_ip" = 1 ]; then
			ip netns exec "${CLIENT_NS:-dpd-ns-client}" true 2>/dev/null ||
				die "netns ${CLIENT_NS:-dpd-ns-client} missing; run tests/netns/setup.sh first"
		else
			die "ip not found; cannot check the netns pair"
		fi
	fi
fi

cleanup() {
	rm -rf "$TMP"
}
trap 'cleanup' 0 1 2 15

now_ts() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s
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

retrans_now() {
	v=$(awk '/^Tcp:/{print $13; exit}' /proc/net/snmp 2>/dev/null || true)
	case "$v" in '' | *[!0-9]*) v=0 ;; esac
	printf '%s' "$v"
}

pps_from_mbps() {
	awk -v m="$1" -v z="$2" 'BEGIN{printf "%.1f", (z>0)?(m*125000/z):0}'
}

emit_zero() {
	printf '%s,%s,%s,0.000,0.000,0.0,0,%s\n' "$1" "$2" "$3" "$(now_ts)"
}

# --------------------------------------------------------------- direct mode
do_direct() {
	scenario=$1
	size=$2
	flows=$3

	extra=
	case "$scenario" in
	tcp-download) extra="-R" ;;
	tcp-upload) extra= ;;
	udp) extra="-u -b 0" ;;
	esac
	[ "$size" -gt 0 ] && extra="$extra -l $size"

	cpu0=$(cpu_read)
	r0=$(retrans_now)
	# shellcheck disable=SC2086
	iperf3 -c "$SERVER" -p "$PORT" -t "$DURATION" -P "$flows" $extra -f m \
		>"$TMP/iperf.log" 2>&1
	rc=$?
	cpu1=$(cpu_read)

	mbps=$(awk '/Mbits\/sec/ {
			for (i = 1; i <= NF; i++)
				if ($i == "Mbits/sec")
					v = $(i-1)
		} END{printf "%.3f", v+0}' "$TMP/iperf.log")
	retr=$(awk '/Mbits\/sec/ {
			for (i = 1; i <= NF; i++)
				if ($i == "Mbits/sec" && $(i+1) ~ /^[0-9]+$/)
					v = $(i+1)
		} END{printf "%d", v+0}' "$TMP/iperf.log")
	cpu=$(cpu_pct "$cpu0" "$cpu1")
	pps=$(pps_from_mbps "$mbps" "$size")

	if [ "$scenario" = udp ]; then
		retr=0
	elif [ "$retr" = 0 ]; then
		r1=$(retrans_now)
		retr=$(awk -v a="$r0" -v b="$r1" 'BEGIN{d=b-a; if(d<0)d=0; printf "%d", d}')
	fi

	if [ "$rc" != 0 ] || [ "$mbps" = "0.000" ]; then
		echo "matrix: $scenario size=$size flows=$flows failed (rc=$rc)" >>"$LOG"
		sed 's/^/    /' "$TMP/iperf.log" >>"$LOG"
		emit_zero "$scenario" "$size" "$flows"
	else
		printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
			"$scenario" "$size" "$flows" "$mbps" "$pps" "$cpu" "$retr" "$(now_ts)"
	fi
}

# ------------------------------------------------------------------ main
printf 'scenario,size,flows,mbps,pps,cpu_pct,retrans,ts\n' >"$OUT" || die "cannot write $OUT"
: >"$LOG" || die "cannot write $LOG"

cells=0
for s in $SCENARIOS; do
	for z in $SIZES; do
		for f in $FLOWS; do cells=$((cells + 1)); done
	done
done
echo "matrix: $cells cells, ${DURATION}s each, out=$OUT" >&2

n=0
for scenario in $SCENARIOS; do
	for size in $SIZES; do
		for flows in $FLOWS; do
			n=$((n + 1))
			echo "matrix: [$n/$cells] $scenario size=$size flows=$flows" >&2
			if [ -n "$SERVER" ]; then
				do_direct "$scenario" "$size" "$flows" >>"$OUT"
			else
				row=$(sh "$RUN" --no-header --size "$size" --flows "$flows" \
					--seconds "$DURATION" --engine "$ENGINE" "$scenario" 2>>"$LOG")
				rc=$?
				row=$(printf '%s' "$row" | tr -d '\r')
				if [ "$rc" != 0 ] || [ -z "$row" ]; then
					echo "matrix: $scenario size=$size flows=$flows failed (rc=$rc)" >>"$LOG"
					emit_zero "$scenario" "$size" "$flows" >>"$OUT"
				else
					printf '%s\n' "$row" >>"$OUT"
				fi
			fi
		done
	done
done

rows=$(($(wc -l <"$OUT") - 1))
echo "matrix: wrote $rows rows to $OUT (log: $LOG)" >&2
exit 0
