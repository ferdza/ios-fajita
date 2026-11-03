#!/bin/bash
# SPDX-License-Identifier: MIT
#
# host-check.sh - compile-check the fajita GPU driver WITHOUT a Mac and WITHOUT
# a CI run, building from the PINNED Bergamota tree (gpu/pin.env).
#
# The iOS build needs the macOS toolchain and a macOS CI run costs ~10x minutes.
# But the bug-prone part of the driver - the AIR frontend (gpu/metal/air), the
# ir3 patches, Turnip, and the gallium freedreno path - is ordinary Mesa C/C++
# that compiles on Linux. This builds it on the host so a broken patch or a
# compile error is caught in seconds here instead of after a 20-minute macOS
# runner. Same idea as the kernel's tools/xnu-cc.py.
#
# It does NOT cover the iOS-only pieces: gpu/metal/src/bgmtl.m (Metal API),
# chl_vk.c (the iOS runtime/encoder), the arm64e cross link, renegade/PAC-strip
# and codesign. Those still need the macOS CI (.github/workflows/turnip.yml).
#
# Usage:
#   gpu/host-check.sh                     # clones Bergamota@pin + Mesa to $WORK
#   WORK=/scratch gpu/host-check.sh       # override the work dir
#   BERGAMOTA=/path/to/checkout gpu/host-check.sh   # reuse a local Bergamota tree
#
# Linux deps (Debian/Ubuntu): meson ninja-build python3-mako flex bison
#   glslang-tools spirv-tools libdrm-dev libzstd-dev zlib1g-dev pkg-config
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/pin.env"
WORK="${WORK:-$HOME/fajita-gpu-hostcheck}"
MESA="$WORK/${MESA_TAG}"
PATCHES=(air-frontend ir3-round-default ir3-ssbo-subdword ir3-context-error-return ir3-disk-cache-macho turnip-ios)

mkdir -p "$WORK"

# 1) the pinned Bergamota tree (source of the driver, patches and air/)
BERGA="${BERGAMOTA:-$WORK/bergamota}"
if [ -z "${BERGAMOTA:-}" ]; then
  if [ ! -d "$BERGA/.git" ]; then
    echo ">> cloning Bergamota @ $BERGAMOTA_REF"
    git clone -q "$BERGAMOTA_REPO" "$BERGA"
  fi
  git -C "$BERGA" fetch -q origin "$BERGAMOTA_REF" 2>/dev/null || git -C "$BERGA" fetch -q origin
  git -C "$BERGA" checkout -q "$BERGAMOTA_REF"
fi
METAL="$BERGA/gpu/metal"
[ -d "$METAL/patches/mesa-26.2" ] || { echo "!! $METAL/patches/mesa-26.2 missing - bad Bergamota pin"; exit 1; }

# 2) Mesa at the pinned tag
if [ ! -d "$MESA/.git" ]; then
  echo ">> cloning $MESA_TAG (shallow)"
  git clone -q --depth 1 --branch "$MESA_TAG" https://gitlab.freedesktop.org/mesa/mesa.git "$MESA"
fi
cd "$MESA"
echo ">> resetting Mesa to a clean $MESA_TAG"
git clean -qxfd; git reset -q --hard HEAD

echo ">> git apply --check (catches patch rot against $MESA_TAG)"
fail=0
for p in "${PATCHES[@]}"; do
  if git apply --check "$METAL/patches/mesa-26.2/$p.patch" 2>/tmp/hc.err; then
    echo "   OK    $p"
  else
    echo "   FAIL  $p -> $(head -1 /tmp/hc.err)"; fail=1
  fi
done
[ "$fail" = 0 ] || { echo "!! a patch no longer applies - fix it (or the pin) before any CI run"; exit 2; }

echo ">> applying patches + symlinking gpu/metal/air from the pinned tree"
for p in "${PATCHES[@]}"; do git apply "$METAL/patches/mesa-26.2/$p.patch"; done
mkdir -p src/compiler/air
for f in "$METAL"/air/*; do ln -sf "$f" "src/compiler/air/$(basename "$f")"; done

echo ">> meson setup (Linux, both freedreno drivers)"
rm -rf build-host
meson setup build-host \
  -Dvulkan-drivers=freedreno -Dgallium-drivers=freedreno -Dfreedreno-kmds=msm \
  -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled \
  -Dvideo-codecs= -Dbuildtype=debugoptimized >/tmp/hc-meson.log 2>&1 \
  || { echo "!! meson setup failed:"; tail -15 /tmp/hc-meson.log; exit 3; }

echo ">> ninja (the compile-check)"
if ninja -C build-host >/tmp/hc-ninja.log 2>&1; then
  echo "== PASS: Bergamota@${BERGAMOTA_REF:0:7} gpu/metal compiles clean on the host =="
  echo "   (iOS-only bgmtl.m / chl_vk.c / arm64e link still need the macOS CI)"
else
  echo "== FAIL: compile errors (fix before spending a macOS CI run) =="
  grep -iE "error:|FAILED:" /tmp/hc-ninja.log | head -30
  exit 4
fi
