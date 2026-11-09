#!/bin/sh
# Sample the counters around a DPD A/B run and print the deltas as JSON.
#
#   sh tests/bench/sample.sh --dev br-lan --dev eth1 --seconds 30
#   sh tests/bench/sample.sh --dev eth1 --seconds 60 --interval 5 --out /tmp/dpd.json
#
# Reads:
#   /proc/net/dev          rx/tx bytes, packets, errors, drops per device
#   dpdctl stats           per-counter totals (git-style text table)
#   /var/run/dpd/napi.json gro_flush_timeout, napi_defer_hard_irqs, genl, devices
#   /proc/interrupts       per-IRQ counts for the devices under test
#
# Only POSIX sh and awk are used. IRQ numbers come from
# `dpd-napi-netdev list`, /sys/class/net/<dev>/device/msi_irqs, and finally
# descriptors containing "<dev>-" in /proc/interrupts.
#
# Output is JSON on stdout (and in --out FILE when given). The raw samples are
# kept in --raw FILE, or next to --out, so a surprising delta can be audited.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

DEVS=
SECONDS_ARG=10
INTERVAL=1
OUT=
RAW=

TMP=/tmp/dpd-sample.$$
mkdir -p "$TMP" || exit 1

usage() {
	cat <<'EOF'
usage: sample.sh [--dev DEV]... [--seconds N] [--interval N]
                 [--out FILE] [--raw FILE]

  --dev DEV       device to report; repeatable. Default: br-lan (if present),
                  the UCI wan device, or every physical NIC.
  --seconds N     measurement window (default 10)
  --interval N    seconds between samples (default 1; clamped to the window)
  --out FILE      write the JSON summary here as well as stdout
  --raw FILE      keep the raw samples here (default: <out>.raw or a tmp file)
  -h, --help      this text
EOF
}

die() {
	echo "sample.sh: $*" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dev)
		[ $# -ge 2 ] || die "--dev wants a value"
		DEVS="$DEVS $2"
		shift 2
		;;
	--seconds)
		[ $# -ge 2 ] || die "--seconds wants a value"
		SECONDS_ARG=$2
		shift 2
		;;
	--interval)
		[ $# -ge 2 ] || die "--interval wants a value"
		INTERVAL=$2
		shift 2
		;;
	--out)
		[ $# -ge 2 ] || die "--out wants a value"
		OUT=$2
		shift 2
		;;
	--raw)
		[ $# -ge 2 ] || die "--raw wants a value"
		RAW=$2
		shift 2
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
		DEVS="$DEVS $1"
		shift
		;;
	esac
done

case "$SECONDS_ARG" in '' | *[!0-9]*) die "--seconds must be a positive integer" ;; esac
case "$INTERVAL" in '' | *[!0-9]*) die "--interval must be a positive integer" ;; esac
[ "$SECONDS_ARG" -gt 0 ] || die "--seconds must be > 0"
[ "$INTERVAL" -gt 0 ] || die "--interval must be > 0"
[ "$INTERVAL" -gt "$SECONDS_ARG" ] && INTERVAL=$SECONDS_ARG

if [ -z "$DEVS" ]; then
	[ -d /sys/class/net/br-lan ] && DEVS="$DEVS br-lan"
	wan=
	if command -v uci >/dev/null 2>&1; then
		wan=$(uci -q get network.wan.device 2>/dev/null || true)
		[ -n "$wan" ] || wan=$(uci -q get network.wan.ifname 2>/dev/null || true)
	fi
	[ -n "$wan" ] && [ ! -d "/sys/class/net/$wan" ] && wan=
	if [ -z "$wan" ] && command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		wan=$(ubus call network.interface.wan status 2>/dev/null |
			jsonfilter -e '@.l3_device' 2>/dev/null || true)
	fi
	[ -z "$wan" ] && [ -d /sys/class/net/pppoe-wan ] && wan=pppoe-wan
	if [ -n "$wan" ] && [ -d "/sys/class/net/$wan" ]; then
		DEVS="$DEVS $wan"
	fi
	if [ -z "$DEVS" ]; then
		for d in /sys/class/net/*; do
			[ -d "$d/queues" ] || continue
			name=${d##*/}
			[ "$name" = lo ] && continue
			[ -e "$d/device" ] && DEVS="$DEVS $name"
		done
	fi
fi
[ -n "$DEVS" ] || die "no device to sample (use --dev)"
for d in $DEVS; do
	[ -d "/sys/class/net/$d" ] || echo "sample.sh: warning: $d does not exist" >&2
done

if [ -z "$RAW" ]; then
	if [ -n "$OUT" ]; then
		RAW=$OUT.raw
	else
		RAW=/tmp/dpd-sample.$$.raw
	fi
fi
case "$RAW" in
*/*) mkdir -p "${RAW%/*}" 2>/dev/null || true ;;
esac
if [ -n "$OUT" ]; then
	case "$OUT" in
	*/*) mkdir -p "${OUT%/*}" 2>/dev/null || die "cannot create ${OUT%/*}" ;;
	esac
fi

cleanup() {
	rm -rf "$TMP"
}
trap 'cleanup' 0 1 2 15

napi_value() { # key num|str|bool
	f=/var/run/dpd/napi.json
	[ -r "$f" ] || return 0
	case "$2" in
	num)
		sed -n "s/.*\"$1\":[ ]*\\([-0-9][0-9]*\\).*/\\1/p" "$f" 2>/dev/null | head -n 1
		;;
	str)
		sed -n "s/.*\"$1\":[ ]*\"\\([^\"]*\\)\".*/\\1/p" "$f" 2>/dev/null | head -n 1
		;;
	bool)
		sed -n "s/.*\"$1\":[ ]*\\(true\\).*/\\1/p; s/.*\"$1\":[ ]*\\(false\\).*/\\1/p" "$f" 2>/dev/null | head -n 1
		;;
	esac
}

napi_irqs() {
	[ -x /usr/sbin/dpd-napi-netdev ] || return 0
	/usr/sbin/dpd-napi-netdev list "$1" 2>/dev/null | awk '
		{
			for (i = 1; i <= NF; i++)
				if ($i ~ /^irq=/) {
					sub(/^irq=/, "", $i)
					if ($i + 0 > 0)
						print $i
				}
		}'
}

msi_irqs() {
	f="/sys/class/net/$1/device/msi_irqs"
	[ -r "$f" ] || return 0
	while IFS= read -r irq; do
		case "$irq" in
		'' | *[!0-9]*) continue ;;
		esac
		[ -d "/proc/irq/$irq" ] && printf '%s\n' "$irq"
	done <"$f"
}

proc_irqs() {
	dev=$1
	[ -r /proc/interrupts ] || return 0
	awk -v dev="$dev" '
		$1 ~ /^[0-9]+:$/ {
			found = 0
			for (i = 2; i <= NF; i++) {
				if ($i ~ /^[0-9]+$/)
					continue
				if ($i == dev || index($i, dev "-") == 1)
					found = 1
			}
			if (found) {
				irq = $1
				sub(":", "", irq)
				print irq
			}
		}' /proc/interrupts
}

dev_irqs() {
	{
		napi_irqs "$1"
		msi_irqs "$1"
		proc_irqs "$1"
	} | sort -n -u
}

irq_count() { # irq
	awk -v want="$1:" '
		$1 == want {
			s = 0
			for (i = 2; i <= NF; i++)
				if ($i ~ /^[0-9]+$/)
					s += $i
			print s
			exit
		}' /proc/interrupts 2>/dev/null
}

snapshot() {
	if [ -r /proc/stat ]; then
		awk '/^cpu /{
				t = 0
				for (i = 2; i <= NF; i++) t += $i
				print "C|" t "|" ($5 + $6)
				exit
			}' /proc/stat
	fi

	if [ -r /proc/net/dev ]; then
		awk -v OFS='|' -v want="$DEVS" '
			BEGIN {
				n = split(want, w, " ")
				for (i = 1; i <= n; i++)
					keep[w[i]] = 1
			}
			NR > 2 {
				split($0, a, ":")
				gsub(/[ \t]/, "", a[1])
				if (!(a[1] in keep))
					next
				split(a[2], v)
				print "D", a[1], v[1], v[2], v[3], v[4], v[9], v[10], v[11], v[12]
			}' /proc/net/dev
	fi

	if [ -x /usr/sbin/dpdctl ]; then
		/usr/sbin/dpdctl stats 2>/dev/null |
			awk '$1 ~ /^[0-9]+$/ && NF >= 3 { print "S|" $2 "|" $3 }'
	fi

	v=$(napi_value gro_flush_timeout num)
	[ -n "$v" ] && echo "N|gro_flush_timeout|$v"
	v=$(napi_value napi_defer_hard_irqs num)
	[ -n "$v" ] && echo "N|napi_defer_hard_irqs|$v"
	v=$(napi_value netdev_genl bool)
	[ -n "$v" ] && echo "N|netdev_genl|$v"
	v=$(napi_value devices str)
	[ -n "$v" ] && echo "N|devices|$v"

	for dev in $DEVS; do
		for irq in $(dev_irqs "$dev"); do
			c=$(irq_count "$irq")
			[ -n "$c" ] && echo "I|$dev|$irq|$c"
		done
	done
}

SAMPLES=$((SECONDS_ARG / INTERVAL))
[ "$SAMPLES" -lt 1 ] && SAMPLES=1

: >"$RAW" || die "cannot write $RAW"
T0=$(date +%s)
i=0
while [ "$i" -le "$SAMPLES" ]; do
	snapshot >>"$RAW"
	i=$((i + 1))
	[ "$i" -le "$SAMPLES" ] && sleep "$INTERVAL"
done
T1=$(date +%s)
SECS=$((T1 - T0))
[ "$SECS" -lt 1 ] && SECS=1

summary=$(awk -F'|' -v sec="$SECS" '
	function put(k, v) {
		if (!(k in first)) first[k] = v
		last[k] = v
	}
	function num(x) { return x + 0 }
	function esc(s) {
		gsub(/\\/, "\\\\", s)
		gsub(/"/, "\\\"", s)
		return s
	}
	function jnum(k) { return (k in last) ? last[k] : "null" }

	$1 == "C" { put("cpu_total", $2); put("cpu_idle", $3); samples++ }
	$1 == "D" {
		devs[$2] = 1
		split("rxb rxp rxe rxd txb txp txe txd", fn, " ")
		for (i = 1; i <= 8; i++)
			put("D|" $2 "|" fn[i], $(i + 2))
	}
	$1 == "S" { put("S|" $2, $3); stats[$2] = 1 }
	$1 == "I" { put("I|" $2 "|" $3, $4); idev[$2] = 1; iirq[$2 SUBSEP $3] = 1 }
	$1 == "N" { put("N|" $2, $3) }

	END {
		dt = num(last["cpu_total"]) - num(first["cpu_total"])
		di = num(last["cpu_idle"]) - num(first["cpu_idle"])
		cpup = (dt > 0) ? 100 * (dt - di) / dt : 0

		printf "{\n"
		printf "  \"seconds\": %d,\n", sec
		printf "  \"samples\": %d,\n", samples
		printf "  \"cpu_pct\": %.1f,\n", cpup
		printf "  \"devices\": {"

		n = 0
		for (d in devs) order[++n] = d
		for (i = 1; i <= n; i++) {
			d = order[i]
			rxb = num(last["D|" d "|rxb"]) - num(first["D|" d "|rxb"])
			rxp = num(last["D|" d "|rxp"]) - num(first["D|" d "|rxp"])
			rxe = num(last["D|" d "|rxe"]) - num(first["D|" d "|rxe"])
			rxd = num(last["D|" d "|rxd"]) - num(first["D|" d "|rxd"])
			txb = num(last["D|" d "|txb"]) - num(first["D|" d "|txb"])
			txp = num(last["D|" d "|txp"]) - num(first["D|" d "|txp"])
			txe = num(last["D|" d "|txe"]) - num(first["D|" d "|txe"])
			txd = num(last["D|" d "|txd"]) - num(first["D|" d "|txd"])
			if (i > 1) printf ","
			printf "\n    \"%s\": {\"rx_bytes\": %.0f, \"rx_pkts\": %.0f, \"rx_errs\": %.0f, ", d, rxb, rxp, rxe
			printf "\"rx_drops\": %.0f, \"rx_mbps\": %.3f, \"rx_pps\": %.1f, ", rxd, rxb * 8 / sec / 1e6, rxp / sec
			printf "\"tx_bytes\": %.0f, \"tx_pkts\": %.0f, \"tx_errs\": %.0f, ", txb, txp, txe
			printf "\"tx_drops\": %.0f, \"tx_mbps\": %.3f, \"tx_pps\": %.1f}", txd, txb * 8 / sec / 1e6, txp / sec
		}
		printf "\n  },\n"

		printf "  \"dpd\": {"
		n = 0
		for (s in stats) dorder[++n] = s
		for (i = 1; i <= n; i++) {
			s = dorder[i]
			v = num(last["S|" s]) - num(first["S|" s])
			if (i > 1) printf ","
			printf "\n    \"%s\": %.0f", s, v
		}
		printf "\n  },\n"

		printf "  \"napi\": {\"gro_flush_timeout\": %s, ", jnum("N|gro_flush_timeout")
		printf "\"napi_defer_hard_irqs\": %s, ", jnum("N|napi_defer_hard_irqs")
		printf "\"netdev_genl\": %s, ", jnum("N|netdev_genl")
		if ("N|devices" in last)
			printf "\"devices\": \"%s\"},\n", esc(last["N|devices"])
		else
			printf "\"devices\": null},\n"

		printf "  \"interrupts\": {"
		n = 0
		for (d in idev) dorder2[++n] = d
		for (i = 1; i <= n; i++) {
			d = dorder2[i]
			if (i > 1) printf ","
			printf "\n    \"%s\": {\"total\": ", d
			total = 0
			ic = 0
			for (k in iirq) {
				split(k, p, SUBSEP)
				if (p[1] == d) {
					v = num(last["I|" d "|" p[2]]) - num(first["I|" d "|" p[2]])
					total += v
					ic++
				}
			}
			printf "%.0f, \"irqs\": {", total
			ic = 0
			for (k in iirq) {
				split(k, p, SUBSEP)
				if (p[1] == d) {
					v = num(last["I|" d "|" p[2]]) - num(first["I|" d "|" p[2]])
					if (ic > 0) printf ", "
					printf "\"%s\": %.0f", p[2], v
					ic++
				}
			}
			printf "}}"
		}
		printf "\n  }\n"
		printf "}\n"
	}' "$RAW") || die "summary failed"

if [ -n "$OUT" ]; then
	printf '%s\n' "$summary" >"$OUT" || die "cannot write $OUT"
fi
printf '%s\n' "$summary"
echo "sample.sh: raw samples in $RAW" >&2
