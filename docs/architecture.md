# Architecture — les grosses pièces

Vue d'ensemble des composants du projet : ce que chacun fait, où il vit, et
comment ils s'enchaînent. Pour les détails bas niveau voir
[`NOTES-FAJITA.md`](../NOTES-FAJITA.md) et [`PORTING.md`](../PORTING.md).

```
  bootloader OnePlus (ABL, fastboot)
        │  charge boot_a (ou `fastboot boot` temporaire)
        ▼
  shim/  ── EL2/EL1 minimal, saute dans XNU, passe le payload
        │        payload = kernel + ADT + boot-args + blobs sweetfwN
        ▼
  XNU (xnu-8796, patché)  ── bsd/ iokit/ osfmk/ …
   ├─ UFS host driver ───────── monte la racine HFS+ dans `userdata`
   ├─ Display (IOSurface + IOMobileFramebuffer / AppleCLCD, panneau iPhone X)
   ├─ Touch RMI4 (I²C) + boutons PM8998 (SPMI)  → HID
   └─ GPU Adreno 630
        ├─ bsd/dev/sweet_gpu.c ───── bring-up + ring + fence + recovery
        ├─ iokit/.../SweetAdreno.cpp ─ user client compatible msm
        └─ iokit/.../SweetFramebuffer.cpp ─ présentation (vsync, swap)
        ▼
  iOS 16.7.16 userland (iPhone X, non modifié)
   ├─ launchd + daemons + backboardd + SpringBoard
   └─ Chlorophyll (driver Metal) ── AIR→NIR→ir3 (freedreno) → le user client
```

---

## 1. La chaîne de boot (`shim/`, payload, ADT)

Le bootloader OnePlus (ABL) accepte un **boot image header v1** : `Image.gz`
(gzip) + DTB appondu. Un header v2 ou un `Image` brut est rejeté. Notre image
contient un **shim** : il met en place un environnement EL2/EL1 minimal et saute
dans XNU en lui passant un **payload** :

- le **kernel** (`kernel.development.sweet`),
- l'**ADT** (Apple Device Tree, construit par `tools/mkadt.py` — c'est le device
  tree qu'XNU attend, pas le DTB Linux),
- les **boot-args** (`CMDLINE`),
- des **blobs firmware** annoncés `sweetfwN=<pa>:<size>` : `a630_gmu.bin`, le bloc
  mémoire GMU, l'**arène** de buffers GPU (voyage en RAW dans l'image, d'où la
  limite ~44 MiB sur `boot_a` ~64 MiB), et le pool de tables de pages.

Outils : `tools/build-fajita.sh` (orchestre), `tools/mkadt.py`,
`tools/mkpayload.py`, `shim/build.sh`.

## 2. Le port XNU (`xnu/patches/`)

XNU iOS 16 (xnu-8796) buildé par GitHub Actions via `blacktop/darwin-xnu-build`
(runner macOS : il faut `iig` d'Apple et les libs KDK fermées → link macOS
obligatoire). Toute la personnalisation est une **série de patchs numérotés**
dans `xnu/patches/`, appliqués dans l'ordre par `git apply`. Config kernel
`MACHINE_CONFIG=SWEET`, arm64 simple (pas arm64e/ptrauth).

Validation locale avant CI : `tools/xnu-cc.py` (voir
[`gpu-progress.md`](gpu-progress.md)) rejoue les commandes de compil avec un
clang système → attrape compil + link en quelques secondes.

## 3. Stockage (UFS, racine HFS+)

Driver hôte UFS maison. La racine iOS est un volume **HFS+ journalisé** logé
**dans la partition `userdata`** (décision 2026-10-15 : pas de modif GPT ;
flasher écrase `userdata`). Construite par `tools/mkiosroot.sh` depuis l'IPSW
iPhone X (OS/SystemOS/AppOS + shared cache + apps).

## 4. Affichage (IOSurface, IOMobileFramebuffer, AppleCLCD)

Services kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`), présentés comme un
**panneau iPhone X**. C'est ce qui permet à CoreAnimation de composer. La
présentation GPU passe ensuite par `SweetFramebuffer.cpp` (pièce 7).

## 5. GPU — cœur kernel (`bsd/dev/sweet_gpu.c`)

Le bring-up Adreno 630 en étages (boot-arg `adreno=1..9`) : power/clocks (2),
firmware GMU + HFI (3), GX rail/SPTPRAC (5), zap signé via TrustZone (6),
command processor `hw_init`/`CP_ME_INIT` (7), keep-alive + espace d'adressage
client 1 GiB + submit « command buffer + fence » + arène de buffers (8). Puis,
en service : l'anneau PM4 (`gpu_ring_emit`/`flush`), les fences
(`sweet_gpu_fence_*`, slot écrit par `CACHE_FLUSH_TS`), la soumission
(`sweet_gpu_submit`, **asynchrone** depuis 0198 + back-pressure
`gpu_ring_reserve`), le dump de hang et la **récupération** (`sweet_gpu_recover`,
0197). Détails et série de patchs : [`gpu-progress.md`](gpu-progress.md).

## 6. GPU — user client IOKit (`iokit/Kernel/arm/SweetAdreno.cpp`)

La surface **compatible msm** qu'un driver userspace ouvre : `GEM_NEW`/`INFO`/
`SUBMIT`/`CPU_PREP`/`WAIT_FENCE`/`close`, les BOs (write-combined depuis 0195),
l'espace d'adressage GPU, et la détection+récupération de hang câblée dans
`waitFenceCall`. C'est l'ABI que Mesa/freedreno attend.

## 7. GPU — présentation (`iokit/Kernel/arm/SweetFramebuffer.cpp`)

Le timer vsync (60 Hz) notifie CoreAnimation ; `swap()` marque la frame, et la
présentation n'a lieu que sur une **frame complète** (fence done — 0194), ce qui
a supprimé l'affichage de frames à moitié rendues. Throttle panneau `sweetfb_hz`.

## 8. Metal userspace (Chlorophyll / Bergamota)

**Chlorophyll** = Mesa **freedreno** (compilateur ir3, cible a630) habillé en
driver **Metal** d'Apple : `libbgair.dylib` fait AIR→NIR→ir3. **Bergamota** =
la partie kernel GPU côté bring-up. Le bundle **SweetBGMTL.bundle** est le plugin
Metal, chargé par `metalplugin=1`. C'est le driver **libre** qu'on garde ; le
travail récent est la **colle kernel** autour (submit/fence/cache/recovery), pas
une réécriture du driver.

## 9. Entrées (tactile, boutons)

Tactile **RMI4 sur I²C** (`0x20`, SE `0xa90000`) avec activation du rail, livré
en événements HID digitizer. Boutons power/volume via **PM8998** (SPMI, usages
`0x30`/`0xe9`/`0xea`). Identité device = iPhone X (`iPhone10,3`/D22) pour
qu'UIKit prenne l'UI gestuelle.

## 10. Logs & diagnostic

Ring buffer persistant dans `userdata` + flush sur panic ; pull via OrangeFox
(`tools/sweet-log-pull.sh`), filtré par `tools/sweet-log.py`. Le panneau est la
première console (`sweetfb_noconsole` la coupe au premier swap pour laisser la
GUI). Après un hang dur, une **photo du panneau fait foi** (le ring peut être
périmé si le panic est arrivé pendant un flush).

## 11. Sécurité (stubs)

AMFI, sandbox et signature de code sont des **stand-ins permissifs** — ce n'est
pas un iOS sécurisé. L'horloge démarre en 1969 (tout ce qui vérifie un certificat
voit une date invalide).
