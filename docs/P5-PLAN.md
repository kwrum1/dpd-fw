# P5 — plugins, UI and upgrade drill

P5 is the "product face" of DPD-FW: the proxy/NAT/ACL/QoS/MWAN pieces exist as
separate plugins, the UI reads one status document, and an upgrade/rollback
path is tested. It does not change the datapath ABI.

## Definition of done

- [x] `dpd-honk` package: reports honk state, bumps the DPD epoch when the
      honk config changes, never starts/stops honk on its own.
- [x] `dpd-observe` package: writes `/var/run/dpd/observe.json` and exposes
      `ubus dpd status` / `flows` / `plugins`.
- [x] `dpd-napi` package: applies the UCI NAPI/GRO/RPS values to sysfs and
      publishes `/var/run/dpd/napi.json`.
- [x] `luci-app-dpd`: DPD menu, overview page, honk link, flows/gate cards.
- [ ] upgrade drill: keep-settings upgrade, packages reinstall, status/gate
      survived, rollback restores the previous package set.
- [ ] local build: `dpd-fw` packages compile against 6.18 and the ESXi lab
      boots the resulting image.

## P2 dependency

The lab found that taking over LAN->WAN before einat's SNAT breaks bulk TCP
(the server sees the LAN source address). P2's UFS+NAT merge is therefore a
hard dependency for *forward-path* acceleration with NAT. P5's UI/plugins are
independent and are delivered first; the report must state the P2 gap rather
than hide it.

## Non-goals

- Replacing honk's proxy datapath.
- Renaming the existing `luci-app-ebpf` package; `luci-app-dpd` is additive and
  depends on it.
- Per-packet plugin traversal; plugins are control-plane only.
