# iOS on the OnePlus 6T (`fajita`)

**Apple's iOS 16.7.16 running on a OnePlus 6T, with GPU-accelerated Metal rendering.**

This project ports Apple's open-source XNU kernel (the iOS 16 generation) to the OnePlus 6T
(`fajita`, Qualcomm SDM845 / Snapdragon 845, Adreno 630). On top of it runs the **unmodified
iOS 16.7.16 (20H392) userland of the iPhone X**: launchd, the system daemons, backboardd,
SpringBoard and the stock apps.

The phone boots to the **iOS home screen** — unlock, touchscreen and hardware buttons all
work — and the interface is **drawn by the Adreno 630 through Metal**: CoreAnimation renders
on the GPU over the kernel's msm-compatible IOKit user client. The GPU driver is moving from
the first gallium-ir3 bring-up to **Turnip (Metal → Vulkan → a630)**, the path every working
Metal-on-Adreno project uses; the driver is built from
[Bergamota](https://github.com/ry-diffusion/Bergamota)'s `gpu/metal/` at a pinned commit (see
[`gpu/README.md`](gpu/README.md)) and the kernel is already Turnip-ready. Current work is that
GPU pivot and the first connectivity driver (see
[`docs/gpu-turnip-bringup.md`](docs/gpu-turnip-bringup.md) and
[`docs/connectivity-research.md`](docs/connectivity-research.md)).

> Experimental bring-up, not a usable phone OS. Wi-Fi, Bluetooth, the modem and the camera
> are not there yet, Apple's security model is mostly switched off, and the iOS root lives in
> the `userdata` partition — so **flashing it erases whatever is in `userdata`**.

## What works

| Area | State |
| --- | --- |
| Boot | Stock OnePlus ABL (`fastboot`) → our boot image on `boot_a` → shim → XNU. Header v1 + gzip `Image.gz` + appended DTB; a v2 header or a raw `Image` is rejected by this bootloader |
| CPU | 8 of 8 cores via PSCI, GICv3, timers |
| Storage | Own UFS host driver; the iOS root is a journaled HFS+ volume inside `userdata` |
| iOS userland | Real iPhone X 16.7.16 root filesystem and shared cache; launchd and the system daemons run (hundreds of processes) |
| Display | Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`) services, presented as an iPhone X panel |
| **GPU / Metal** | **Adreno 630 renders the UI**: full kernel bring-up (power, clocks, GMU firmware + HFI, SMMU, signed zap, command processor, buffers, fences, IOKit user client) plus the Metal driver. CoreAnimation composites on the GPU. Driver is moving to **Turnip** (Vulkan), built from Bergamota pinned ([`gpu/`](gpu/README.md)) |
| GUI | backboardd, SpringBoard, lock screen, home screen, Control Center, notification centre, Settings |
| Touch | RMI4 over I²C (`0x20`, SE `0xa90000`) with rail enable; delivered as HID digitizer events |
| Buttons | Power and volume up/down (PM8998 through SPMI, usages `0x30`/`0xe9`/`0xea`) |
| Device identity | iPhone X (`iPhone10,3` / D22) so UIKit picks the gesture UI |
| Logging | Persistent ring buffer in `userdata` plus a panic flush; pulled over OrangeFox (`tools/sweet-log-pull.sh`) |

## Current focus: the Turnip pivot & first connectivity

The UI renders on the GPU today through the first gallium-ir3 driver, but that path is slow
and fragile (a shader faulting on a bad descriptor wedged the GPU, and the `0199` SMMU
continue-after-fault experiment panicked the kernel on device). A step-back audit concluded
every *working* Metal-on-Adreno stack routes through **Vulkan/Turnip**, and Bergamota already
proved Turnip on this exact A630 — so the direction is **Metal → Vulkan → Turnip**:

- **GPU.** The Turnip driver is built from Bergamota's `gpu/metal/` at a pinned commit
  ([`gpu/README.md`](gpu/README.md)); the kernel is already Turnip-ready (`0200` exposes the
  `MSM_PARAM`s Turnip queries). GPU recovery and SMMU HUPCF are now **off by default**
  (`0201`) after the `0199` panic. See [`docs/gpu-turnip-bringup.md`](docs/gpu-turnip-bringup.md)
  and the reasoning in [`docs/gpu-audit-2026-11.md`](docs/gpu-audit-2026-11.md).
- **Connectivity.** No radios work yet. The plan is **USB host → a USB Wi-Fi/Ethernet dongle
  → a `utun` interface** first (reuses the working CDC-ECM networking, skips both the modem
  stack and Apple's closed 802.11 family), with native WCN3990 Wi-Fi as a later two-stage
  effort. See [`docs/connectivity-research.md`](docs/connectivity-research.md).

What each GPU patch changes and how the code compares to the other XNU-on-Adreno efforts is in
[`docs/gpu-reference-audit.md`](docs/gpu-reference-audit.md); the coding rules the project
holds itself to are in [`docs/coding-practices.md`](docs/coding-practices.md).

## What does not work (yet)

- **Wi-Fi / Bluetooth / modem / camera**: no drivers yet. The connectivity plan (USB-dongle
  first, native WCN3990 later) is in [`docs/connectivity-research.md`](docs/connectivity-research.md).
- **Wallpaper (PosterBoard)** and a few graphical glitches: under investigation; expected to
  be reworked with the Turnip driver rather than patched on the gallium path.
- **Time**: the clock starts at 1969, so anything checking certificates (TLS, activation)
  sees an invalid date.
- **Apple security**: AMFI, sandbox and code signing are permissive stand-ins. Do not treat
  this as a secure iOS.

## How it boots

1. The bootloader loads `boot_a` with our shim, which sets up a minimal EL2/EL1
   environment and jumps into XNU.
2. The shim passes XNU a payload: the kernel, the ADT (device tree), the boot arguments and
   firmware blobs announced as `sweetfwN=<pa>:<size>` (`a630_gmu.bin`, the GMU memory block,
   the buffer arena, the page-table pool).
3. XNU mounts the HFS+ root from `userdata` and starts `/sbin/launchd`.

## How to do it yourself

### 0. Back up the phone

`userdata` holds the iOS root. Everything else (bootloaders, recovery, modem, `persist`) is
left alone by this project, but keep a backup anyway and read this file to the end first.

### 1. Build the kernel

The flashable kernel is built by GitHub Actions (`.github/workflows/xnu.yml`) from the patch
series in `xnu/patches/` — it needs Apple's `iig` and the closed KDK support libraries, so
the final link is macOS-only. The artifact is `kernel.development.sweet`.

**Before spending a CI run**, validate the patches locally (seconds, no macOS needed):

```bash
python3 tools/check-hunk-counts.py xnu/patches      # every patch still applies in order
# compile-check one or more sources against a downloaded CI buildtree artifact:
python3 tools/xnu-cc.py <ci-run.log> <buildtree/> bsd/dev/sweet_gpu.c
```

`tools/xnu-cc.py` re-runs the real compile commands with a system clang (or an Apple-fork
clang if installed) and, with `XNU_CC_OBJDIR` set, emits arm64 objects whose undefined
symbols reveal link errors. It catches almost everything that makes a CI build fail.

### 2. Build the iOS root image

`tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img` builds a 16 GiB HFS+ image from
the iPhone X IPSW (the OS, SystemOS and AppOS disk images), including the shared cache and
the stock apps. `tools/mk-root-with-gpu.sh --in-place IMG` then adds this project's
userspace pieces (the Metal driver bundle, the GPU test daemons) to an existing image.

### 3. Build the boot image

```bash
export CMDLINE="<the cmdline from NOTES-FAJITA.md> adreno=9 zap=1 gpuhold=1 metalplugin=1"
export ADT_GAMUT=P3
export ARENA_MIB=40
bash tools/build-fajita.sh          # -> shim/out/shim-boot.img
```

`tools/build-fajita.sh` reads the kernel from `xnu/out/kernel.development.sweet`, builds the
ADT (`tools/mkadt.py`), packs the payload (`tools/mkpayload.py`) and wraps it (`shim/build.sh`).
Add `gpurecover=0` to disable GPU hang recovery.

### 4. Flash

```bash
# the iOS root (destructive: this is the userdata partition)
fastboot flash userdata ios16-root-gpu.img

# the kernel/boot image
fastboot flash boot_a shim-boot.img
fastboot reboot
```

On Windows the fastboot from platform-tools is the one that works with this bootloader; a
`fastboot` inside WSL is usually that same Windows binary, so pass it Windows-style paths.

### 5. Read the log

The panel is the first console, and the ring in `userdata` keeps the whole boot:

```bash
tools/sweet-log-pull.sh            # boots OrangeFox, pulls the ring to fajita-logs/
tools/sweet-log.py fajita-logs/<newest>.txt --grep GPU
```

After a hard hang, a photo of the panel is authoritative — the ring can be stale if the
panic happened during a flush.

## The GPU

The kernel bring-up follows the ladder of HackiOS (`oosexgang`) and Bergamota (`ry-diffusion`),
which run the same SDM845/Adreno 630. Boot arguments select how far it goes: `adreno=1..9`,
`zap=1` (the secure-world step), `gpuhold=1` (keep the GPU up after the self-tests),
`metalplugin=1` (load the Metal driver). GPU hang-recovery and SMMU continue-after-fault are
**off by default** (`0201`); the old experiments are `gpurecover=1` / `gpuhupcf=1`.

The userspace Metal driver (Turnip) is built from Bergamota's `gpu/metal/` at a pinned commit;
the recipe, the one fajita delta, the Linux compile-check and the macOS CI are under
[`gpu/`](gpu/README.md). The kernel is already Turnip-ready (`0200`).

| Stage | What it proves |
| --- | --- |
| 1–2 | block probes, CX/GX power domains, GPU clocks |
| 3 | GMU firmware (`0xbabeface` handshake), HFI v1, SMMU contexts |
| 5 | GX rail through the GMU OOB path, SPTPRAC, the core answering (`RBBM_STATUS`) |
| 6 | the signed **zap** through SCM/PAS id 13 (TrustZone authenticates it) |
| 7 | command processor: `hw_init`, `CP_ME_INIT`, out of secure mode, first submission read back |
| 8 | keep-alive, a 1 GiB client address space, submit as "command buffer + fence", the IOKit user client |

The kernel GPU core is `bsd/dev/sweet_gpu.c`; the IOKit user client and present path are in
`iokit/Kernel/arm/SweetAdreno.cpp` and `SweetFramebuffer.cpp`. Per-patch history, every
register number and the traps are in [`NOTES-FAJITA.md`](NOTES-FAJITA.md); the current GPU
work and findings are in [`docs/gpu-progress.md`](docs/gpu-progress.md) and
[`docs/gpu-reference-audit.md`](docs/gpu-reference-audit.md).

### A userland toolchain without macOS

There is no Xcode here and none is needed for userspace tools:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git ~/ios-sdk
cd ~/ios-sdk && git sparse-checkout set iPhoneOS16.5.sdk

clang --target=arm64-apple-ios16.0 -isysroot ~/ios-sdk/iPhoneOS16.5.sdk -fuse-ld=lld -O2 \
      -L~/ios-sdk/iPhoneOS16.5.sdk/usr/lib -Wl,-adhoc_codesign -o tool tool.c \
      -framework IOKit -framework CoreFoundation -lSystem
```

That produces a normal dynamic arm64 Mach-O with `LC_LOAD_DYLIB` entries, which is what the
graphics stack needs.

## Repository layout

```
xnu/patches/            the kernel patch series (apply in order)
shim/                   the small loader the bootloader jumps to
gpu/                    the Turnip driver recipe: pin.env, ios16-overlay.sh, host-check.sh
tools/                  build, image, log and userspace helpers (xnu-cc.py = local compile check)
dtb/                    the device trees dumped from the phone
docs/                   gpu-turnip-bringup.md, connectivity-research.md, coding-practices.md, and more
shim/out/, xnu/out/     build products (not committed)
NOTES-FAJITA.md         the working handoff: state, registers, traps, next steps
PORTING.md              hardware notes and the bring-up plan
```

## Credits

- [ios-sweet](https://github.com/dipa-studio/ios-sweet) — the iOS 16 / XNU base this fork
  started from; `docs/IOS16_README.md` keeps that history.
- HackiOS (`oosexgang`) — the Adreno bring-up ladder the GPU work follows.
- [Bergamota](https://github.com/ry-diffusion/Bergamota) — the sibling XNU port for
  beryllium (the same SDM845/Adreno 630). Its `gpu/metal/` is the Metal → Vulkan → Turnip
  driver this project builds from (pinned), together with the `freedreno-sweet` libdrm shim
  and the `renegade` signing tool;
  [Chlorophyll](https://github.com/ry-diffusion/Chlorophyll) is that driver's upstream.
- Reference designs studied for the GPU submit/fence/recovery work: msm/freedreno (Linux
  a6xx), [UniXNU/Adreno740](https://unixnu.com) and Cam396/Snapintosh (XNU-on-Adreno).
- [theos/sdks](https://github.com/theos/sdks) — the iOS SDK used to build userland tools.
- Apple's open-source releases (XNU, IOHIDFamily, libpthread, hfs), BearSSL, and OrangeFox
  Recovery. iOS itself is Apple's and is not distributed here.
