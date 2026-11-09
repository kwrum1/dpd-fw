# P4 — NAPI / queue tuning

`dpd-napi` is a control-plane package. It applies only standard kernel knobs;
no driver changes.

## Implemented

### Device-wide (sysfs/sysctl)

- `/proc/sys/net/core/netdev_budget`
- `/proc/sys/net/core/netdev_budget_usecs`
- `/proc/sys/net/core/dev_weight`
- per-netdev `gro_flush_timeout` / `napi_defer_hard_irqs` (legacy paths)
- RPS: each `queues/rx-*/rps_cpus`
- XPS: each `queues/tx-*/xps_cpus`

### Per-NAPI (netdev generic netlink, kernel >= 6.10)

`/usr/sbin/dpd-napi-netdev` talks to the kernel's `netdev` family directly
(NETLINK_GENERIC, no libmnl/libnl). It lists the real NAPI instances and sets:

- `gro_flush_timeout`
- `defer_hard_irqs`
- `irq_suspend_timeout` (no sysfs file exists for this at all)
- `threaded` (NAPI kthreads)

Commands:

```
dpd-napi-netdev list [dev]
dpd-napi-netdev set <dev> gro_flush_timeout <ns> defer_hard_irqs <n> \
                       [irq_suspend_timeout <ns>] [threaded <0|1>]
```

The daemon uses this path when the helper exists and `netdev_genl` is enabled
(default 1), and falls back to the sysfs path when the family is missing
(exit code 2). `/var/run/dpd/napi.json` records `netdev_genl: true|false`.

## Lab evidence (dpd-test, 6.18.0, x86_64, vmxnet3)

```
# /usr/sbin/dpd-napi-netdev list eth1
ifindex=3 napi=540 irq=0 ... defer_hard_irqs=0 gro_flush_timeout=0 ...
ifindex=3 napi=539 ...
ifindex=3 napi=538 ...
ifindex=3 napi=537 ...

# /usr/sbin/dpd-napi-netdev set eth1 gro_flush_timeout 200 defer_hard_irqs 3
# /usr/sbin/dpd-napi-netdev list eth1
ifindex=3 napi=540 ... defer_hard_irqs=3 gro_flush_timeout=200 ...
... (all four instances)
```

All four per-queue NAPIs of eth1 were updated individually. `threaded` is
accepted by the family but vmxnet3 stays `threaded=0` (the driver does not
opt in); the code treats an unsupported attribute as a no-op, not a failure.

The service run writes:

```
{ "enabled": true, ..., "gro_flush_timeout": 200, "napi_defer_hard_irqs": 3,
  "netdev_genl": true, "devices": " br-lan dummy0 eth0 eth1 eth2 teql0 vbr" }
```

## Notes

- Two UAPI details cost real time while bringing this up: `CTRL_ATTR_FAMILY_ID`
  is a **u16** (not u32), and `NAPI_GET`/`NAPI_SET` are commands **11/14**
  (`QUEUE_GET` is 10 and `BIND_RX` is 13, so an off-by-one silently dumps
  queue entries and "sets" a dmabuf binding).
- Kernel 6.17 returns `-EINVAL` for a NAPI dump filtered by ifindex even
  though the spec lists the filter; the helper dumps all and filters in
  userspace.
- Threaded NAPI and IRQ affinity for real drivers still need A/B numbers on
  1G/2.5G/10G hardware; the knobs are now reachable but the profile choice is
  per platform.

## Guardrails

- `qos=off` is required for the 10G line-rate target; CAKE is a separate gate.
- GRO/GSO help the eBPF software path; do not copy the NSS/PPE practice of
  disabling them, that guidance is for hardware offload.
- Every setting must have a measured A/B result; no blind defaults.
