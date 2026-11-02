# GPU reference audit — our code vs the references

References read: **UniXNU/Adreno740** (XNU + Adreno a7xx, Xiaomi Pad),
**Cam396/Snapintosh** (EL2 hypervisor + Adreno Metal/IOGPU stack, macOS 27,
Snapdragon X2 a8xx), and **msm/freedreno** (Linux, a6xx).

⚠️ **XNU-version caveat.** Adreno740 and Snapintosh target a *much newer* XNU
(macOS 26/27) and Adreno a7xx/a8xx. We copy **no** APIs from them: we take the
*method* and the *hardware sequences*, adapted to our xnu-8796 (iOS 16) and to the
**a630/SDM845**. Register offsets are re-verified against a6xx.xml rather than
reused as-is (e.g. `RBBM_SW_RESET_CMD` is 0x043 for us, not the a8xx 0x073).

Our GPU core is `bsd/dev/sweet_gpu.c` (a630 bring-up, ~3900 lines) plus the IOKit
user client `iokit/Kernel/arm/SweetAdreno.cpp` and `SweetFramebuffer.cpp` (present
path).

---

## Finding 1 — Synchronous submit (serialization) → **FIXED (0198)**

**Our code (before):** both `sweet_gpu_submit` and `gpu_cp_submit` ended with
`gpu_ring_wait_idle(...)` → the CPU busy-waited (via `delay()`) until the GPU had
drained the entire ring, on every frame. That is pure CPU↔GPU serialization.

**The references:** msm `a6xx_submit`, Adreno740 `submitUnfenced`, Snapintosh
`adreno_ring_kick` all write the ring, advance the write pointer, and **return
immediately**. Synchronization happens *later* through the fence.

**The key fact:** our IOKit client *already* separates submit from waiting
(`submit()` records `r->fence`, then `CPU_PREP`/`WAIT_FENCE` waits) — so the
wait-idle inside submit was **redundant**. A likely major contributor to the
low frame rate, on top of the cache flushes 0195 removes.

**Fix 0198:** `sweet_gpu_submit` returns right after the write-pointer kick; added
`gpu_ring_reserve` (back-pressure: wait for the read pointer to free room, because
`gpu_ring_emit` wraps without checking it — safe only while we drained to empty).
`gpu_cp_submit` (boot tests) stays synchronous.

## Finding 2 — No hang recovery (the freeze) → **FIXED (0196 + 0197)**

**Our code (before):** `gpu_ring_wait_idle` looped `100000 × 1 ms` = **100 s of
busy-wait** when the CP was wedged, then `sweet_gpu_hang_dump`, which *resets
nothing* → a full freeze until reboot.

**The references:** Adreno740 `recover()` + Snapintosh `adreno_recover()` are a
mature sequence: halt the bus → reset the core → re-init the CP → advance the
fence → replay/resubmit, with fail-closed guards and rate limiting.

**Fix 0196:** cap the busy-wait at 3 s (msm hangcheck is 500 ms) → a wedge becomes
a bounded stall, not a 100 s freeze.

**Fix 0197** (`sweet_gpu_recover`, on by default, `gpurecover=0` disables):
halt the SQE + halt the VBIF (best-effort ack) → **RBBM_SW_RESET** of the GPU core
(the GMU stays up: a CP hang does not wedge the GMU) → `gpu_cp_hw_init` +
`gpu_cp_start` → reload the **zap shader** (back out of secure mode) → advance the
fence slot to the last submitted sequence (unblocks every waiter) →
`gpu_lost = false`. **Fail-closed** (any step that does not settle marks the GPU
lost, no loop) and **rate-limited** (32 resets/boot). Wired into `waitFenceCall`
and into the `gpu_ring_reserve` failure path.

Lessons from the references applied: halt the bus **before** reset (otherwise
in-flight GPU writes corrupt memory afterward); fail-closed guards; rate limiting;
reset the **core**, not the GMU.

## Finding 3 — Cache coherency on GPU→CPU readback → **to watch**

`sweet_gpu_cache_sync` is just a `dsb sy` barrier. Correct for our
uncached / write-combined buffers (the arena and, since 0195, the GEM BOs). The
references (Adreno740 `makeWriteCombined`, Snapintosh's `INVALIDATE` in
adreno-ib) issue a `dc ivac` *only* for **cacheable** BOs the CPU reads after a
GPU write. In our code the **display surfaces stay cacheable** (0195 touches only
the GEM BOs): if the CPU reads a surface the GPU wrote without invalidation, it
can read stale cache. To verify on device (residual graphical glitches, the
wallpaper). Options: targeted invalidation in the present path, or make surfaces
write-combined like the BOs.

## Finding 4 — SMMU behavior on a fault → **noted (outside our control)**

Adreno740 sets `stall_on_fault=0, continue_after_fault=1`, so an access fault does
not wedge the GPU. In our code, stage 3c leaves the SMMU to the **hypervisor's
stream table** — we do not configure the context bank, so this is hard to change.
If the SMMU stalls on a fault, a single bad access can cause the hang (→ freeze).
To confirm; otherwise 0197 recovery is the safety net.

Good point: Adreno740 notes "FSR 0x400 is a format bit, not a fault." Our
`sweet_gpu_hang_dump` tests `FSR & 0x2` (the real fault bit), not 0x400 — no false
alarm from that side.

## Finding 5 — Recovery hardening (if 0197 is insufficient on device)

If RBBM_SW_RESET alone does not bring the GPU back, the hardening path, from
Snapintosh's `adreno_recover`: a **GMU-mediated reset** + a full bus-transaction
drain (halt GBIF/VBIF *acknowledged in stages*), write-one-to-clear of faults
before reset, and an SQE image integrity check (hash) before writing. The VBIF
client mask is to be confirmed (0xf assumed for a630).

---

## Quality / method taken from the references

- **Local build**: `tools/xnu-cc.py` (improved, commit 729b5d7) validates each
  patch in seconds with a system clang plus a CI buildtree → we no longer waste a
  CI run on a compile error. The *final flashable* kernel still needs the macOS CI
  (Apple's `iig` + closed KDK libraries).
- **Opt-in gate** (boot-arg), **fail-closed**, **rate-limit**, **constant
  provenance**, and **no invented hardware constants** (a630 offsets re-verified
  against a6xx.xml).

## CI plan (grouped — a single build)

Branch `fix/surface-row-align-64` = **0195 + 0196 + 0197 + 0198**. One CI build
delivers them all. Device tests, in order:

1. Without `gpurecover`: check **smoothness** (0195 write-combined + 0198 async →
   the frame rate should recover) and that a hang stalls only briefly (~3 s,
   0196) rather than 100 s.
2. With **`gpurecover=1`**: check that it **recovers** instead of freezing.

Boot args: `…adreno=9 zap=1 gpuhold=1 metalplugin=1` (+ `gpurecover=1` for test
2). `ARENA_MIB=40`.
