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
  implementation packages; they do not ship a second copy of the daemon, init
  script or UCI defaults.
- Each meta package adds only its own uci-defaults script plus the shared
  keep-settings helper described below.
- Existing UCI names are not renamed. A future rename needs a uci-defaults
  migration, not a silent switch.
- Keep `router-acl` at pref 90 and `dpd-fastpath` at pref 100; a third classic
  filter after 100 is refused by the chain guard.

## Keep-settings upgrade

An in-place upgrade must keep the user's configuration. The meta packages
therefore never rename, rewrite or copy a UCI file:

| Meta package | UCI file kept | Owner |
|---|---|---|
| `dpd-acl` | `/etc/config/router_acl` | `router-acl` |
| `dpd-qos` | `/etc/config/router_qos` | `router-qos` |
| `dpd-mwan` | `/etc/config/ebpf_mwan` | `dpd-fastpath` |

Each meta package installs `/etc/uci-defaults/90-dpd-<name>-keep-settings`.
The script is idempotent and only acts when the legacy file exists:

- the existing config is read, never written;
- a marker is created or kept at `/etc/dpd/keep-settings/dpd-<name>.<uci>`,
  containing the package, implementation and config path;
- one line is logged through `logger -t dpd`, e.g.
  `dpd-acl: keeping legacy UCI /etc/config/router_acl (implementation router-acl)`;
- if the expected file is absent but an older spelling exists
  (`dpd_acl`/`acl`, `dpd_qos`/`qos`, `dpd_mwan`/`mwan`), it is left untouched.

The shared helper `/usr/lib/dpd/keep-settings.sh` protects the implementation
configs `router_acl`, `router_qos`, `ebpf_mwan`, `dpd_fastpath`, `einat`,
`honk` and `dpd_napi`:

```sh
/usr/lib/dpd/keep-settings.sh list       # protected files
/usr/lib/dpd/keep-settings.sh snapshot   # record which exist now
/usr/lib/dpd/keep-settings.sh check      # non-zero if a recorded file vanished
```

The baseline lives in `/etc/dpd/keep-settings/state`. A package postinst and
the uci-defaults script can call `check`; the uci-defaults script takes a new
snapshot only when the check passes, so a missing file is not silently
forgotten. The first run on a system without a baseline only prints a notice
and succeeds. After intentionally removing a plugin, run `snapshot` once to
reset the baseline; otherwise `check` keeps reporting its config as missing.

After an upgrade, verify (or call from a postinst):

```sh
/usr/lib/dpd/keep-settings.sh check
echo $?                                  # 0 = all protected configs present
ls -l /etc/dpd/keep-settings/            # markers + state
```

`uci show router_acl` (and the equivalent `router_qos` / `ebpf_mwan`) must show
the same sections as before the upgrade. Nothing in this flow edits those
files, so a difference points at the package manager or the user, not at the
plugin meta package.
