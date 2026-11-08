# P4 — NAPI / queue tuning

`dpd-napi` is a control-plane package. It applies only standard kernel knobs;
no driver changes.

## Implemented (sysfs/sysctl)

- `/proc/sys/net/core/netdev_budget`
- `/proc/sys/net/core/netdev_budget_usecs`
- `/proc/sys/net/core/dev_weight`
- per-netdev `gro_flush_timeout`
- per-netdev `napi_defer_hard_irqs`
- RPS: each `queues/rx-*/rps_cpus`
- XPS: each `queues/tx-*/xps_cpus`

All values come from `/etc/config/dpd_napi`; the daemon applies once at start
and publishes `/var/run/dpd/napi.json`.

## Not yet implemented (netdev-genl)

The following need the `netdev` generic-netlink family, not sysfs:

- per-NAPI `defer-hard-irqs` / `gro-flush-timeout` / `irq-suspend-timeout`;
- `threaded` NAPI and kthread CPU affinity;
- per-queue IRQ affinity and RSS indirection table.

The plan is a small C helper using libmnl/libnl (or `ynl` if present) that
enumerates NAPI IDs and applies the same UCI values. This is P4.1; the sysfs
version is shipped first because it is universally available.

## Test plan

- 1G/2.5G: 64B/512B/1500B, single and 4 parallel flows;
- `gro_flush_timeout` 0 vs 50µs/100µs; `napi_defer_hard_irqs` 0 vs 10;
- threaded NAPI on/off, with P99 RTT and CPU per queue;
- keep the best profile per platform in `Config/` rather than hard-coding.

## Guardrails

- `qos=off` is required for the 10G line-rate target; CAKE is a separate gate.
- GRO/GSO help the eBPF software path; do not copy the NSS/PPE practice of
  disabling them, that guidance is for hardware offload.
- Every setting must have a measured A/B result; no blind defaults.
