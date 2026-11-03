# Turnip (Vulkan) Metal bring-up on fajita — build & install recipe

The GPU driver moves from gallium-freedreno (the old `libbgair`, AIR→NIR→ir3→GL)
to **Turnip** (Vulkan), the path every working Metal-on-Adreno project uses and
the one upstream Chlorophyll already proved on the A630. See
[`gpu-audit-2026-11.md`](gpu-audit-2026-11.md) for why.

**Status (2026-11-03):**
- Driver: **done upstream and on your GitHub** — `ferdza/chlorophyll`. The iOS-26
  line is branch `ios26` (`d3cb665`); the **iOS-16.7 adaptation for fajita is
  branch `fajita`** (lower deployment target + CI + the host compile-check).
  Turnip runtime `air/chl_vk.c` (~100 KB), AIR→NIR for Vulkan `air/air_nir_vk.c`,
  Metal device `src/bgmtl.m`, build scripts under `turnip/`. `tu_smoke` and the
  Metal probes pass on the A630 (Bergamota boot-54/55 logs).
- iOS 16.7 fix (branch `fajita`): `ios26` built everything at
  `-miphoneos-version-min=18.0`, which **will not load on iOS 16.7** (dyld
  rejects a min-OS-18 dylib). Lowered to **16.0** across the build/test scripts.
  The iOS-26 specifics in `bgmtl.m` are inert on 16.7 (they only answer the
  `supportsMTL4*` queries with NO; no iOS-18-only API is called).
- Kernel (fajita): **ready** — all selectors the Turnip shim uses are
  implemented, and `0200-fajita-gpu-turnip-params.patch` exposes the `MSM_PARAM`s
  Turnip queries (HIGHEST_BANK_BIT=15, UBWC_SWIZZLE=6, MACROTILE_MODE=0). Syncobjs
  are emulated in the `sweet_drm` shim, so no further kernel change is needed.
- Remaining: build the iOS dylibs (macOS-only: `clang -arch arm64e`,
  `-framework IOKit`) and install on the device. **No Mac? Build on GitHub CI**
  (below). Validate locally first with the **host compile-check** (below) so CI
  runs are not wasted.

## Build via GitHub CI — no Mac needed

`ferdza/chlorophyll` has a macOS Actions workflow, **`.github/workflows/turnip.yml`**
(listed on `main`, run it against `fajita`). It checks out Bergamota for the
`freedreno-sweet` libdrm stand-in, builds the `renegade` PAC-strip tool, lowers
the shim's target to 16.0, clones Mesa 26.2.5, runs `turnip/build-turnip.sh` +
`build-metal.sh`, and uploads the driver (`libchlorophyll.dylib`, `libdrm.2.dylib`,
`bgmtl.o`, metallibs) as an artifact you download and install.

```sh
gh workflow run turnip.yml -R ferdza/chlorophyll --ref fajita
gh run watch <id> -R ferdza/chlorophyll
gh run download <id> -R ferdza/chlorophyll -n chlorophyll-turnip-a630-ios16
```

macOS runner minutes are ~10x, so it is `workflow_dispatch` only. It is a young
workflow and may need a debug run or two (the first failed on the renegade step,
now fixed).

## Local compile-check — no Mac, no CI (save minutes)

**`turnip/host-check.sh`** in `ferdza/chlorophyll` compiles the bug-prone part of
the port on a plain **Linux** host (Mesa 26.2.5 + our patches + the AIR frontend +
ir3 + Turnip + gallium freedreno) in minutes, catching broken patches and compile
errors before a macOS CI run — the Chlorophyll analogue of the kernel's
`tools/xnu-cc.py`. Proven green. It does **not** cover the iOS-only `bgmtl.m` /
`chl_vk.c` / arm64e link, which still need the Mac build or CI.

```sh
# Linux deps: meson ninja python3-mako flex bison glslang-tools spirv-tools \
#             libdrm-dev libzstd-dev zlib1g-dev pkg-config
turnip/host-check.sh      # clones Mesa 26.2.5 on first run; PASS/FAIL in minutes
```

Workflow: edit the driver → `host-check.sh` until green → only then dispatch the
macOS CI → download the artifact → install on the device.

## What runs where

```
iOS app / CoreAnimation  ──AIR──►  Chlorophyll (ferdza/chlorophyll@ios26)
                                     ├─ air/  AIR → NIR  (air_nir_vk.c)
                                     ├─ Turnip (Mesa 25.0.7 + turnip-ios.patch)  NIR → a630
                                     └─ src/bgmtl.m  MTLDevice/encoder → VkCommandBuffer
                                          │ libdrm stand-in (Bergamota freedreno-sweet/sweet_drm.c)
                                          ▼  IOConnect… (msm ABI, syncobjs emulated)
                                   fajita kernel: SweetAdrenoUserClient + sweet_gpu.c (reused)
```

## Build (macOS host with the iOS arm64e cross setup)

Prerequisites (from Chlorophyll `turnip/` and Bergamota `gpu/metal`):
`brew install glslang`; a Bergamota checkout (for the `freedreno-sweet` libdrm
stand-in and the Mesa patches); the iOS SDK cross file.

```sh
# Chlorophyll submodules (Mesa 25.0.7 + libdrm 2.4.124) must be checked out:
git -C chlorophyll submodule update --init --recursive

export GPU_METAL_WORK=~/work-chlorophyll          # scratch build tree
export BERGAMOTA_GPU=<a Bergamota checkout>/gpu   # freedreno-sweet + patches; WITHOUT it pacstrip is skipped and the dylibs SIGILL on the phone

# 1) Turnip for a630 (separate Gallium-free tree):
chlorophyll/turnip/build-turnip.sh                # applies patches/turnip-ios.patch, builds Mesa Turnip arm64e
# 2) the Metal driver on Turnip:
chlorophyll/turnip/build-metal.sh                 # libbgair.dylib (Turnip) + the backboardd inject
# 3) sanity on the phone, nothing installed system-wide:
chlorophyll/turnip/build-test.sh                  # tu_smoke, chl_test, bgmtl probes -> /var/root/turnip-test
```

## Install on fajita (confirm each destructive step with the user)

- `libbgair.dylib` (Turnip) → `/usr/local/lib/bgmtl/libbgair.dylib` (keep the
  previous one as `…/libbgair.dylib.prev-<sha>`).
- the backboardd inject → as Bergamota's `inject` installs it; it takes effect at
  backboardd's **next start**.
- Kill switches while testing: `bgmtl-bb.off` and the per-process
  `bgmtl.off.<bundleid>` gate backboardd/apps onto the driver; move them aside
  right before the boot you want to test on Turnip.
- Texture pool: `BGMTL_TEXPOOL_MB=192` (set by the inject) — a too-small pool
  makes backboardd allocate/free GPU memory every frame.

## Boot-args (fajita kernel)

Keep the current GPU args; recovery/HUPCF stay **off** (they were for the gallium
hang path and 0199 panicked): add `gpurecover=0 gpuhupcf=0`. Turnip's own
cache/barrier handling replaces the kernel-side experiments. `sweetfb_hz=60` is
worth trying once the encoder is smooth (the panel cap was the last limiter in
Bergamota's measurements).

## Known first-boot issue to expect (and the fix)

The first command buffer can take tens of seconds — **pipeline creation happens
under `bg_lock`** while CoreAnimation compiles its startup shaders (this is the
"Apple logo for too long"). Upstream's plan: move pipeline creation out of
`bg_lock` and add an AIR→NIR cache. Until then, SpringBoard may need one restart
after the logo.

## Pointers

- Driver + full port write-up: `ferdza/chlorophyll@ios26`, `docs/TURNIP.md`
  (phases T1–T7, phone results), `docs/FIXES.md`.
- Shim / libdrm stand-in: Bergamota `gpu/freedreno-sweet/sweet_drm.c`.
- Native kernel backend (optional, later): UniXNU `tu_knl_darwin.cc` is the
  template for a `tu_knl_sweet.cc` that calls `SweetAdrenoUserClient` directly.
