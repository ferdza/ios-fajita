# Research & similar projects

The landscape of "XNU / macOS / Adreno off Apple hardware" efforts, what each one
contributes, and **what we take from it**. Note: register offsets and hardware
sequences are **re-verified against public sources** (a6xx.xml), never copied
blindly — the XNU versions and GPU generations differ.

---

## Our direct lineage

### ios-sweet (dipa-studio)
The iOS 16 / XNU base this repository forks. Provides the port's skeleton (shim,
ADT, UFS, display, the patch series). History kept in `docs/IOS16_README.md`.

### Bergamota & Chlorophyll (ry-diffusion)
The **same SoC as ours**: SDM845 / Adreno 630.
- **Bergamota** — the a630 kernel GPU bring-up and the **msm-compatible IOKit
  user client**. The foundation of our `sweet_gpu.c` / `SweetAdreno.cpp`.
- **Chlorophyll** — the userspace **Metal** driver: Mesa/freedreno (ir3) presented
  as Metal, AIR→NIR→ir3. This is the open-source driver we keep.

*What we take:* most of the GPU architecture. Our recent work is the kernel glue
around it (performance and recovery).

### HackiOS (`oosexgang`)
The Adreno bring-up "ladder" (stages 1→8) the GPU follows. Same SDM845/a630
family.

*What we take:* the order and the proof of each bring-up stage.

## References for GPU performance & recovery

### msm / freedreno (Linux, a6xx)
The reference kernel driver for Adreno a6xx (including a630). Source of the
canonical sequences: `a6xx_submit` (asynchronous submission + fence),
`a6xx_recover`, `a6xx_bus_clear_pending_transactions` (halt VBIF/GBIF before
reset), a ~500 ms hangcheck, and the register definitions (a6xx.xml → verified
offsets, e.g. `RBBM_SW_RESET_CMD = 0x043`).

*What we take:* asynchronous submit (0198), halting the bus before reset, a
bounded hangcheck (0196), and the correct a630 offsets.

### UniXNU / Adreno740
XNU + Adreno **a7xx** (Xiaomi Pad), with native Metal. A much newer XNU than ours,
so we copy **no** APIs from it. Its "GPU restart/recovery + system-memory BOs"
work addresses our exact two problems.

*What we take:* the recovery **method** (hangcheck → recover worker → mark the
faulting VM, advance the fence, restart, replay), **write-combined** system
buffers by default (which validated our 0195), SMMU `stall_on_fault=0 /
continue_after_fault=1`, and the note that "FSR bit 0x400 is a format bit, not a
fault."

### Cam396 / Snapintosh
An EL2 hypervisor plus an **Adreno Metal/IOGPU stack on macOS 27**, Snapdragon X2
Elite (a8xx). A mature recovery module (`adreno_recover` in
`compat/adreno-ib.c`): fail-closed guards, rate limiting, a staged
acknowledged bus halt, write-one-to-clear of faults before reset, and an SQE
firmware-image integrity check before writing. Its `AGENTS.md` is also an
excellent **quality standard** (opt-in gates, constant provenance, host-first
validation).

*What we take:* the fail-closed + rate-limited structure of our
`sweet_gpu_recover` (0197), halting the bus before reset, and the general quality
discipline. Caveat: a8xx ≠ a630 (e.g. `RBBM_SW_RESET_CMD` is 0x073 there vs 0x043
for us → re-verified).

## How we apply all of this

See [`gpu-reference-audit.md`](gpu-reference-audit.md) for the line-level
comparison (our code vs the references, prioritized findings) and
[`gpu-progress.md`](gpu-progress.md) for the patch series and its state.

The guiding principle, like the open NVIDIA kernel modules on macOS: **keep the
open-source core** (freedreno/Chlorophyll, which is what makes the UI render) and
**rewrite the kernel glue** (submit/fence/cache/recovery) — no driver rewrite.
