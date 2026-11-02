# Recherche & projets similaires

Le paysage des efforts « XNU / macOS / Adreno hors matériel Apple », ce que
chacun apporte, et **ce qu'on en tire** pour ce projet. Rappel : les offsets de
registres et séquences hardware sont **revérifiés sur source publique**
(a6xx.xml), jamais copiés aveuglément — les versions XNU et les générations GPU
diffèrent.

---

## Notre lignée directe

### ios-sweet (dipa-studio)
La base iOS 16 / XNU dont ce dépôt est un fork. Fournit l'ossature du port
(shim, ADT, UFS, display, la série de patchs). Historique conservé dans
`docs/IOS16_README.md`.

### Bergamota & Chlorophyll (ry-diffusion)
Le **même SoC que nous** : SDM845 / Adreno 630.
- **Bergamota** : le bring-up kernel GPU a630 et le **user client IOKit
  compatible msm**. C'est la fondation de notre `sweet_gpu.c` / `SweetAdreno.cpp`.
- **Chlorophyll** : le driver **Metal** userspace = Mesa/freedreno (ir3) habillé
  en Metal, AIR→NIR→ir3. C'est le driver **libre** qu'on garde.
→ *On en tire* : l'essentiel de l'architecture GPU. Notre travail récent est la
colle kernel autour (perf + récupération).

### HackiOS (`oosexgang`)
L'« échelle » de bring-up Adreno (stages 1→8) que le GPU suit. Même famille
SDM845/a630.
→ *On en tire* : l'ordre et les preuves de chaque étage de bring-up.

## Références pour la perf & la récupération GPU

### msm / freedreno (Linux, a6xx)
Le driver noyau Linux de référence pour Adreno a6xx (dont a630). Source des
séquences canoniques : `a6xx_submit` (soumission async + fence), `a6xx_recover`,
`a6xx_bus_clear_pending_transactions` (halt VBIF/GBIF avant reset), hangcheck
~500 ms, registres (a6xx.xml → offsets vérifiés, ex. `RBBM_SW_RESET_CMD=0x043`).
→ *On en tire* : submit asynchrone (0198), halt bus avant reset, hangcheck borné
(0196), les bons offsets a630.

### UniXNU / Adreno740
XNU + Adreno **a7xx** (Xiaomi Pad), **Metal natif**. XNU bien plus récent que le
nôtre : on n'y copie **pas** d'API. Son PR « GPU restart/recovery + system-memory
BOs » adresse nos deux problèmes exacts.
→ *On en tire* : la **méthode** de récupération (hangcheck → recover_worker →
marquer la VM en faute, avancer la fence, restart, rejouer), les **BOs en
write-combined** par défaut (validé notre 0195), SMMU `stall_on_fault=0 /
continue_after_fault=1`, et « FSR 0x400 = bit de format, pas une faute ».

### Cam396 / Snapintosh
Hyperviseur EL2 + **stack Adreno Metal/IOGPU sur macOS 27**, Snapdragon X2 Elite
(a8xx). Reco de l'utilisateur. Module de récupération mûr (`adreno_recover` dans
`compat/adreno-ib.c`) : garde **fail-closed**, **rate-limiting**, halt bus
acquitté par étapes, clear des fautes W1C, vérification d'intégrité de l'image
SQE avant d'écrire. Son `AGENTS.md` est aussi un excellent **standard de
qualité** (opt-in gates, provenance des constantes, host-first validation).
→ *On en tire* : la structure fail-closed + rate-limit de notre `sweet_gpu_recover`
(0197), le halt bus avant reset, et la discipline qualité générale. Caveat : a8xx
≠ a630 (ex. `RBBM_SW_RESET_CMD` 0x073 chez eux vs 0x043 chez nous → revérifié).

## Comment on applique tout ça

Voir [`gpu-reference-audit.md`](gpu-reference-audit.md) pour la comparaison
ligne-à-ligne (notre code vs les refs, findings priorisés) et
[`gpu-progress.md`](gpu-progress.md) pour la série de patchs et leur état.

Principe retenu, à la NVIDIA open modules sur macOS : **garder le cœur
open-source** (freedreno/Chlorophyll, qui fait que l'UI s'affiche) et **réécrire
la colle kernel** (submit/fence/cache/recovery) — pas de réécriture du driver.
