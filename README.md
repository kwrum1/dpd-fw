# dpd-fw

**DPD-FW** is an OpenWrt high-performance dataplane framework built on TC/eBPF.
It turns the existing `dpd-fastpath` into a unified flow-state fastpath with an
ECM-style flow manager, a plugin ecosystem, and NAPI/queue-level tuning.

The project is intentionally **not**:

- XDP / AF_XDP / DPDK / driver-specific; the default path must run on x86 and
  ARM (Rockchip) with stock drivers.
- a second NAT or firewall owner; NAT belongs to the `dpd-einat` plugin, policy
  belongs to `dpd-acl`, proxying belongs to `dpd-honk`.
- a hardware offload replacement for NSS/PPE. It borrows their flow-management
  model, not their silicon.

## Status

**P0 scaffold.** The code migrated from
`kwrum1/ebpf-honk-ImmortalWRT-CI` is being reorganized into `bpf/core`,
`plugins/*`, `userspace/*`, and `openwrt/*`. The first working target is P1:
Flow Manager + one UFS lookup + L2/L3 program variants.

## Architecture

```
dpd-flowd (control plane)
  conntrack / honk / einat / ACL / QoS / MWAN events
  NEW -> OBSERVE(N packets) -> BIND -> FIN
        |
        v
dpd-core (TC eBPF data plane)
  L2 variant / L3 variant -> one UFS lookup
  NAT rewrite -> TTL -> VLAN -> emit -> per-CPU stats
        |
        v
dpd-napi (system layer)
  NAPI threads / IRQ affinity / GRO / GSO / qdisc / RSS / XPS
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## Packages

| Package | Purpose |
|---|---|
| `dpd-core` | UFS BPF programs, `dpdfwd`, `dpdctl`, `libdpd` |
| `dpd-honk` | optional proxy plugin; honk is the only proxy provider |
| `dpd-einat` | full-cone NAT binding and EIF |
| `dpd-acl` | TC-layer ACL / firewall fast path |
| `dpd-qos` | DSCP / CAKE / SQM / short-packet priority |
| `dpd-mwan` | multi-WAN selection and failover |
| `dpd-observe` | flow statistics, gate/status, telemetry |
| `dpd-napi` | NAPI, IRQ, GRO/GSO, qdisc and RSS/XPS tuning |
| `luci-app-dpd` | LuCI UI |
| `dpd-fw` | meta package |

## Build

The OpenWrt package makefiles live under `openwrt/package/` once P0 migration
is complete. Until then, the P0 tree is a source scaffold and the original
package makefiles are kept under each component directory.

```sh
# host-side syntax checks
sh -n bpf/core/files/*.sh plugins/*/files/*.sh userspace/*/*.sh

# BPF object (requires clang/llvm and kernel headers)
make -C bpf/core
```

## Test

- `tests/netns`: namespaces for PPPoE/VLAN/NAT/full-cone.
- `tests/qemu`: full image boot and datapath tests.
- `tests/bench`: iperf3, pktgen/Trex, sockperf, NAPI/map profiling.
- ESXi lab: `router-lab` (OpenWrt) + `ebpf-client2` (OpenWrt) on
  `10.1.18.124`; serial consoles 7005/7004.

## License

- Core (BPF, kernel glue, userspace): GPL-2.0-only.
- `dpd-honk`: GPL-3.0-only (separate process/plugin; it does not link the core).
- Documentation: CC BY 4.0 unless noted.
