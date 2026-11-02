# Architecture — the major components

Overview of the project's components: what each one does, where it lives, and how
they fit together. For low-level detail see [`NOTES-FAJITA.md`](../NOTES-FAJITA.md)
and [`PORTING.md`](../PORTING.md).

```
  OnePlus bootloader (ABL, fastboot)
        │  loads boot_a (or a temporary `fastboot boot`)
        ▼
  shim/  ── minimal EL2/EL1 setup, jumps into XNU, passes the payload
        │        payload = kernel + ADT + boot-args + sweetfwN blobs
        ▼
  XNU (xnu-8796, patched)  ── bsd/ iokit/ osfmk/ …
   ├─ UFS host driver ───────── mounts the HFS+ root inside `userdata`
   ├─ Display (IOSurface + IOMobileFramebuffer / AppleCLCD, iPhone X panel)
   ├─ RMI4 touch (I²C) + PM8998 buttons (SPMI)  → HID
   └─ Adreno 630 GPU
        ├─ bsd/dev/sweet_gpu.c ───── bring-up + ring + fence + recovery
        ├─ iokit/.../SweetAdreno.cpp ─ msm-compatible user client
        └─ iokit/.../SweetFramebuffer.cpp ─ present path (vsync, swap)
        ▼
  iOS 16.7.16 userland (iPhone X, unmodified)
   ├─ launchd + daemons + backboardd + SpringBoard
   └─ Chlorophyll (Metal driver) ── AIR→NIR→ir3 (freedreno) → the user client
```

---

## 1. Boot chain (`shim/`, payload, ADT)

The OnePlus bootloader (ABL) accepts a **v1 boot image header**: a gzip `Image.gz`
plus an appended DTB. A v2 header or a raw `Image` is rejected. Our image carries
a **shim** that sets up a minimal EL2/EL1 environment and jumps into XNU, passing
it a **payload**:

- the **kernel** (`kernel.development.sweet`),
- the **ADT** (Apple Device Tree, built by `tools/mkadt.py` — this is the device
  tree XNU expects, not the Linux DTB),
- the **boot arguments** (`CMDLINE`),
- **firmware blobs** announced as `sweetfwN=<pa>:<size>`: `a630_gmu.bin`, the GMU
  memory block, the GPU buffer **arena** (it travels raw inside the boot image,
  which is why it is bounded to ~44 MiB on the ~64 MiB `boot_a`), and the
  page-table pool.

Tools: `tools/build-fajita.sh` (orchestrates), `tools/mkadt.py`,
`tools/mkpayload.py`, `shim/build.sh`.

## 2. XNU port (`xnu/patches/`)

iOS 16 XNU (xnu-8796) built by GitHub Actions via `blacktop/darwin-xnu-build`
(macOS runner: Apple's `iig` and the closed KDK support libraries are required,
so the final link is macOS-only). All customization is a **numbered patch
series** under `xnu/patches/`, applied in order with `git apply`. Kernel config
`MACHINE_CONFIG=SWEET`, plain arm64 (no arm64e/ptrauth).

Local validation before CI: `tools/xnu-cc.py` (see
[`gpu-progress.md`](gpu-progress.md)) re-runs the real compile commands with a
system clang, catching compile and link errors in seconds.

## 3. Storage (UFS, HFS+ root)

An in-house UFS host driver. The iOS root is a **journaled HFS+ volume stored
inside the `userdata` partition** (decision of 2026-10-15: no GPT changes, so
flashing erases `userdata`). It is built by `tools/mkiosroot.sh` from the
iPhone X IPSW (OS/SystemOS/AppOS + shared cache + stock apps).

## 4. Display (IOSurface, IOMobileFramebuffer, AppleCLCD)

Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`) services, presented as an
**iPhone X panel**. This is what lets CoreAnimation composite. GPU presentation
then goes through `SweetFramebuffer.cpp` (component 7).

## 5. GPU — kernel core (`bsd/dev/sweet_gpu.c`)

The staged Adreno 630 bring-up (boot-arg `adreno=1..9`): power/clocks (2), GMU
firmware + HFI (3), GX rail / SPTPRAC (5), the signed zap through TrustZone (6),
command processor `hw_init` / `CP_ME_INIT` (7), then keep-alive + a 1 GiB client
address space + "command buffer + fence" submission + the buffer arena (8). In
service it owns the PM4 ring (`gpu_ring_emit`/`flush`), the fences
(`sweet_gpu_fence_*`, a slot written by `CACHE_FLUSH_TS`), submission
(`sweet_gpu_submit`, **asynchronous** since 0198 with the `gpu_ring_reserve`
back-pressure), the hang dump, and **recovery** (`sweet_gpu_recover`, 0197).
Details and the patch series: [`gpu-progress.md`](gpu-progress.md).

## 6. GPU — IOKit user client (`iokit/Kernel/arm/SweetAdreno.cpp`)

The **msm-compatible** surface a userspace driver opens: `GEM_NEW`/`INFO`/
`SUBMIT`/`CPU_PREP`/`WAIT_FENCE`/`close`, the buffer objects (write-combined
since 0195), the GPU address space, and hang detection/recovery wired into
`waitFenceCall`. This is the ABI Mesa/freedreno expects.

## 7. GPU — present path (`iokit/Kernel/arm/SweetFramebuffer.cpp`)

A 60 Hz vsync timer notifies CoreAnimation; `swap()` marks the frame, and
presentation happens only for a **complete frame** (its fence is done — 0194),
which stopped half-rendered frames from reaching the panel. The panel is
throttled by `sweetfb_hz`.

## 8. Metal userspace (Chlorophyll / Bergamota)

**Chlorophyll** is Mesa **freedreno** (the ir3 compiler, a630 target) presented
as an Apple **Metal** driver: `libbgair.dylib` performs AIR→NIR→ir3. **Bergamota**
is the kernel-side GPU bring-up. The **SweetBGMTL.bundle** is the Metal plugin,
loaded by `metalplugin=1`. This is the open-source driver we keep; the recent
work is the **kernel glue** around it (submit/fence/cache/recovery), not a rewrite
of the driver.

## 9. Input (touch, buttons)

Touch is **RMI4 over I²C** (`0x20`, SE `0xa90000`) with rail enable, delivered as
HID digitizer events. Power and volume buttons go through **PM8998** (SPMI, usages
`0x30`/`0xe9`/`0xea`). The device identity is iPhone X (`iPhone10,3` / D22) so
UIKit selects the gesture UI.

## 10. Logging & diagnostics

A persistent ring buffer in `userdata` plus a panic flush; pulled over OrangeFox
(`tools/sweet-log-pull.sh`), filtered by `tools/sweet-log.py`. The panel is the
first console (`sweetfb_noconsole` mutes it at the first swap to hand the screen
to the GUI). After a hard hang, a **photo of the panel is authoritative** (the
ring can be stale if the panic happened during a flush).

## 11. Security (stubs)

AMFI, the sandbox, and code signing are **permissive stand-ins** — this is not a
secure iOS. The clock starts in 1969, so anything that checks a certificate sees
an invalid date.
