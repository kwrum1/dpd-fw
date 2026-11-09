#!/bin/sh
# Compare two results.csv files (baseline vs DPD) and print a Markdown table.
#
#   sh tests/bench/compare.sh baseline.csv dpd.csv
#   sh tests/bench/compare.sh baseline.csv dpd.csv > compare.md
#
# Rows are matched on (scenario, size, flows). Column order in the CSV does not
# matter. Missing/extra rows are counted, not silently dropped. Exit status is
# 1 when the two files have no row in common.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LC_ALL=C
export LC_ALL

BASE=${1:-}
DPD=${2:-}

usage() {
	cat <<'EOF'
usage: compare.sh BASELINE.csv DPD.csv
EOF
}

if [ -z "$BASE" ] || [ -z "$DPD" ]; then
	usage >&2
	exit 2
fi
[ -r "$BASE" ] || { echo "compare.sh: cannot read $BASE" >&2; exit 2; }
[ -r "$DPD" ] || { echo "compare.sh: cannot read $DPD" >&2; exit 2; }

for f in "$BASE" "$DPD"; do
	head -n 1 "$f" | tr -d '\r' | tr ',' '\n' > /tmp/dpd-cmp-hdr.$$
	for col in scenario size flows mbps pps cpu_pct retrans; do
		if ! grep -qx "$col" /tmp/dpd-cmp-hdr.$$; then
			rm -f /tmp/dpd-cmp-hdr.$$
			echo "compare.sh: $f has no '$col' column" >&2
			exit 2
		fi
	done
done
rm -f /tmp/dpd-cmp-hdr.$$

awk -F, '
	function trim(s) {
		gsub(/\r/, "", s)
		gsub(/^[ \t]+/, "", s)
		gsub(/[ \t]+$/, "", s)
		return s
	}
	function pct(b, d) {
		if (b + 0 == 0) return "n/a"
		return sprintf("%+.1f%%", (d - b) / b * 100)
	}
	FNR == NR {
		if (FNR == 1) {
			for (i = 1; i <= NF; i++) h[trim($i)] = i
			next
		}
		key = trim($h["scenario"]) SUBSEP trim($h["size"]) SUBSEP trim($h["flows"])
		bm[key] = trim($h["mbps"]) + 0
		bp[key] = trim($h["pps"]) + 0
		bc[key] = trim($h["cpu_pct"]) + 0
		br[key] = trim($h["retrans"]) + 0
		border[++nb] = key
		bseen[key] = 1
		next
	}
	FNR == 1 {
		for (i = 1; i <= NF; i++) h2[trim($i)] = i
		next
	}
	{
		key = trim($h2["scenario"]) SUBSEP trim($h2["size"]) SUBSEP trim($h2["flows"])
		dm[key] = trim($h2["mbps"]) + 0
		dp[key] = trim($h2["pps"]) + 0
		dc[key] = trim($h2["cpu_pct"]) + 0
		dr[key] = trim($h2["retrans"]) + 0
		dseen[key] = 1
		if (!(key in bseen))
			extra[++ne] = key
	}
	END {
		print "| scenario | size | flows | baseline Mbps | dpd Mbps | delta Mbps | baseline pps | dpd pps | delta pps | CPU % (base -> dpd) | retrans (base -> dpd) |"
		print "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"

		matched = 0
		missing = 0
		improved = 0
		degraded = 0
		sum_b = 0
		sum_d = 0

		for (i = 1; i <= nb; i++) {
			key = border[i]
			if (!(key in dseen)) {
				missing++
				continue
			}
			split(key, p, SUBSEP)
			matched++
			sum_b += bm[key]
			sum_d += dm[key]
			if (dm[key] > bm[key]) improved++
			if (dm[key] < bm[key]) degraded++
			printf("| %s | %s | %s | %.3f | %.3f | %s | %.1f | %.1f | %s | %.1f -> %.1f | %d -> %d |\n",
				p[1], p[2], p[3],
				bm[key], dm[key], pct(bm[key], dm[key]),
				bp[key], dp[key], pct(bp[key], dp[key]),
				bc[key], dc[key], br[key], dr[key])
		}

		print ""
		printf("**Rows:** %d matched, %d only in baseline, %d only in dpd; %d improved, %d degraded.\n",
			matched, missing, ne, improved, degraded)
		if (sum_b > 0)
			printf("**Aggregate throughput:** %.3f -> %.3f Mbps (%+.1f%%).\n",
				sum_b, sum_d, (sum_d - sum_b) / sum_b * 100)
		else
			printf("**Aggregate throughput:** baseline is zero, no ratio.\n")

		if (ne > 0) {
			printf("**Only in dpd:** ")
			for (i = 1; i <= ne; i++) {
				split(extra[i], p, SUBSEP)
				printf("%s%s/%s/%s", (i > 1) ? ", " : "", p[1], p[2], p[3])
			}
			printf("\n")
		}

		if (matched > 0)
			exit 0
		exit 1
	}
' "$BASE" "$DPD"

exit $?
