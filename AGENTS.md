# Working on ios-fajita

Apple's iOS 16 userland + a patched XNU on the OnePlus 6T (`fajita`, SDM845 /
Adreno 630). This is a fork of ios-sweet.

## Orient yourself first

- Read **[docs/index.md](docs/index.md)** — the documentation hub (architecture,
  GPU work, research, similar projects). Start there.
- Read **[NOTES-FAJITA.md](NOTES-FAJITA.md)** — the exhaustive working handoff:
  current state, registers, traps, local artifact locations, next concrete step.
- **[README.md](README.md)** has the build & flash procedure and what works.

## Keep the handoff current

The user switches agents frequently. After each milestone and before stopping,
update the active handoff in `NOTES-FAJITA.md` and the relevant `docs/` page
(e.g. `docs/gpu-progress.md`'s device test log). Record commits, CI run IDs,
exact build/boot results, and unfinished work. Distinguish observations from
guesses, and verified behavior from assumed.

## Building the kernel

- The flashable kernel is built by GitHub Actions (`.github/workflows/xnu.yml`)
  from `xnu/patches/` — it needs Apple's `iig` and the closed KDK libraries, so
  the final link is **macOS-only**. Use `gh` for builds and logs.
- **Before spending a CI run**, validate locally: `python3 tools/check-hunk-counts.py
  xnu/patches` and compile-check with `tools/xnu-cc.py <ci-run.log> <buildtree/>
  <source>` (system clang, seconds, no macOS). It catches almost everything that
  fails a CI build.
- **CI time is limited and the macOS runners are often at capacity.** Develop and
  validate patches locally, then **group** several into one CI build rather than
  one build per patch.
- New runtime behavior should be **opt-in** (a boot-arg or compile gate) and
  **fail closed**; re-verify any hardware constant against a public source
  (e.g. a6xx.xml) rather than copying it from a different GPU generation.

## Device & destructive-step safety

- Device bring-up uses temporary `fastboot boot` images. Preserve partition
  backups.
- The user approved (2026-10-15) using internal UFS for iOS and said Android may
  be deleted: the iOS root goes into the existing `userdata` partition (no GPT
  changes). **Flashing erases `userdata`.** Keep bootloaders, recovery, modem,
  `persist` and the backups intact, and **confirm each destructive step with the
  user before running it**.

## Out of git

Keep device dumps, serial numbers, and downloaded Apple artifacts out of git.
The same goes for vendor firmware obtained for connectivity bring-up (WCN3990
Wi-Fi/BT firmware and `board-2.bin`, Bluetooth NVM) — obtain it independently and
keep it under ignored local paths.
