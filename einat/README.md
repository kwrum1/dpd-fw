# einat build (part of the DPD dataplane)

einat is the full-cone NAT engine DPD ships: it owns SNAT/DNAT on the TC hooks,
DPD owns forwarding. This directory builds it from upstream source and
publishes the binaries under the fixed release tag `einat-p2`.

```
einat/
  pins.env                 upstream repo + commit, asset prefix, release tag
  patches/einat-perf.py    p1: one less L2/L3 parse per packet per direction
  patches/einat-perf-p2.py p2: dest_config fast path + established-TCP CT path
  tests/einat-e2e-nat.sh   netns functional check (EIM/EIF, ICMP, 20 MB TCP)
```

`.github/workflows/einat.yml` runs the netns check first, then builds
x86_64 and aarch64 with upstream's `static` Nix preset (no NAT66) and updates
the `einat-p2` release with:

```
einat-p2-x86_64-unknown-linux-musl
einat-p2-aarch64-unknown-linux-musl
SHA256SUMS
```

## Consumers

The firmware repository's `ebpf/einat-ebpf/Makefile` pins

```
https://github.com/kwrum1/dpd-fw/releases/download/einat-p2
```

with the sha256 of each asset. After a rebuild, update the two hash lines
there and bump `PKG_RELEASE`. `provenance-<CONFIG>.txt` in the firmware
release records which asset was shipped.

## Offline builds

The firmware build reads the asset from OpenWrt's `dl/` directory. Once
downloaded (and while the CI `dl` cache is warm) no network access is needed;
for a fully offline build, drop the two files into `wrt/dl/` before `make`.

## Bumping

1. Bump `EINAT_COMMIT` in `pins.env`.
2. Run the patch scripts locally (`python3 patches/einat-perf.py <tree>`); both
   fail loudly if the anchors moved, which is the only thing to fix.
3. Push: the `einat` workflow runs the netns check and rebuilds the release.
4. Update the hashes in the firmware's `ebpf/einat-ebpf/Makefile`.
