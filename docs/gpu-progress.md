# GPU / Metal — progress log and findings

Living working document for GPU acceleration (Adreno 630 / SDM845). For the
exhaustive history (registers, traps) see [`NOTES-FAJITA.md`](../NOTES-FAJITA.md);
for the comparison with the other projects see
[`gpu-reference-audit.md`](gpu-reference-audit.md).

State as of **2026-11-02**. Any "device" line without a date is **not yet verified
on the phone** (observations and assumptions are kept distinct).

---

## Where we are

The **Metal path is functional**: CoreAnimation renders the iOS interface through
the GPU (Chlorophyll = Mesa/freedreno ir3 presented as a Metal driver, with the
kernel-side Bergamota bring-up and the msm-compatible IOKit user client). On
device the UI draws **correctly** (crisp icons, dock, status bar — photo
2026-11-02).

Two problems remained, both addressed by the 0193–0198 series:

- **Low frame rate.** The UI ran at only a few frames per second — a severe
  frame-rate regression caused by cache maintenance and by the submit path
  serializing the CPU behind the GPU.
- **Freezes on a GPU hang.** A 100-second busy-wait with no recovery.

## The GPU patch series (on the device-validated 0193–0194 base)

| Patch | What it does | Risk | State |
| --- | --- | --- | --- |
| 0193 | Aligns surface pitch to 64 (freedreno rejected the icon-mask pitches) | low | ✅ device (rejections 39→2) |
| 0194 | Presents only complete frames (fence done) instead of a 50 ms wait | low | ✅ device (UI correct) |
| 0195 | GEM buffer objects made **write-combined** (removes the per-cache-line flush of spilled framebuffers) | low | 🔨 device test pending (speed) |
| 0196 | Caps the ring-drain busy-wait at **3 s** (was 100 s — the freeze) | low | 🔨 device test pending |
| 0197 | **GPU hang recovery**: reset the GPU core (RBBM_SW_RESET) + re-init the CP + reload the zap shader + advance the fence. Fail-closed, rate-limited (32/boot). **On by default**; `gpurecover=0` disables | medium | 🔨 device test pending |
| 0198 | **Asynchronous submit**: no more wait-idle in the Metal submit path (the client waits on the fence itself) + the `gpu_ring_reserve` ring back-pressure | medium | 🔨 device test pending |
| 0199 | **SMMU HUPCF** (continue-after-fault): sets SCTLR bit 8 so a GPU context fault no longer terminates the batch's remaining accesses — the GPU retires the batch and posts the fence instead of wedging. Matches UniXNU's `stall_on_fault=0, continue_after_fault=1`. **On by default**; `gpuhupcf=0` restores the stock SCTLR | low | 🔨 device test pending |

The kernel base is assembled from the CI buildtree + `git apply`; every patch is
**compile-checked locally** (`tools/xnu-cc.py`) before any CI run.

## Key findings (from the reference comparison)

- The Metal submit path **waited for the whole ring to drain on every frame**,
  serializing the CPU and the GPU. The client already separates submit from
  WAIT_FENCE, so that wait-idle was redundant (→ 0198).
- `gpu_ring_emit` wraps the write pointer **without checking the read pointer**:
  safe only while every submit drained the ring to empty; asynchronous submit
  needs back-pressure (→ 0198).
- The correct reset for a **CP** hang is a soft reset of the **GPU core**
  (RBBM_SW_RESET), not a **GMU** SYSRESET (which would reset the microcontroller).
  The a630 offset is `0x043` (not the a8xx `0x073` — re-verified against a6xx.xml,
  never guessed).
- The bus (VBIF) must be halted **before** the reset, or in-flight GPU writes can
  corrupt memory after it.
- `sweet_gpu_hang_dump` already reads the correct SMMU fault bit (`FSR & 0x2`),
  not the format bit `0x400` — no false alarm there.

## To verify / decide on device

- **Cacheable surfaces** (Finding 3): if the CPU reads back a surface the GPU
  wrote, there is a risk of stale cache (the wallpaper not loading, graphical
  glitches?). Two options (write-combined vs targeted invalidation) — **decide
  after the device test.**
- **SMMU fault wedge** (Finding 4) — **root-caused on device (gpu-metal8)** and
  addressed by **0199**. The hang is a **GPU IOMMU translation fault** (context
  bank 1, `FSR 0x402` = `TF`, on a wild IOVA `0x14d78_0a8a2c00` that is in no BO).
  Our context banks already run **stall-on-fault off** (SCTLR `CFCFG`, bit 7, is
  clear; the `FSR` stall-status bit `0x100` was not set, confirming no SMMU
  stall), but **HUPCF (bit 8) was clear**, so after the fault the SMMU terminated
  every later access of that context and the GPU wedged. 0199 sets HUPCF to match
  UniXNU (`NativeAdrenoSmmuContext.cpp`: `stall_on_fault=0, continue_after_fault=1`).
- **Recovery hardening** (Finding 5, *deferred — "B"*): the bare `RBBM_SW_RESET`
  path (0197) **does not revive a630+GMU** — on device the recover re-bring-up of
  the GX rail timed out on the GMU OOB `boot_slumber` handshake (`INTR_INFO 0` vs
  `0x40000000` at boot) → `GPU lost`. The real fix is a **GMU-mediated reset**
  (power-collapse + reboot via rpmh), as msm/freedreno `a6xx_recover` does, not a
  register-level reset. Only needed for a true lockup; with 0199 a page fault no
  longer wedges, so this is no longer the first line of defence.
- **Wild-address root cause** (*deferred — "C"*): *why* the frame-12/13 command
  references `0x14d78_0a8a2c00` (a command-stream / descriptor bug). The ib1/ib2
  CP packets are dumped in the gpu-metal8 log; needs a packet-level analysis.

## Long-term direction

A larger performance effort: **concurrent submission / multi-ring** (in the style
of UniXNU/Adreno740). The user client already has a `queueid` notion — a natural
hook. A large effort; see [`gpu-multiring-design.md`](gpu-multiring-design.md).

## Device test log

| Date | Kernel (short SHA) | Boot args | Result |
| --- | --- | --- | --- |
| 2026-11-02 | 0193+0194 | adreno=9 zap=1 gpuhold=1 metalplugin=1 | UI correct but a few FPS + freeze on a hang |
| 2026-11-02 | 0193→0198 (gpu-metal7) | …metalplugin=1 `gpurecover=1` | GPU rendered to fence 12, hung on 13; recovery (RBBM reset) failed at CP re-init → `GPU lost`. No 100 s freeze, no panic (fail-closed held) |
| 2026-11-03 | 0193→0198 recover-v2 (gpu-metal8), CI `41547357270` | …metalplugin=1 (recovery on by default) | Same class: GPU rendered to fence 11, hung on 13 — a **GPU page fault** (SMMU cb1 `FSR 0x402`, wild IOVA). recover-v2 reached the new GX-rail re-bring-up but the GMU OOB handshake **timed out** → `GPU lost`. Root-caused → **0199** |
| _to fill_ | 0193→0199 (HUPCF) | …metalplugin=1 (`gpuhupcf=0` to disable) | _awaiting the test: does the page fault still wedge, or does the GPU retire the batch and keep going?_ |
