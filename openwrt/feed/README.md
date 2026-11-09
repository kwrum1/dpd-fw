# Consuming dpd-fw as an OpenWrt feed

`kwrum1/dpd-fw` is organised by layer (`bpf/`, `plugins/`, `userspace/`,
`openwrt/`), not as a flat feed. `scripts/feeds` only looks for a `Makefile`
in the **direct children** of a feed root, so a feed pointed at the repository
root finds no packages. Pick one of the three ways below; they all end with
the same package directories available in `make menuconfig`.

## Option A - `src-link` over a generated index (recommended)

`scripts/feed-index.sh` creates the missing flat level as symlinks, named by
`PKG_NAME`, in a directory OpenWrt can use as a feed:

```sh
# once, or again after adding/renaming a package directory
sh scripts/feed-index.sh -o /srv/openwrt/feed/dpd-fw

cd /srv/openwrt
echo 'src-link dpd-fw /srv/openwrt/feed/dpd-fw' >> feeds.conf.default
./scripts/feeds update dpd-fw
./scripts/feeds install -a -p dpd-fw
```

The index contains symlinks back into the checkout, so edits to a package are
picked up by the next `make` without another `feeds update`. `feeds update`
still has to run once so the feed index is built. The generated directory is
gitignored; delete it at any time. The links are absolute, so regenerate the
index on every build host (or use a path that exists on all of them).

Notes:

- `feeds.conf` splits fields on whitespace, so the feed path must not contain
  spaces.
- Use an absolute path for `src-link`; a relative one is resolved from the
  OpenWrt tree's `feeds/` directory, not from the tree root.
- Install a single package with `./scripts/feeds install dpd-fastpath`
  instead of `-a -p dpd-fw`.
- The script also works on a plain (non-git) source tarball.

## Option B - per-package symlinks (no feed at all)

If you only need one or two packages, link the directories into `package/`.
This bypasses `scripts/feeds` entirely:

```sh
cd /srv/openwrt
mkdir -p package/dpd-fw
ln -s /path/to/dpd-fw/bpf/core              package/dpd-fw/dpd-fastpath
ln -s /path/to/dpd-fw/plugins/dpd-honk      package/dpd-fw/dpd-honk
ln -s /path/to/dpd-fw/openwrt/luci-app-dpd  package/dpd-fw/luci-app-dpd
```

Name the links after `PKG_NAME` (see the table below), not after the source
directory: `plugins/dpd-acl` and `openwrt/meta/dpd-acl` would otherwise collide.
`scripts/feed-index.sh --print` prints the `PKG_NAME<TAB>directory` pairs.

## Option C - `src-git`

```sh
cd /srv/openwrt
echo 'src-git dpd-fw https://github.com/kwrum1/dpd-fw.git;main' >> feeds.conf.default
./scripts/feeds update dpd-fw
```

This is the right form for CI or a build server, but it needs a branch **whose
root is already a flat feed** (one directory per package). The `main` branch of
this repository is not one: its root is `bpf/`, `plugins/`, `userspace/`,
`openwrt/`. Point `src-git` at a published feed branch built from
`scripts/feed-index.sh` (or at a fork that mirrors the package directories),
or use Option A against a checkout of `main`.

## Package directories

| Source directory | `PKG_NAME` | What it is |
|---|---|---|
| `bpf/core` | `dpd-fastpath` | the TC eBPF datapath, `dpdctl` and the init scripts |
| `userspace/dpd-napi` | `dpd-napi` | NAPI/IRQ/GRO/GSO/qdisc/RSS tuning |
| `plugins/dpd-acl` | `router-acl` | TC-layer ACL implementation |
| `plugins/dpd-einat` | `einat-ebpf` | full-cone NAT provider (from upstream, wrapper package) |
| `plugins/dpd-einat-sync` | `dpd-einat-sync` | mirrors einat bindings into `dpd_nat` |
| `plugins/dpd-honk` | `dpd-honk` | transparent-proxy bridge (GPL-3.0, separate process) |
| `plugins/dpd-observe` | `dpd-observe` | flow/gate/status telemetry |
| `plugins/dpd-qos` | `router-qos` | DSCP/CAKE/SQM fast path |
| `plugins/dpd-tuning` | `router-tuning` | kernel/IRQ/network sysctl tuning |
| `openwrt/meta/dpd-acl` | `dpd-acl` | meta package keeping the old DPD name |
| `openwrt/meta/dpd-mwan` | `dpd-mwan` | multi-WAN meta package |
| `openwrt/meta/dpd-qos` | `dpd-qos` | QoS meta package |
| `openwrt/luci-app-dpd` | `luci-app-dpd` | LuCI app |

`plugins/dpd-mwan` is a placeholder without a `Makefile` today and is skipped by
the index generator. The meta packages pull the implementation packages; a
normal image installs `luci-app-dpd` plus the meta packages it wants.

After `feeds install`, the packages appear under **Network -> DPD** (the
`DPD` submenu comes from the meta packages) and in `.config` as
`CONFIG_PACKAGE_<name>=y`.

## ABI caveat: in-place upgrades drop pinned maps

The BPF object and `dpdctl` share the structures in
`bpf/core/src/dpd_common.h`. `DPD_ABI_VERSION` stamps their layout, and the map
value sizes are part of the pinned-map ABI in `/sys/fs/bpf/dpd_*`.

libbpf can only reuse a pinned map whose key/value sizes and flags match the
new object. When an upgrade changes the ABI, the old pins from the previous
package are **stale**: the new object cannot reuse them and `tc filter add`
fails with a map/pin error that does not name the real cause. `dpdctl` on an
old pin would also decode the wrong layout.

The package handles the normal case:

- it installs the ABI it was built with in `/usr/lib/dpd/abi`;
- `dpd_pins_compat()` in `/usr/libexec/dpd-fastpath.sh` compares that with
  `dpdctl abi` when the service starts and removes the stale pins when they
  differ;
- the pins are dropped the next time the init script starts. An upgrade that
  restarts the enabled, running service does it immediately; a service that was
  stopped keeps its old pins until you start it.

Keep these points in mind:

- Upgrade `dpd-fastpath` as one unit (object + `dpdctl` + init scripts are all
  in that package). Do not mix a hand-copied object with an older `dpdctl`.
- If the service was stopped during the upgrade, the old pins stay in bpffs
  until the next start. That is harmless, and the start cleans them up.
- If the start still fails on a pin (for example because a map added after the
  cleanup list was written is still there), remove **every** DPD pin, not just
  the logged ones, and start again:
  ```sh
  rm -f /sys/fs/bpf/dpd_*
  /etc/init.d/dpd-fastpath restart
  ```
  A reboot has the same effect (bpffs is RAM).
- Never restore or copy pins from a backup; they do not survive a reboot and
  they belong to one ABI and one running object.
- Check the stamp after an upgrade: `cat /usr/lib/dpd/abi` and `dpdctl abi`
  must print the same number. On a build host,
  `sh scripts/verify-abi.sh --installed /usr/lib/dpd/abi` checks the tree
  against an installed stamp.
- A sysupgrade that keeps settings is not affected by the pin issue (pins are
  not in `/etc`), but the new image must still ship an object and `dpdctl`
  built from the same `DPD_ABI_VERSION`; see the "ABI" job in
  `.github/workflows/ci.yml`.
