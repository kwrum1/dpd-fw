# honk p1 core (dataplane handover)

honk owns the LAN TCX hook for transparent proxying. Upstream's core returns
`TC_ACT_OK` for direct-classified flows, which terminates the TCX chain and
hides those packets from the classic TC chain that DPD uses. This directory
builds a patched core for x86_64/aarch64/armv7 in which direct flows carry
`DIRECT_UNSPEC_MARK` and return `TC_ACT_UNSPEC`, so DPD can take them over.
Proxy/block verdicts stay terminal; NAT stays with einat.

```
honk/
  pins.env                              upstream daeuniverse/honk commit + tag
  patches/honk-direct-unspec.py         the handover patch (anchored)
  patches/honk-core-config-validate.patch  upstream config check
  build-core.sh                         cross-compiles all three arches
```

`.github/workflows/honk-core.yml` runs `build-core.sh` and publishes the
archives plus `generated-stage.mk` under the fixed tag `core-p1`.

## Consumer

The firmware repository (`kwrum1/ebpf-honk-ImmortalWRT-CI`) keeps only a small
source patch for the *package* files and points its Makefile here:

```
https://github.com/kwrum1/dpd-fw/releases/download/core-p1
```

`Scripts/Packages.sh` fetches `generated-stage.mk` and the provenance file from
that release, then `make download` pulls the matching `honk-core-<commit>-p1-<arch>.tar.gz`.
IPQ/MTK images use the stock upstream package and core.

## Bumping

1. Bump `CORE_COMMIT` in `pins.env`, and the same commit in the firmware's
   `patches/honk/apply-makefile.sh` (`CORE=`), because that is what the image
   writes into the package Makefile.
2. Run `python3 honk/patches/honk-direct-unspec.py <honk tree>` locally; it
   fails loudly if the anchors moved. `honk-core-config-validate.patch` is
   applied first and must apply unchanged.
3. Push: `honk-core` rebuilds and republishes `core-p1` (assets carry the new
   commit, `generated-stage.mk` and the provenance file are replaced).
4. The firmware needs no further change: it reads `generated-stage.mk` from the
   fixed tag and the asset names carry the commit.
