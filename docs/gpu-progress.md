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
- **SMMU fault stall** (Finding 4): if the SMMU stalls on a fault, a single bad
  access can cause the hang. The context bank is owned by the hypervisor, so it
  is hard to change; 0197 is the safety net.
- **Recovery hardening** (Finding 5): if RBBM_SW_RESET alone does not bring the
  GPU back, move to a GMU-mediated reset with a fully acknowledged bus drain
  (as Snapintosh does).

## Long-term direction

A larger performance effort: **concurrent submission / multi-ring** (in the style
of UniXNU/Adreno740). The user client already has a `queueid` notion — a natural
hook. A large effort; see [`gpu-multiring-design.md`](gpu-multiring-design.md).

## Device test log

| Date | Kernel (short SHA) | Boot args | Result |
| --- | --- | --- | --- |
| 2026-11-02 | 0193+0194 | adreno=9 zap=1 gpuhold=1 metalplugin=1 | UI correct but a few FPS + freeze on a hang |
| _to fill_ | 7147885 (0193→0198) | …metalplugin=1 (+ `gpurecover=1`) | _awaiting the test_ |

> 0193→0198 kernel: CI run `41540055327`, SHA256
> `7147885556c48c3128add8ca515985604e469c4b16ce10ecc9073424cabd4255`.
> Built before 0197 was switched to on-by-default: for this exact binary, add
> `gpurecover=1` to test recovery. The next build has it enabled by default.
