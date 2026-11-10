#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# ppe-probe.sh - read-only detection of the Qualcomm hardware-offload backend.
#
# Two different things are called "PPE" on Qualcomm:
#   qcom-ppe  upstream 6.18 Ethernet/switch driver (IPQ9574/IPQ5424),
#             L2 only today, L3/NAT offload not implemented yet;
#   nss-ecm   out-of-tree NSS firmware + ECM (IPQ807x/IPQ60xx), full L3/NAT
#             offload; once NSS runs, offloaded packets never reach Linux/TC.
#
# The gate needs to tell them apart before it can decide whether DPD may
# accelerate (docs/RESEARCH-PPE-DUAL.md). This script only reads sysfs,
# debugfs, /proc and the module list; it changes nothing.
#
# Output is one key=value per line so a shell caller and a LuCI page can both
# consume it. `backend=` is the only line that needs to be parsed: none,
# qcom-ppe or nss-ecm.

say() { printf '%s=%s\n' "$1" "$2"; }

backend=none
ppe_dbg=0
ecm_dbg=0
nss_mod=0
ppe_mod=0
ppe_dev=0
nss_dev=0
edma_dev=0

# --- modules ---------------------------------------------------------------
# The driver is spelled differently depending on the tree: upstream calls it
# qcom-ppe (IPQ9574/5424), the ImmortalWrt qualcommax tree ships qca-ppe
# (IPQ60xx/807x). It is also commonly builtin, in which case /proc/modules does
# NOT list it -- /sys/module/<name> still exists. Both spellings and both
# builtin/module cases are checked; a probe that only looked for qcom_ppe in
# /proc/modules reported this IPQ60xx as "no PPE" (measured 2026-11-11).
if grep -qE '^(qcom_ppe|qca_ppe) ' /proc/modules 2>/dev/null ||
   [ -d /sys/module/qcom_ppe ] || [ -d /sys/module/qca_ppe ]; then
	ppe_mod=1
fi
if grep -qE '^(qca_nss_drv|qca_nss_dp|qca_nss_ecm) ' /proc/modules 2>/dev/null ||
   [ -d /sys/module/qca_nss_drv ] || [ -d /sys/module/qca_nss_ecm ]; then
	nss_mod=1
fi

# --- debugfs ---------------------------------------------------------------
# The qca-ppe driver creates its debugfs dir as the *platform device* name,
# /sys/kernel/debug/<addr>.ppe (measured: 3a000000.ppe on IPQ60xx), not a tidy
# "ppe". Match either form so an upstream rename does not silently disable the
# backend detection.
[ -d /sys/kernel/debug/ppe ] && ppe_dbg=1
for d in /sys/kernel/debug/*.ppe; do
	[ -d "$d" ] && ppe_dbg=1
done
[ -d /sys/kernel/debug/ecm ] && ecm_dbg=1

# --- netdev drivers --------------------------------------------------------
# qca-ppe drives IPQ9574/5424 ports, nss-dp (or qca-nss-dp) is the older NSS
# data-path driver; qca_edma is the upstream EDMA used by both.
for dev in /sys/class/net/*; do
	[ -e "$dev/device/driver" ] || continue
	drv=$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null)" 2>/dev/null)
	# qca-ppe / qcom-ppe are the *modern* upstream switch+PPE driver; they must
	# NOT be treated as the NSS data path. This case used to set nss_dev=1, so
	# a pure qcom-ppe board (IPQ60xx here) was reported as nss-ecm and the
	# caller recommended ppe_mode=fallback -- exactly the wrong advice, since
	# there is no NSS firmware on this box to fall back from.
	case "$drv" in
	qca-ppe|qcom-ppe)
		ppe_dev=1
		;;
	nss-dp|qca-nss-dp|qca-nss)
		nss_dev=1
		;;
	qca_edma|qcom_edma)
		edma_dev=1
		;;
	esac
done

# --- decide ----------------------------------------------------------------
# NSS is chosen only on real NSS evidence (module, ECM debugfs, or the NSS
# netdev driver). The modern qcom-ppe driver is its own backend and can carry
# L3 offload (active_flows / offload counters under its debugfs dir).
if [ "$nss_mod" = 1 ] || [ "$ecm_dbg" = 1 ] || [ "$nss_dev" = 1 ]; then
	backend=nss-ecm
elif [ "$ppe_mod" = 1 ] || [ "$ppe_dbg" = 1 ] || [ "$ppe_dev" = 1 ]; then
	backend=qcom-ppe
fi

say backend "$backend"
say qcom_ppe_module "$ppe_mod"
say qcom_ppe_debugfs "$ppe_dbg"
say nss_modules "$nss_mod"
say ecm_debugfs "$ecm_dbg"
say qcom_ppe_netdev "$ppe_dev"
say nss_netdev "$nss_dev"
say edma_netdev "$edma_dev"
command -v nssinfo >/dev/null 2>&1 && say nssinfo yes || say nssinfo no

# --- conntrack offload state ----------------------------------------------
# IPS_OFFLOAD (software flowtable) and IPS_HW_OFFLOAD (hardware) show up as
# [OFFLOAD] / [HW_OFFLOAD] in the proc table and via ctnetlink CTA_STATUS.
if [ -r /proc/net/nf_conntrack ]; then
	say ct_offload "$(grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack 2>/dev/null)"
	say ct_hw_offload "$(grep -c '\[HW_OFFLOAD\]' /proc/net/nf_conntrack 2>/dev/null)"
else
	say ct_offload unknown
	say ct_hw_offload unknown
fi

# --- DPD's own view --------------------------------------------------------
if command -v dpdctl >/dev/null 2>&1; then
	say dpd_mode "$(dpdctl show 2>/dev/null | awk '/^mode/ { print $2; exit }')"
	say dpd_nat_offload "$(dpdctl show 2>/dev/null | awk '/^nat_offload/ { print $2; exit }')"
	say dpd_nat_forward "$(dpdctl show 2>/dev/null | awk '/^nat_forward/ { print $2; exit }')"
else
	say dpd_mode absent
	say dpd_nat_offload absent
	say dpd_nat_forward absent
fi

# --- recommended mode ------------------------------------------------------
# auto: layered dual where PPE has no L3 offload; fallback where NSS owns the
# data plane; off elsewhere. This is advice, not configuration.
case "$backend" in
qcom-ppe) say recommended ppe_mode=dual ;;
nss-ecm)  say recommended ppe_mode=fallback ;;
*)        say recommended ppe_mode=off ;;
esac
