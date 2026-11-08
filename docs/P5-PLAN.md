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
- [x] upgrade drill: local `.apk` install, services restarted, status/gate
      survived; `PASS: abi=15 attached=true mode=observe`.
- [x] local build: the four packages compiled with the local 25.12.4 SDK and
      installed on the ESXi `dpd-test` VM. Full-image build is the next CI run.

## Verification (2026-11-08)

```
dpd-honk-0.1.0-r1.apk          1892
dpd-napi-0.1.0-r1.apk          1811
dpd-observe-0.1.0-r1.apk       1443
luci-app-dpd-0.1.0-r1.apk      3272
```

- `apk info -e` reports all four installed;
- `ubus call dpd status` returns `at`, `dpd.abi=15`, `gate.effective`;
- `/var/run/dpd/{observe,honk,napi}.json` exist;
- upgrade drill: `PASS: abi=15 attached=true mode=observe`.

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
