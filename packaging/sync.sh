#!/bin/sh
# Regenerate packaging/ from the canonical sources on this branch.
#
# The firmware CI does not keep a copy of the dataplane sources: it clones this
# branch and copies packaging/<pkg>/{src,files} into its package directories.
# Run this after changing bpf/core or userspace/dpdfwd, then commit:
#
#   git checkout arm
#   sh packaging/sync.sh
#   git add -A packaging && git commit -m "arm: sync packaging"
#   git push origin arm
set -eu
cd "$(dirname "$0")/.."

rm -rf packaging/router-dataplane packaging/dpdfwd
mkdir -p packaging/router-dataplane/src packaging/router-dataplane/files
mkdir -p packaging/dpdfwd/src packaging/dpdfwd/files

cp bpf/core/src/dpdctl.c bpf/core/src/dpd_common.h bpf/core/src/dpd_bpf.h \
   bpf/core/src/dpd_fastpath.bpf.c packaging/router-dataplane/src/
cp bpf/core/files/* packaging/router-dataplane/files/
cp userspace/dpdfwd/src/* packaging/dpdfwd/src/
cp userspace/dpdfwd/files/* packaging/dpdfwd/files/

echo "synced packaging/ from $(git rev-parse --short HEAD) ($(git branch --show-current))"
