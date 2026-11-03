#!/bin/bash
# SPDX-License-Identifier: MIT
#
# ios16-overlay.sh - the ENTIRE fajita delta to Bergamota's GPU driver.
#
# Bergamota targets beryllium on a newer iOS line and builds every dylib at
# -miphoneos-version-min=18.0. A min-OS-18 dylib will not load on fajita's iOS
# 16.7.16 (dyld rejects it). This lowers the deployment target to 16.0 across
# Bergamota's gpu/metal build scripts. That is the only source change fajita
# needs: the GPU is the same Adreno 630 / SDM845, so the driver is unchanged.
#
# Usage:  gpu/ios16-overlay.sh <path-to-bergamota-checkout>
set -euo pipefail

BERGA="${1:?usage: ios16-overlay.sh <bergamota-checkout>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/pin.env"
TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"

METAL="$BERGA/gpu/metal"
[ -d "$METAL/turnip" ] || { echo "!! $METAL/turnip not found - wrong Bergamota path?"; exit 1; }

echo ">> lowering iOS deployment target 18.0 -> $TARGET in $METAL/turnip"
changed=0
for f in "$METAL"/turnip/*.sh; do
  [ -f "$f" ] || continue
  if grep -q "version-min=18\.0" "$f"; then
    sed -i "s/version-min=18\.0/version-min=$TARGET/g" "$f"
    echo "   patched $(basename "$f")"
    changed=$((changed+1))
  fi
done
[ "$changed" -gt 0 ] || echo "   (nothing matched 18.0 - Bergamota may have changed; verify the pin)"
echo "== overlay applied ($changed file(s)) =="
