# DPD-FW Technical Guide (English)

This is the English companion to [DPD-GUIDE.zh-CN.md](DPD-GUIDE.zh-CN.md). It
describes the architecture, datapath, NAT/acceleration ownership, coexistence
with honk/PPE, NAPI tuning, observability, build and operations.

## 1. Scope

DPD-FW is a **TC/eBPF software dataplane** for OpenWrt:

- it caches flows (UFS) on `tc` ingress/egress hooks; no XDP, AF_XDP, DPDK or
  driver-private interface;
- it runs on stock drivers on x86 and Rockchip (ARM64);
- hardware offload (Qualcomm PPE/NSS, MediaTek HNAT) is a separate layer; the
  goal is coexistence and fallback, not replacing the silicon;
- NAT is owned by `einat` (TC eBPF full-cone NAT) by default; DPD accelerates
  the forwarding. DPD-owned NAT is available, but the two engines must never
  share an uplink.

It is **not**: a second firewall, a second NAT (by default), a second
flowtable, or a hardware-offload driver.

## 2. Components

```
┌──────────────────────────── control plane ─────────────────────────────┐
│ dpdfwd        flow lifecycle, ctnetlink, auto-tune, epoch, plugins     │
│ dpdctl        maps/flows/local addresses/NAT bindings CLI              │
│ dpd-napi      NAPI/IRQ/GRO/RPS/XPS/qdisc tuning (adaptive profiles)    │
│ LuCI          status, simple firewall, multi-WAN, NAPI/DPD pages       │
└───────────────────────────────┬────────────────────────────────────────┘
                                │ pinned BPF maps
┌───────────────────────────────┴────────────────────────────────────────┐
│ TC eBPF dataplane (bpf/core/src/dpd_fastpath.bpf.c)                    │
│  classifier/l2    LAN ingress (br-lan / bridge ports)                  │
│  classifier/l3    WAN ingress (pppoe-wan, downlink=1)                  │
│  classifier/nat   WAN ingress pref 50 (DNAT, DPD-owned NAT only)       │
│  classifier/egress WAN egress (SNAT, DPD-owned NAT only)               │
└─────────────────────────────────────────────────────────────────────────┘
```

Plugins: `dpd-honk` (honk lifecycle/gate), `dpd-einat` (NAT binding sync),
`dpd-acl`, `dpd-qos`, `dpd-mwan`, `dpd-observe`, `dpd-knod` (optional GPU
provider).

## 3. Packet path

```
frame arrives
  │
  ├─ br-lan / eth0..2 ingress: classifier/l2
  │    └─ parse L2/L3/L4, UFS lookup (dpd_flows)
  │
  └─ pppoe-wan ingress: classifier/l3 (downlink)
       └─ same UFS logic

hit:
  epoch/TTL/policy checks
    → (NATed flow) dpd_nat binding gate
    → restore skb_priority
    → VLAN handling / TTL decrement
    → dpd_emit_cached: write the L2 header + bpf_redirect
       (ppp/tun: bpf_redirect(ifindex), no neighbour table)

miss:
  → local-delivery fast check (dpd_local) → hand to the stack
  → bpf_fib_lookup (retry with SKIP_NEIGH for ppp/tun)
  → local/unforwardable → hand to the stack
  → NAT gate (einat mode requires a consistent forward+reverse binding)
  → learn the UFS entry (prime = accel_after_pkts)
  → the current packet still walks the stack
```

### 3.1 Flow key and UFS

`struct dpd_flow_key` = ingress ifindex + family + proto + 5-tuple.
`dpd_flows` is an LRU hash (16384 entries by default); each value stores:

- `egress_ifindex`, `flags` (L2/DEV/NO_NEIGH/L3OUT/NAT), `wan` (WAN index + epoch);
- `dmac/smac`, IPv4 nexthop;
- `last_seen_ms`, `state` (OBSERVE/BIND/FIN), `action`;
- `packets/bytes` (`flow_counters` 0/1/2).

### 3.2 Takeover threshold (priming)

A new direction first walks `accel_after_pkts` packets (default 8; the tuner
may lower/raise it within 8..64). Taking over too early hides the handshake
and ACKs from netfilter, leaving conntrack incomplete.

### 3.3 Epoch

Link/address/route changes invalidate the whole flow cache (`epoch++`).
Neighbour (IPv6 NUD) events are rate-limited to one bump per 30 s; otherwise the
cache is flushed every couple of seconds and short flows never get learned.
The epoch lives in the high byte of `dpd_flow_val.wan`, so the hit path needs
one comparison.

### 3.4 Local-delivery fast check (dpd_local)

`dpdctl local sync` fills `dpd_local` with the router's own IPv4/IPv6
addresses. The miss path checks it before the FIB lookup: a packet addressed to
the router can only be delivered locally, so it increments `local` and returns
`TC_ACT_UNSPEC` instead of paying a FIB lookup that must fail. `dpdfwd`
re-syncs on address events.

## 4. NAT ownership

### 4.1 einat mode (default)

- einat performs SNAT/DNAT in TC (full-cone), outside conntrack;
- `dpd-einat-sync` mirrors the bindings into `dpd_nat`/`dpd_nat_rev`;
- the DPD hit/learn gate requires **forward and reverse bindings to agree**:
  the reverse lookup for `dpd_nat`'s `to_addr/to_port` must point back at the
  same internal tuple. A mismatch (recycled/overwritten binding) is not learned;
  `nat_gone++` and the flow stays on the stack.
- A long-lived flow can outlive its binding; the gate keeps it on the stack
  instead of emitting with the wrong external port.

### 4.2 DPD-owned NAT (`nat_forward=dpd` / `nat_ingress=dpd`)

- DNAT at WAN ingress pref 50, SNAT + port allocation at WAN egress
  (20000–29999);
- its own `dpd_nat` bindings and recycling; mutually exclusive with einat (the
  gate refuses double NAT);
- useful without einat. Measured on the N5000, its return-half learning was
  worse than einat's; it is not the default.

### 4.3 honk

honk owns the LAN TCX hook for the proxy. The stock core returns `TC_ACT_OK`
for `direct` flows, which terminates the TCX chain and hides them from the
classic chain (DPD). x86/RK use the **p1 core**: direct flows carry
`DIRECT_UNSPEC_MARK` and return `TC_ACT_UNSPEC`, so DPD can take them over.
Proxy/block verdicts remain terminal; NAT stays with einat. IPQ/MTK use the
stock honk core.

## 5. Coexistence with PPE/NSS/flowtable

- **Qualcomm qca_ppe (IPQ60xx/807x)**: netfilter flowtable hardware offload;
  the first packet walks the host, then the PPE takes over. DPD must not steal
  before the grace window; offloaded packets never reach TC.
- **Qualcomm NSS/ECM**: offloaded packets never reach Linux; DPD only sees
  exception/return traffic.
- **DPD-owned NAT + PPE**: the NAT engine must be chosen per flow for its whole
  lifetime (conntrack/PPE or einat/DPD); no mid-flow switch.
- **MediaTek HNAT**: same flowtable model.

Rule: **one flow is never accelerated by two layers at once**; DPD handles what
the hardware cannot or does not.

## 6. NAPI / queues

`dpd-napi` has three profiles:

- `low` (default): `gro_flush_timeout=0`, `napi_defer_hard_irqs=0`,
  `netdev_budget=300`, `dev_weight=64`, RPS/XPS off;
- `throughput`: `20000ns/2`, `1000`, `128`, RPS/XPS=`f`;
- `adaptive`: start low; switch to throughput after CPU>60% for 3×10 s, back to
  low after <25% for 6×10 s.

`irq_cpus` + `irq_spread=1` assigns one CPU per IRQ round-robin (e.g. `0-3`).
`busy_poll`/`busy_read` only affect sockets that set `SO_BUSY_POLL`; the
forwarding path does not, so they default to 0.

Local 64B UDP A/B (fixed 90 Mbps): spread vs full mask is within noise on
throughput and ~7% lower CPU per MB; the throughput profile roughly halves
softirq at ~176k pps (GRO/RPS) at the cost of latency.

## 7. Observability

```sh
dpdctl status -j          # cfg/maps/counters/gate, JSON
dpdctl show               # human-readable cfg/iface/ttl/nat
dpdctl stats              # per-CPU summed counters
dpdctl flows -a           # full UFS (5-tuple, state, pkt/bytes)
dpdctl local list         # local-delivery table
dpdctl nat [-a]           # einat-mirrored bindings/reverse
cat /var/run/dpd/flowd.json   # flow manager, epoch, tune, ct offload
cat /var/run/dpd/napi.json    # NAPI profile, IRQ spread, busy_poll
cat /var/run/ebpf/gate.json   # gate decision and reason
```

Key counters: `flow_hit/flow_miss`, `bytes_hit_v4/v6`, `fib_ok/fib_fail`,
`local`, `nat_gone`, `flow_bind/fin`, `redirect_ok/neigh_ok`.

## 8. Build and CI

- `dpd-fw`: `bpf/core` (BPF object + dpdctl), `userspace/*` (dpdfwd, dpdctl,
  dpd-napi), `openwrt/*` (LuCI), `plugins/*`. CI is
  `.github/workflows/ci.yml`: shellcheck, BPF compile, ABI/section/counter
  checks.
- `ebpf-honk-ImmortalWRT-CI`: image/package builds. X86/RK use
  `patches/honk/` (overlay + `core-p1`); IPQ/MTK use stock honk. `HONK-CORE`
  builds the p1 core and publishes it under the fixed `core-p1` tag.
- Local: `sh scripts/check-scripts.sh`, `make -C bpf/core`,
  `sh scripts/verify-abi.sh`.

## 9. Operations and troubleshooting

- Gate: `/var/run/ebpf/gate.json` (`code`/`reason`); `no-einat`,
  `honk-unpatched` etc. downgrade to observe.
- A flow is not accelerated: check the gate, then `dpdctl flows` state/epoch,
  then `nat_gone`/`fib_fail`.
- Low hit rate: distinguish "never learned" (short flow, NAT binding, FIB
  failure) from "learned but not hit" (epoch/binding change).
- Long-lived NAT flow: recycle it with `conntrack -D` and let the client
  reconnect, or wait for the TTL.
- Disable/rollback: `dpdctl set mode off|observe`;
  `/etc/init.d/dpd-fastpath stop`.

## 10. Known limits

- No XDP/AF_XDP/DPDK; no driver takeover.
- At home link rates the link is usually the bottleneck, not the CPU;
  micro-optimizations have limited payoff.
- An IPv4 NAT flow cannot change its NAT engine mid-life.
- Packets offloaded by PPE/NSS never reach DPD; dual acceleration is a
  flow-level partition, not per-flow stacking.
- GPU/NPU are unsuitable for the fast path (latency/batching/DMA); they fit
  sidecar batch processing only.
- Auto-tune TTL changes are step-limited to avoid oscillation.
