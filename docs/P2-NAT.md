# P2.1 — UFS + einat full-cone NAT (bidirectional acceleration)

Status: **verified on the ESXi lab (2026-11-09), ABI 16.**

## The problem, restated

The first attempt took over the LAN→WAN half with DPD's pre-NAT flow key but
never applied einat's SNAT, so the server saw the LAN address and bulk TCP
failed after the priming packets. The obvious fix — rewrite the source at
ingress and update the checksums — does not work either: einat's TCX egress
program **still runs on an skb that DPD redirects from ingress**. Measured
2026-11-09: after DPD rewrote 192.168.10.200:40128 to 198.18.0.1:9044, einat's
egress hook saw the already-external source and allocated a **second** external
port (`198.18.0.1:9044 -> 198.18.0.1:9300`), so the server's ACKs went to a
port whose reverse binding did not exist and the transfer stalled at the priming
window.

## The design that works

```
LAN ingress (classic pref 100, DPD)
    forward hit? -> dpd_nat gate -> bpf_redirect(eth1)
                                     |
                                     v
                          einat TCX egress (SNAT)
                                     |
                                     v
                                   WAN

WAN ingress (einat TCX first, then DPD classic)
    einat reverse-SNAT (DNAT) -> DPD return hit -> redirect to br-lan
```

- `dpd_nat` is an **admission gate, not a rewrite**. It holds the origin
  binding `(internal addr, port, proto) -> (external addr, port)` mirrored from
  einat by `dpd-einat-sync`. A forward flow is learned and taken over only when
  a binding exists; einat's egress hook does the actual SNAT, exactly as it does
  on the slow path, so there is no double NAT.
- `DPD_FLOW_F_NAT` (0x0080) is set on flows whose egress has a learned IPv4
  nexthop. **Only those flows re-check `dpd_nat` on every hit.** The return half
  has no mark and never pays for the lookup.
- A binding that disappears while a flow is live (einat timer or restart) turns
  the next hit into `TC_ACT_UNSPEC` and `ST_NAT_GONE`; the packet returns to the
  stack, einat re-creates or rejects it normally, and DPD learns again later.
- The mirror daemon resolves the maps from the **live programs' `map_ids`**
  (`egress_snat` → `map_binding`, `dpd_fastpath_l2` → `dpd_nat`), not by name:
  after a restart the old maps still exist and a name lookup silently attaches
  to the dead instance. It mirrors only `BINDING_ORIG_DIR_FLAG` entries and
  skips the NAT host's own identity bindings.

## Evidence (ESXi, dpd-test, ABI 16)

The lab's original "client" VM turned out to be on a different L2 segment
(its 192.168.10.1 gateway MAC was not dpd-test's br-lan MAC), which invalidated
the earlier client-side tests. The verified setup is a network namespace client
on a veth dropped into br-lan:

```
ip netns add lc
ip link add vlc type veth peer name vbr
ip link set vlc netns lc
ip link set vbr master br-lan up
ip -n lc addr add 192.168.10.200/24 dev vlc
ip -n lc route add default via 192.168.10.1
```

DPD is attached to `vbr` as a bridge port, so the same path as a physical LAN
client is exercised.

### Download (return half accelerated)

```
QoS shape br-lan/vbr egress: tbf 20mbit
32 MB: real 14.05s          (≈ 20 Mbit, transfer completes)
flow_hit=26774 redirect=26774 nat_gone=0
forward flow: key (192.168.10.200:52356 -> 198.18.0.2:8000),
              egress_ifindex=3 (eth1), flags=0x182 (L2 | NAT | prime=1)
```

### Upload (forward half accelerated + einat SNAT)

```
QoS shape eth1 egress: tbf 20mbit
32 MB from the netns client over `nc` to a Python sink on 198.18.0.2:9000
server wrote: PEER 198.18.0.1 28721 BYTES 33554432
flow_hit 9968 -> 20100, redirect == flow_hit, nat_gone=0
```

`28721` is inside einat's configured external range (20000-29999) and the byte
count is exact, so the accelerated forward packets were SNATed by einat with
correct checksums. Upload and download both cross the fast path in both
directions.

## Limits / next

- einat and fw4 `masquerade` must not be active at the same time. If both are,
  the slow-path packets get an nft-allocated external port while the
  accelerated ones get einat's port, and bulk flows stall after the priming
  window (measured 2026-11-09 while testing with `firewall.@zone[1].masq=1`).
  einat's init already injects the fw4 override that turns masking off; the
  gate only sets `nat_offload` when einat is attached, so the combo is a
  misconfiguration rather than a default.
- `bpf_ct_*` is not used: einat's own `map_ct` remains the only state.
- IPv6 stays routed-only (no NAT66), as before.
- The mirror is a 1 Hz polling daemon. It is control-plane only; the packet
  path never calls userspace. A future event-driven version can use a BPF ring
  buffer, but the current cost is one map iteration per second.
- Stale `dpd_nat` entries are harmless: the flow entry expires on its own TTL
  and the next connection uses a new source port.
