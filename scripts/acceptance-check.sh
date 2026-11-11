#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# acceptance-check.sh - self-check the acceptance criteria on a live device.
#
# Implements the checks in docs/ACCEPTANCE-CRITERIA.md that can be run
# read-mostly on the box itself. It changes state only for the duration of a
# single tc filter probe and removes it again.
#
# usage: sh scripts/acceptance-check.sh [lan-port]
#   lan-port defaults to lan2; it must be a REAL switch port, because the
#   hardware rejects anything else (that is itself one of the checks).
#
# exit: 0 all pass, 1 at least one failed.

set -u

PORT=${1:-lan2}
PPE=/sys/kernel/debug/3a000000.ppe
CTL=/usr/sbin/dpdctl

pass=0
fail=0

chk() {		# chk <name> <want> <got>
	if [ "$2" = "$3" ]; then
		echo "  PASS  $1 = $3"
		pass=$((pass + 1))
	else
		echo "  FAIL  $1 = $3 (want $2)"
		fail=$((fail + 1))
	fi
}

info() { echo "  info  $1"; }

echo "===== AC-5 package installed on this box ====="
if [ -r /usr/lib/dpd/abi ]; then
	chk "abi stamp" 22 "$(tr -d '[:space:]' < /usr/lib/dpd/abi)"
else
	echo "  FAIL  /usr/lib/dpd/abi missing"
	fail=$((fail + 1))
fi
info "dpdctl: $($CTL version 2>/dev/null || echo absent)"
if [ -r /lib/bpf/dpd_fastpath.bpf.o ]; then
	info "bpf object: $(wc -c < /lib/bpf/dpd_fastpath.bpf.o) bytes"
else
	echo "  FAIL  /lib/bpf/dpd_fastpath.bpf.o missing"
	fail=$((fail + 1))
fi
if command -v strings >/dev/null 2>&1 && [ -r /usr/sbin/dpdfwd ]; then
	chk "dpdfwd carries the conntrack sweep" 1 \
		"$(strings /usr/sbin/dpdfwd | grep -c '/proc/net/nf_conntrack')"
fi

echo
echo "===== AC-4 PPE hardware ACL (tc flower) ====="
if [ ! -d "/sys/class/net/$PORT" ]; then
	echo "  FAIL  no such port: $PORT"
	fail=$((fail + 1))
else
	tc qdisc del dev "$PORT" clsact 2>/dev/null
	tc qdisc add dev "$PORT" clsact 2>/dev/null
	tc filter add dev "$PORT" ingress pref 100 protocol ip flower \
		src_ip 10.10.10.173 skip_sw action drop 2>/dev/null
	chk "filter bound in hardware" 1 \
		"$(tc filter show dev "$PORT" ingress 2>/dev/null |
			grep -c 'in_hw_count 1')"
	chk "hardware owns the statistics" 1 \
		"$(tc filter show dev "$PORT" ingress 2>/dev/null |
			grep -c 'used_hw_stats immediate')"
	tc qdisc del dev "$PORT" clsact 2>/dev/null
fi

echo
echo "===== AC-4b a software device must be rejected ====="
BR=${BRIDGE:-br-lan}
tc qdisc del dev "$BR" clsact 2>/dev/null
tc qdisc add dev "$BR" clsact 2>/dev/null
chk "$BR rejected as a hardware target" 1 \
	"$(tc filter add dev "$BR" ingress pref 100 protocol ip flower \
		src_ip 10.10.10.173 skip_sw action drop 2>&1 |
		grep -c 'Not supported')"
tc qdisc del dev "$BR" clsact 2>/dev/null

echo
echo "===== AC-2 software flowtable with offload ====="
ft=$(nft list ruleset 2>/dev/null | grep -c 'flags offload')
if [ "$ft" -ge 1 ]; then
	echo "  PASS  flowtables with offload = $ft"
	pass=$((pass + 1))
else
	echo "  FAIL  no flowtable carries 'flags offload'"
	fail=$((fail + 1))
fi

echo
echo "===== AC-X hardware L3 offload is absent by driver design ====="
if [ -r "$PPE/offload" ]; then
	info "offloaded=$(( $(awk '/^offloaded/{print $2}' "$PPE/offload") ))"
	info "live_entries=$(( $(awk '/^live_entries/{print $2}' "$PPE/offload") ))"
	# qca_ppe_setup_tc must expose only QoS branches, and no flow_block.
	fb=$(grep -cE 'qca_ppe.*flow_block' /proc/kallsyms 2>/dev/null)
	[ -n "$fb" ] || fb=0
	chk "no qca_ppe flow_block symbol" 0 "$fb"
else
	info "no qca-ppe debugfs on this box (not a PPE platform)"
fi

echo
echo "===== summary ====="
echo "  PASS=$pass FAIL=$fail"
if [ "$fail" = 0 ]; then
	echo "  acceptance-check: OK"
	exit 0
fi
echo "  acceptance-check: FAILED"
exit 1