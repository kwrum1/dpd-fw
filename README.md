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

Functional on x86 (N5000, OpenWrt 6.18, ABI 20) and Rockchip. The source tree is
organized as `bpf/core`, `userspace/*`, `openwrt/*`, `plugins/*`; the dataplane
is validated on the N5000 (see `docs/acceptance-N5000-2026-11-09.md`,
`docs/inspection-2026-11-09.md` and `docs/OPTIMIZATION-2026-11-10.md`). The
image/package pipeline lives in `kwrum1/ebpf-honk-ImmortalWRT-CI`.

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
# host-side syntax checks (no shellcheck needed)
sh scripts/check-scripts.sh

# BPF object (requires clang/llvm and kernel headers)
make -C bpf/core
```

## CI

`.github/workflows/ci.yml` runs on every push, pull request and by hand. Three
jobs on `ubuntu-latest`:

- `shell` - `shellcheck -S warning` on every tracked shell script (plus
  `sh -n` via `scripts/check-scripts.sh`);
- `bpf` - compiles every `bpf/**/*.bpf.c` with `clang -target bpf`, asserts the
  `classifier/l2` and `classifier/l3` sections, and builds `dpdctl` with
  `-Wall -Werror`;
- `abi` - runs `scripts/verify-abi.sh`: the ABI stamp agrees with
  `docs/ARCHITECTURE.md`, the section names match, and every `ST_*` counter has
  a name in `dpdctl`'s `stat_name()`.

Both scripts work without CI: `sh scripts/check-scripts.sh` is a fast
syntax-only pass, and `sh scripts/verify-abi.sh` checks an ABI bump (add
`--obj /lib/bpf/dpd_fastpath.bpf.o` on a build host to inspect a real object).

The image and OpenWrt package builds live in the separate firmware repository
`kwrum1/ebpf-honk-ImmortalWRT-CI` (its own Actions). This workflow only validates
the source tree. Both repositories pin actions to stable major versions and use
least-privilege `permissions`; image builds have per-workflow `concurrency` and a
240-minute timeout.

## Feed

`openwrt/feed/README.md` explains how to consume this repository as an OpenWrt
feed: `src-link` over a generated index, per-package symlinks, or `src-git`.
`sh scripts/feed-index.sh` builds the flat directory a feed needs (feeds only
scan their direct children for a `Makefile`). The same README documents the
in-place upgrade caveat: an ABI change drops the pinned `/sys/fs/bpf/dpd_*`
maps, so the object and `dpdctl` must come from one package version.

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
