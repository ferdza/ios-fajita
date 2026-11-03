# Migration: fork Bergamota, add a `fajita` board, go iOS 18

**Decision (2026-11-03, user):** switch the vast majority of the code onto
Bergamota and move to **iOS 18**. Structure: **fork `ry-diffusion/Bergamota` →
`ferdza/Bergamota`, add a `BOARD=fajita` target** next to `beryllium`. This repo
(`ios-fajita`, iOS 16.7 / iPhone X) becomes **legacy**; new work happens in the
Bergamota fork.

## Why this is tractable

Bergamota is the XNU + iOS port for **beryllium (Poco F1) = the same SDM845 /
Adreno 630 as fajita**, and it is already **multi-board**: `tools/mkadt.py` has a
`BOARDS` dict with `sweet` (SM7150) and `beryllium` (SDM845). Adding `fajita`
(SDM845, OnePlus 6T) is a third entry, closest to `beryllium`. Bergamota already
boots **iOS 18.7.8 (iPhone XR, `iPhone11,8`)** to SpringBoard on this SoC, with
the GPU on Turnip — the stack we want.

## What iOS 18 forces (verified in Bergamota)

- **Not iPhone X.** iPhone X (`iPhone10,3`) tops out at iOS 16.7.x. iOS 18 means
  the **iPhone XR (`iPhone11,8`) 18.7.8 userland** and that device identity —
  same as Bergamota.
- **New kernel base:** Bergamota's **xnu-11215** (Heartwood) line (`xnu/patches-11215/`),
  not our xnu-8796/iOS-16 series. Our `0001–0201` are largely retired.
- **New root image:** built from the iPhone XR 18.7.8 IPSW, not iPhone X 16.7.16.

## What Bergamota already gives us (do NOT re-port)

SDM845 platform bring-up (PSCI/GIC/timers), UFS, the **GPU** (kernel + Turnip
driver), the display/IOMFB path, USB, logging, the boards framework, the iOS-18
userland method, and the connectivity groundwork (its `bt18` branch: Bluetooth
ADT node + BlueTool stub; Wi-Fi ADT + `wlfw`).

## What is fajita-specific and must be ported onto Bergamota

From this repo's patch series (the device deltas, SoC is shared):

| Area | fajita source here | Bergamota target |
| --- | --- | --- |
| **Touch** | `0090/0095/0096/0097/0098-fajita-touch-rmi4…` — **Synaptics RMI4 (S3706)** over I²C | Bergamota's touch is runtime-detected **Goodix / Novatek / Focaltech** (`touch_goodix/novatek/focaltech`). **RMI4 is not there** — add a `touch_rmi4()` + a `TOUCH_RMI4` kind to its detector. |
| **Panel / display** | `0061-iphone-x-display-size`, `0079-display-power`, `0083/0084/0085-fajita-panel-console` — OnePlus 6T AMOLED 1080×2340, notch | a `BOARDS['fajita']` display block (res, scale, `cont_splash_mem`) + panel power |
| **Buttons** | `0089-fajita-keys-probe`, `0091-fajita-keys` (PM8998 via SPMI) | Bergamota's keys/HID path (`0082b-…-keys-touch-hid`) |
| **PMIC rails** | `0092-fajita-rpmh-ldoa28`, `0093-fajita-rpmh-bases` | its rpmh/regulator plumbing (verify fajita rail IDs) |
| **CPU match** | `0086-fajita-cpu-match` | `BOARDS['fajita']` CPU topology (SDM845: 4×A55 + 4×A75) |
| **DTB** | (dumped from the phone) | `dtb/fajita/` |
| **GPU constants** | fajita GMU fw / SMMU / bank bits (`0107/0109/0200`) | should match beryllium (same GPU); re-verify against Bergamota's `gpu-abi/` |

The large `0099–0201` fajita GPU kernel series is **superseded** by Bergamota's
working GPU — don't port it; only carry over any constant Bergamota lacks, each
re-verified (the `a6xx.xml` / `AGENTS.md` rule).

## Concrete first steps (once `ferdza/Bergamota` exists)

1. **Fork** `ry-diffusion/Bergamota` → `ferdza/Bergamota` (user action on GitHub).
2. Branch `fajita` off `develop`.
3. **`tools/mkadt.py`:** add `BOARDS['fajita']` (SDM845, OnePlus 6T display:
   1080×2340, scale, `cont_splash_mem@…`, compat `['oneplus,fajita','qcom,sdm845']`,
   points, security tuple like beryllium). Verify the display base from a boot.
4. **`dtb/fajita/`:** drop the OnePlus 6T device tree (dumped), keep it out of git
   if it carries serials (AGENTS.md).
5. **Touch:** add `touch_rmi4()` (port `0090/0097/0098`) + `TOUCH_RMI4` to the
   detector in Bergamota's touch patch; wire the fajita TLMM/I²C (`0096/0097`).
6. **Build:** `BOARD=fajita shim/build.sh payload`, `mkadt.py --board fajita`,
   bring up console → panel → touch → GPU in that order (the known-good ladder).
7. **Root image:** iPhone XR 18.7.8 IPSW (`iPhone11,8`), like Bergamota's recipe.

## Firmware / out-of-git (unchanged rule)

WCN3990 Wi-Fi/BT firmware + `board-2.bin` + BT NVM, device dumps, DTB with
serials, and Apple artifacts stay **out of git** (AGENTS.md).

## Building without a Mac (unchanged)

No Mac is required for development. Bergamota, like this repo, does the macOS-only
final link on a **GitHub Actions macOS runner**; we develop and compile-check on
Linux here (the GPU driver via `gpu/host-check.sh`, the kernel via the
`xnu-cc.py`-style local check) and group patches into CI builds. A Hackintosh is
an optional convenience, not a requirement.

## Status

- [x] Decision + structure chosen (fork + fajita board, iOS 18).
- [x] `ferdza/Bergamota` fork created.
- [ ] `BOARDS['fajita']` + `dtb/fajita/`.
- [ ] RMI4 touch ported into Bergamota's detector.
- [ ] First `BOARD=fajita` console boot on xnu-11215.
- [ ] iPhone XR 18.7.8 root image.
