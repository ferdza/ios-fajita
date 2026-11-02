# Design — concurrent submission / multi-ring (a630)

Design for the chosen long-term performance effort: multiple submission queues,
so the UI (the compositor, SpringBoard) is not blocked behind a heavy app render.
**Design document — not yet implemented.** To be weighed against the 0193–0198
device results (if the single-ring asynchronous submit from 0198 is already
smooth, the hardware-preemption part is not urgent).

References: UniXNU/Adreno740 (multi-ring recover/preempt, a7xx), Snapintosh
(a8xx), msm/freedreno a6xx. See
[research-and-similar-projects.md](research-and-similar-projects.md).

---

## 1. What it gives (and what it does not)

- **Gives:** **priority / responsiveness.** The compositor can jump ahead of a
  long app render, so the UI stays responsive even when an app loads the GPU.
- **Does not give:** raw throughput on a single workload. For one render, a single
  ring is enough. The single-workload gain already comes from 0195
  (write-combined) + 0198 (asynchronous submit).

So: **judge after the 0198 device test.** If single-ring asynchronous submit is
smooth for UI use, this effort is a responsiveness "nice-to-have," not urgent.

## 2. What our code already has

- The IOKit user client already exposes a **`queueid`** notion (`QUEUE_IDS`, the
  `fQueues` mask in `SweetAdreno.cpp`) — a natural hook.
- A **single ring** (`gpu_cp_wptr`, `GPU_CP_RING`), a **single fence counter**
  (`gpu_cp_seq`), a fence slot in the scratch page, and a single address space.
- **Asynchronous** submit + the `gpu_ring_reserve` back-pressure (0198), and a
  single-ring **recovery** (`sweet_gpu_recover`, 0197).

## 3. Hardware grounding — ⚠️ a630 risk

Open-source Adreno preemption is **proven only on a7xx+** (the msm series are
titled "preemption for A7XX targets," enabled on tested a750/a7xx parts). Both of
our references that preempt are a7xx (Adreno740) and a8xx (Snapintosh). For
**a630** (SDM845), preemption existed in **downstream CAF/Qualcomm** kernels but
is not well documented in open source. Unknowns to resolve before committing:

- does the **SQE** firmware we load support `CP_CONTEXT_SWITCH` on a630?
- the exact a630 **preempt record** layout (saved write pointer, SMMU info,
  GPU_RO buffer);
- the `CP_CONTEXT_SWITCH_CNTL` (ringbuffer-level) registers — offsets to be
  **re-verified against a6xx.xml**, never taken from an a7xx.

Conclusion: do not port an a7xx reference's hardware preemption directly. Use a
**staged** approach, the safe level first.

## 4. Staged design

### Stage A — software multi-queue → single ring (safe, first)
No hardware preemption. The kernel orders several client queues into **the single
ring**, by priority:

- Per `queueid`, a small queue structure (priority, last fence).
- `sweet_gpu_submit(queueid, …)`: instead of emitting directly, **enqueue** the
  IBs; a **scheduler** drains the queues into the ring by priority (compositor
  before app), still asynchronous and still using `gpu_ring_reserve`.
- **Fence namespace:** keep a single global `gpu_cp_seq` (like Adreno740, where
  the rings share one numbering), but remember the last fence per queue for
  `WAIT_FENCE`.
- Gain: submission order favors the UI. Limit: it does **not preempt** an IB
  already in flight (an app frame already submitted finishes before the UI gets
  through).
- Risk: low (we stay on the proven ring model). Mostly scheduling.

### Stage B — hardware ringbuffer preemption (a630, advanced, optional)
Two hardware rings + `CP_CONTEXT_SWITCH` so the GPU switches to the
high-priority ring when it has work, preempting the low one.

- Allocate a **second ring** + a **preempt record** per ring (a630 layout to be
  established).
- Program `CP_CONTEXT_SWITCH_CNTL` (ringbuffer level), with a postamble that
  resets the performance counters on preemption (msm reviewers noted this is
  necessary).
- Integrate **multi-ring recovery** in the style of Adreno740 (a `recover` that
  handles the faulting ring, advances both rings' fences, and replays) — adapt
  our `sweet_gpu_recover`.
- Gain: true preemption (the UI jumps ahead of a long render in progress).
- Risk: **high on a630** (firmware/record/registers not proven in open source).
  Attempt only after Stage A, with careful device validation and a boot-arg
  **gate** (`gpupreempt=1`, off by default), fail-closed.

## 5. What would change

| Area | Stage A | Stage B |
| --- | --- | --- |
| `sweet_gpu.c` submit | enqueue + scheduler | + second ring, preempt record, CP_CONTEXT_SWITCH |
| fences | last fence per queue | same + per-ring shared fence |
| `SweetAdreno.cpp` | route by `queueid`, WAIT_FENCE per queue | same |
| recovery (0197) | unchanged | extend to multi-ring (Adreno740 model) |
| boot-arg | — | `gpupreempt=1` (opt-in, fail-closed) |

## 6. Validation

- Stage A: local compile check (`xnu-cc.py`), then device — measure **UI
  responsiveness** under load (an app rendering heavily while scrolling).
- Stage B: first **confirm a630 preemption support** (SQE firmware, registers)
  with a minimal isolated test (one `CP_CONTEXT_SWITCH` between two trivial rings,
  read back) **before** any integration — like the existing boot tests
  (`gpu_cp_nop_test`, etc.). If the hardware does not follow, stay at Stage A.

## 7. Recommendation

1. Test 0193→0198 first. If the UI is smooth, **Stage A** is enough for
   under-load responsiveness — low risk, large comfort gain.
2. Approach **Stage B** (a630 hardware preemption) only if Stage A is not enough,
   with an isolated feasibility test first, because a630 is not well-trodden in
   open source.
