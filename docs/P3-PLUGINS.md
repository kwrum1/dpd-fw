# P3 — ACL / QoS / multi-WAN plugin mapping

P3 keeps the existing, working implementations and exposes them under the DPD
plugin names. No datapath rewrite is needed; the goal is stable UCI/LuCI and a
single dependency story.

| DPD plugin | Implementation | UCI | LuCI |
|---|---|---|---|
| `dpd-acl` | `router-acl` (TC pref 90, five-tuple guard) | `router_acl` | Network → 防火墙 |
| `dpd-qos` | `router-qos` (one root CAKE/fq_codel qdisc on WAN) | `router_qos` | Network → QoS (existing) |
| `dpd-mwan` | `dpd-fastpath`'s `ebpf-mwan` script + `ebpf_mwan` UCI | `ebpf_mwan` | Network → 多 WAN |
| `dpd-honk` | honk (TCX proxy) | `honk` | Network → 代理 |
| `dpd-einat` | einat (full-cone NAT44) | `einat` | none (gate/status) |
| `dpd-observe` | status composer | `dpd_observe` | DPD 插件页 |
| `dpd-napi` | NAPI/queue tuning | `dpd_napi` | DPD 插件页 |

## Ordering

```
honk TCX (proxy) -> einat TCX (NAT) -> router-acl classic pref 90
                    -> dpd-fastpath classic pref 100
```

`dpd-fastpath` stays classic so it runs after the TCX interception layer. The
bridge-port attach fix (`dpd_attach_if` walks `brif/*`) belongs to this order:
the LAN port is where the forwarded frame first appears.

## Compatibility

- Meta packages `dpd-acl`, `dpd-qos`, `dpd-mwan` only depend on the existing
  implementation packages; they install no duplicate files.
- Existing UCI names are not renamed. A future rename needs a uci-defaults
  migration, not a silent switch.
- Keep `router-acl` at pref 90 and `dpd-fastpath` at pref 100; a third classic
  filter after 100 is refused by the chain guard.
