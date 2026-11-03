# Documentation — index

Entry point for the project documentation (iOS 16 userland + Metal/Adreno 630
rendering on the OnePlus 6T, `fajita`).

## Start here

- **[../README.md](../README.md)** — overview, what works, build & flash, repo
  layout. **Read this first.**
- **[../PORTING.md](../PORTING.md)** — hardware notes and the bring-up plan.
- **[../AGENTS.md](../AGENTS.md)** — working rules (handoff, commits, safety of
  destructive steps).
- **[coding-practices.md](coding-practices.md)** — the blunt "pense bête"
  rulebook: don't guess constants, read before theorising, fail closed, prove
  the compile locally, admit wrongness fast. Each rule is a mistake we already
  made.

## Overview

- **[architecture.md](architecture.md)** — **the major components**: boot chain
  (shim / ADT / payload), XNU port, UFS storage, display, GPU kernel core, IOKit
  user client, present path, Metal userspace driver, input, logging, security.

## GPU / Metal (current focus)

- **[../gpu/README.md](../gpu/README.md)** — **how the GPU driver is built: from
  ry-diffusion/Bergamota's `gpu/metal/` at a pinned commit (not a fork)**, with
  one fajita overlay (iOS target 18→16). The pin (`../gpu/pin.env`), the overlay,
  the Linux `host-check.sh` and the macOS CI (`turnip.yml`) all live under
  [`../gpu/`](../gpu/README.md). Read this before touching the driver build.
- **[gpu-progress.md](gpu-progress.md)** — living status log: the 0193–0198 patch
  series (what each does and its state), findings, open questions to confirm on
  device, the long-term direction, and the **device test log**.
- **[gpu-turnip-bringup.md](gpu-turnip-bringup.md)** — **the Turnip (Vulkan) Metal
  driver bring-up recipe**: the driver is done on `ferdza/chlorophyll@ios26`, the
  fajita kernel is ready (selectors + `0200` params); this is the macOS build +
  device install + boot-args to run it on fajita.
- **[gpu-audit-2026-11.md](gpu-audit-2026-11.md)** — **step-back audit (2026-11-03)**
  after the 0199 panic. Conclusions (see "What still holds"): **HUPCF (0199)
  caused the panic — gate it off**; the hang is a **shader faulting on a garbage
  descriptor** (not a CPU-cache bug — the first-draft coherency theory is
  withdrawn, the client already maps write-combined); recovery (0197) is the
  wrong mechanism for a630+GMU. Comparison to UniXNU/msm. **Read this before
  adding more GPU patches.**
- **[gpu-reference-audit.md](gpu-reference-audit.md)** — line-level comparison of
  our code against the reference projects: prioritized findings, what is already
  addressed, and what remains.
- **[gpu-multiring-design.md](gpu-multiring-design.md)** — design for the
  long-term performance direction: concurrent submission / multi-ring (a safe
  software stage, then optional hardware preemption), with the a630 risk
  documented.

## Connectivity (research)

- **[connectivity-research.md](connectivity-research.md)** — Wi-Fi, Bluetooth and
  USB: the hardware (WCN3990, DWC3), what already works (USB device + CDC-ECM),
  the XNU path for each, references, and a suggested priority order. Research
  only, not yet implemented.

## Research

- **[research-and-similar-projects.md](research-and-similar-projects.md)** — the
  landscape (ios-sweet, Bergamota/Chlorophyll, HackiOS, msm/freedreno,
  UniXNU/Adreno740, Snapintosh) and what we take from each.

## Deep reference & history

- **[../NOTES-FAJITA.md](../NOTES-FAJITA.md)** — the exhaustive working handoff:
  state, registers, traps, numbers, next steps (large file).
- **[../NOTES.md](../NOTES.md)** — notes from the ios-sweet base.
- **IOS16_README.md** — history of the iOS 16 base (if present).

## Key tools

- `tools/xnu-cc.py` — **local compile check** of a kernel patch (seconds, no
  macOS) before spending a CI run. See [gpu-progress.md](gpu-progress.md).
- `tools/build-fajita.sh` — builds the boot image (kernel + ADT + payload).
- `tools/check-hunk-counts.py` — verifies every patch still applies in order.
- `tools/sweet-log-pull.sh` / `tools/sweet-log.py` — pull and filter the device log.

---

**Status (2026-11-03):** the iOS UI is rendered by the GPU through Metal. Current
work is **performance** (0195 write-combined buffers, 0198 asynchronous submit)
and **freezes**. Device testing (gpu-metal8) root-caused the freeze to a **GPU
IOMMU page fault** that wedged the GPU because the SMMU context lacked **HUPCF**
(continue-after-fault) → **0199** sets it (matching UniXNU). The bare-RBBM
recovery (0197) does **not** revive a630+GMU on device; a GMU-mediated reset is
deferred ("B"), as is the root cause of the wild fault address ("C"). Details and
the device test log in [gpu-progress.md](gpu-progress.md).
