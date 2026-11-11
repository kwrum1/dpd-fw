# packaging/ — the tree the firmware CI consumes

The firmware repository no longer keeps a copy of the DPD sources. It clones
this `arm` branch at build time and copies

```
packaging/router-dataplane/{src,files}   ->  ebpf/router-dataplane/{src,files}
packaging/dpdfwd/{src,files}             ->  ebpf/dpdfwd/{src,files}
```

so `main` remains the single source of truth and the CI repository stays a pile
of Makefiles and workflows.

## Why a branch

The firmware packages expect the upstream layout (`src/` + `files/` next to the
Makefile). This branch is the published, package-shaped snapshot of `main`. It
is generated, never edited by hand:

```sh
git checkout arm
sh packaging/sync.sh
git add -A packaging
git commit -m "arm: sync packaging"
git push origin arm
```

## Pinning

The firmware build pins the `arm` tip by commit SHA, so a rebuild is
reproducible and a silent branch move cannot change an image. Update the SHA in
the two firmware Makefiles (`ebpf/router-dataplane`, `ebpf/dpdfwd`) after
pushing a new `arm` commit; `Scripts/Fetch-DPD.sh` prints the SHA it used, and
the image provenance records it.
