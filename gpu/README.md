# fajita GPU driver — built from Bergamota (pinned), not forked

The Metal → Vulkan → Turnip GPU driver for fajita is **not maintained as a fork**
here. It is built from **[ry-diffusion/Bergamota](https://github.com/ry-diffusion/Bergamota)**'s
`gpu/metal/` tree at a single pinned commit, with one small fajita overlay.

## Why Bergamota is the base

Bergamota is the XNU + iOS port for **beryllium** (Pocophone F1), which is the
**same SoC and GPU as fajita** — SDM845 / Adreno 630. It is the sibling of this
repo, and it has already done the integration we need:

- `gpu/metal/` **is** Chlorophyll (AIR frontend + Mesa/Turnip + the `bgmtl.m`
  Metal device), already wired onto **Turnip** and tested on the A630.
- `gpu/freedreno-sweet/` is the **libdrm stand-in** (the msm-ABI shim) the driver
  runs over.
- `tools/renegade-rs/` is the **PAC-strip / ad-hoc sign** tool the arm64e dylibs
  need.

Forking just the driver (the old `ferdza/chlorophyll@fajita`) meant re-doing
integration Bergamota already carries, and risked the driver drifting from its
shim. Building from one pinned Bergamota commit **co-versions the driver, the
shim and renegade** from the same tree — no drift.

> The GPU *driver source* in Bergamota's `gpu/metal/` was byte-identical to the
> old fork at the time of the switch; the win is structural (one serious
> upstream, co-versioned) and reproducibility, not an immediate code change.
> Bergamota's **kernel** (`xnu/`) is on a newer iOS-18 / xnu-11215 line, so we
> take its **GPU + method + `gpu-abi`**, **not** its kernel — our `xnu/` stays
> fajita / iOS 16.7.

## The only fajita delta

`gpu/ios16-overlay.sh` lowers the iOS deployment target **18.0 → 16.0** across
Bergamota's `gpu/metal/turnip/*.sh`. A min-OS-18 dylib will not load on fajita's
iOS 16.7.16 (dyld rejects it). The GPU is identical, so nothing else changes.

## The pin

`gpu/pin.env` is the single source of truth: the Bergamota repo + commit, the
Mesa tag, and the deployment target. Bump it deliberately (read Bergamota's
changes), then re-run the host-check green before any CI.

## Build

```sh
# 1) Linux compile-check, no Mac, no CI (catches patch rot + compile errors):
gpu/host-check.sh                 # clones Bergamota@pin + Mesa 26.2.5 to $WORK
#    reuse a local tree:  BERGAMOTA=/path/to/bergamota gpu/host-check.sh

# 2) only once host-check is green, build the installable iOS driver on macOS CI:
gh workflow run turnip.yml -R <owner>/ios-fajita
gh run download <id> -R <owner>/ios-fajita -n fajita-turnip-a630-ios16
```

`host-check.sh` covers the AIR frontend + ir3 + Turnip + gallium (the bug-prone
part). It does **not** cover the iOS-only `bgmtl.m` / `chl_vk.c` / arm64e link —
those need the macOS CI (`.github/workflows/turnip.yml`).

## Install & boot-args

See [`../docs/gpu-turnip-bringup.md`](../docs/gpu-turnip-bringup.md). The fajita
kernel is already Turnip-ready (all selectors the shim uses, plus `0200`'s
`MSM_PARAM`s); recovery/HUPCF stay **off** (`gpurecover=0 gpuhupcf=0`).
