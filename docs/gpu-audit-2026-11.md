# GPU stack audit — 2026-11-03

A step-back audit of the Adreno/Metal kernel stack after the 0199 kernel
**panicked on device** and rendering regressed (icons corrupted on the previous
test). It compares our code against the reference drivers (UniXNU/Adreno740,
msm/freedreno, Snapintosh) and recommends a direction. Written because the recent
patch series (0195–0199) has not produced a validated improvement and now
regresses — the concern that "our patches are making it worse" is, on the
evidence below, correct for at least 0195 and 0199.

Observations are grounded in the code; the one claim I cannot prove without the
panic log is flagged as a hypothesis.

---

## TL;DR

- **One root cause ties together all three recent failures** (corrupt icons,
  the wild fault address in gpu-metal8, the 0199 panic): the **BO cache-coherency
  model is broken on the ordinary-memory path**. The client maps buffers
  **cacheable**; on submit we must clean those dirty CPU lines to memory before
  the GPU reads. We do that correctly for **arena** BOs (clean by physical
  address) but for **ordinary-memory** BOs (allocated when the arena is full)
  `gem_flush()` does **only `dsb sy`** — which does **not** write back the
  client's dirty cache lines. The GPU then reads **stale** memory.
  - Stale vertex/texture data → **corrupt icons**.
  - A stale pointer/descriptor read from a BO → the GPU dereferences garbage →
    the **wild IOVA `0x14d78_0a8a2c00`** and the SMMU translation fault in
    gpu-metal8.
- **0199 (HUPCF / continue-after-fault) made it worse, not better.** On a driver
  that is already generating wild addresses, letting the GPU *continue* past a
  fault lets a corrupt batch keep executing and scribble over memory →
  **kernel panic** (hypothesis, consistent with "build OK, runtime panic, and no
  panic on the earlier GPU-lost runs"). HUPCF is correct on a *clean* driver
  (UniXNU runs it); it is dangerous as a band-aid over an unsolved addressing bug.
- **The recovery direction (0197) is architecturally wrong for a630+GMU** and was
  built before the foundation was sound. The references do **timer-driven
  hangcheck + GMU-mediated restart + submission replay**, not a synchronous bare
  `RBBM_SW_RESET` from the wait path.
- **Recommendation:** stop adding hang/recovery machinery. Gate 0199 off, **fix
  the coherency model to one consistent, reference-backed scheme**, confirm the
  icons and the wild address are gone, *then* revisit recovery. Validate one
  behavior at a time (boot-arg gated) even within a grouped CI build.

---

## How a BO flows today (and where it breaks)

A GEM buffer object can live in **three different memory regimes**, chosen at
allocation time (`SweetAdrenoUserClient::gemNew`, `SweetAdreno.cpp:425`):

| Regime | When | Backing | Kernel alias | `gem_flush` does |
| --- | --- | --- | --- | --- |
| **Arena** | normal | `sweet_gpu_alloc_pages` (contiguous, above `gPhysBase`) | physical / `ml_io_map` | `flush_dcache64(pa, len, TRUE)` — clean by PA ✅ |
| **Ordinary** | arena full | `IOBufferMemoryDescriptor::inTaskWithOptions(… kIOMapWriteCombineCache)` | write-combined | **`dsb sy` only** ❌ |
| **Surface** | IOSurface path | IOSurface pages | cacheable VA | `flush_dcache64(kva, len, FALSE)` by VA |

The client **always maps the BO cacheable** — the code says so explicitly
(`SweetAdreno.cpp:762`: *"The client writes through a cacheable mapping (the map
options it passes override whatever clientMemoryForType() asks for)"*). So on
**submit** (CPU → GPU) the client's dirty lines must be cleaned to memory, and on
**CPU_PREP** (GPU → CPU) the client's stale lines must be invalidated.

- For **arena** BOs both happen correctly (clean/invalidate by physical address;
  the D-cache is PA-tagged so it reaches every alias).
- For **ordinary** BOs, `gem_flush()` executes only `dsb sy` (`SweetAdreno.cpp:614`).
  `dsb` is a barrier; it is **not** cache maintenance. The client's dirty
  **cacheable** lines are never written back, and its stale lines are never
  invalidated. The GPU reads whatever is in physical memory — **stale**.

This is the coherency hole 0195 opened: it replaced the correct (but slow)
per-line clean on the ordinary path with a bare barrier, for speed. It is almost
certainly intermittent — it only bites once BOs spill to the **ordinary** path
(arena full, i.e. under surface/BO pressure — many icons), which matches "icons
had trouble on the last test."

A second, deeper smell: the same physical page ends up mapped **write-combined**
(kernel) and **cacheable** (client) at once. Mismatched memory attributes for one
physical page are architecturally discouraged on ARM and can lose coherency on
their own, independent of the missing flush.

---

## What the references do (and we don't)

### Coherency — UniXNU/Adreno740 (the closest XNU reference)

UniXNU treats WC vs cacheable as a first-class, **validated** property, not an
incidental side effect of which allocator ran:

- `NativeAdrenoMemory.cpp` tracks per-import whether pages are cacheable, exposes
  `makeWriteCombined()`, and when a BO is write-combined keeps a **cacheable
  alias for CPU readback** — `NativeAdrenoVm.cpp:478`: *"A write-combined BO's own
  mapping is non-cacheable: read the cacheable alias instead, so a dirty line is
  still seen."*
- It maintains each span's cache state deliberately (`NativeAdrenoMemory.cpp:413`)
  and only treats the GPU's cacheable accesses as coherent after the **board
  proved** it, in both directions (`NativeAdrenoVm.cpp:9`).

So UniXNU has exactly the thing we are missing: a single, consistent,
proven-coherent memory model with a defined readback path. We have three regimes
and a barrier where a flush is required.

### Hang handling — UniXNU + msm/freedreno

- A **hangcheck timer** (msm's 500 ms period) polls ring progress
  (`NativeAdrenoPublish.cpp:199`, `NativeAdrenoSubmit::hangCheck`). On a stall it
  restarts the GPU through a board hook and **replays the other submissions**
  (recover_worker). Only the client whose submission hung is told its device is
  lost — not the whole GPU.
- The restart is **GMU-mediated** (power path), matching msm/freedreno
  `a6xx_recover`, not a bare core reset.

Ours (0197): recovery is invoked **synchronously from the user-client wait
path**, does a bare `RBBM_SW_RESET` (which on device does **not** revive
a630+GMU — the GMU OOB `boot_slumber` handshake times out), has **no submission
replay**, and marks the **whole** GPU lost. It was also added before the
coherency foundation was fixed, so it has been catching faults that shouldn't
occur in the first place.

### Snapintosh (macOS 27, a8xx)

Its `adreno_recover` is fail-closed, rate-limited, with a staged bus halt — we
already borrowed those properties. But it, too, sits on a clean memory/VM model;
the recovery is the last line, not the first.

---

## The 0195→0199 series, re-judged

| Patch | Intent | Verdict now |
| --- | --- | --- |
| 0195 write-combined BOs | kill the per-line flush that dropped FPS | **Opened the coherency hole** on the ordinary path (`dsb` instead of clean). Root of the icon/stale-read/wild-address chain. |
| 0196 ring-drain 3 s cap | stop the 100 s busy-wait freeze | Sound and low-risk. Keep. |
| 0197 GPU hang recovery | revive the GPU after a hang | **Wrong mechanism for a630+GMU** (bare RBBM reset; GMU not revived). Does not work on device. Keep gated off until re-architected (B). |
| 0198 async submit | stop serializing CPU/GPU per frame | Reasonable *in principle*, but it leans on recovery (0197) and on a coherent ring — unsafe while the foundation is broken. |
| 0199 SMMU HUPCF | don't let one fault wedge the GPU | **Backfired**: continuing a corrupt batch → memory corruption → panic (hypothesis). Correct only once we stop generating wild addresses. Gate off now. |

Pattern: 0195 broke coherency; 0197–0199 are increasingly aggressive attempts to
survive the consequences, each adding risk. That is the "making it worse" the
user felt.

---

## Recommended plan

**Phase 1 — stop the bleeding (safe kernel).**
1. **Gate 0199 off by default** (`gpuhupcf=0` as default, or drop the patch).
   Don't let a faulting batch continue while addresses are still wild.
2. Keep 0197 recovery **off by default** too (it doesn't work and adds risk).
   0196's bounded wait already removes the 100 s freeze; a hang becomes a clean,
   logged GPU-lost instead of a panic.

**Phase 2 — fix the foundation (one consistent coherency model).** Pick one:
- **(a) Cacheable + correct maintenance (lowest risk, closest to what worked):**
  allocate ordinary BOs **cacheable** again and, in `gem_flush`, clean/invalidate
  the **cacheable** alias by VA (not `dsb`). Reclaim 0195's speed differently —
  flush only the dirty *range* the submission touches, not the whole BO.
- **(b) Write-combined end-to-end (UniXNU's model):** make the **client** map the
  BO WC too (so there are no cacheable lines), and add a **cacheable readback
  alias** for CPU_PREP, exactly as UniXNU does. More work, but matches the proven
  reference and keeps the per-submission cost at one barrier.

Either way: **one** regime, defined readback, no mismatched aliases.

**Phase 3 — confirm.** On device, verify icons render correctly and the wild
address / SMMU fault is gone. This is the real test of Phase 2, and likely of the
"freeze" too (no fault → no wedge).

**Phase 4 — root-cause belt-and-braces (C).** Walk the gpu-metal8 ib1/ib2 CP
packet dump to confirm which packet carried `0x14d78_0a8a2c00` and that it is a
BO-resident pointer (i.e. that Phase 2 removes it).

**Phase 5 — recovery, done right (B), only after 1–4.** Replace the synchronous
bare-RBBM path with an msm-style **timer hangcheck + GMU-mediated restart**, and
per-client device-lost instead of global. Re-enable HUPCF *then* — on a clean
driver it is correct.

### Process note (reconciling with limited CI)

Grouping patches into one CI **build** is still right (macOS runners are scarce).
The fix for ambiguous device debugging is not more builds — it is to keep **every
behavior boot-arg gated** (we already do: `gpurecover`, `gpuhupcf`, `adreno`,
`zap`). Then one kernel lets the user A/B a single behavior across boots, which
gives per-change signal without per-change builds.

---

## Open questions for the maintainer

- Phase 2: prefer **(a) cacheable + ranged clean** (less churn, closest to the
  last known-good) or **(b) WC end-to-end** (matches UniXNU, more work)?
- Is the 100 s-freeze class fully covered by 0196 alone once coherency is fixed,
  or do we still want a *logged, fail-closed* GPU-lost (no reset) as the floor?
- Appetite for the msm-style hangcheck/replay rework (B) now, or defer until the
  UI is smooth and correct?
