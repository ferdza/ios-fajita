# Documentation — index

Entry point for the project documentation (iOS 16 userland + Metal/Adreno 630
rendering on the OnePlus 6T, `fajita`).

## Start here

- **[../README.md](../README.md)** — overview, what works, build & flash, repo
  layout. **Read this first.**
- **[../PORTING.md](../PORTING.md)** — hardware notes and the bring-up plan.
- **[../AGENTS.md](../AGENTS.md)** — working rules (handoff, commits, safety of
  destructive steps).

## Overview

- **[architecture.md](architecture.md)** — **the major components**: boot chain
  (shim / ADT / payload), XNU port, UFS storage, display, GPU kernel core, IOKit
  user client, present path, Metal userspace driver, input, logging, security.

## GPU / Metal (current focus)

- **[gpu-progress.md](gpu-progress.md)** — living status log: the 0193–0198 patch
  series (what each does and its state), findings, open questions to confirm on
  device, the long-term direction, and the **device test log**.
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

**Status (2026-11-02):** the iOS UI is rendered by the GPU through Metal. Current
work is **performance** (0195 write-combined buffers, 0198 asynchronous submit)
and **freezes** (0196 bounded ring-drain wait, 0197 GPU hang recovery, on by
default). The 0193–0198 kernel is CI run `41540055327`. Details in
[gpu-progress.md](gpu-progress.md).
