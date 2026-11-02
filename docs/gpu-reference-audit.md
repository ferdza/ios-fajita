# ios-fajita GPU — comparaison avec les références (audit)

Références lues : **UniXNU/Adreno740** (XNU + Adreno a7xx, Xiaomi Pad),
**Cam396/Snapintosh** (hyperviseur EL2 + stack Adreno Metal/IOGPU, macOS 27,
Snapdragon X2 a8xx), **msm/freedreno** (Linux, a6xx).

⚠️ **Caveat version XNU** : Adreno740 et Snapintosh sont du XNU *bien plus
récent* (macOS 26/27) et de l'Adreno a7xx/a8xx. On n'y copie **pas** d'API : on
en tire la *méthode* et les *séquences hardware*, adaptées à notre xnu-8796
(iOS 16) et à l'**a630/SDM845**. Les offsets de registres sont revérifiés sur
a6xx.xml (pas repris tels quels : ex. RBBM_SW_RESET_CMD = 0x043 chez nous, pas
0x073 comme l'a8xx de Snapintosh).

Notre cœur GPU = `bsd/dev/sweet_gpu.c` (bring-up a630, 3868 l.) + le user client
IOKit `iokit/Kernel/arm/SweetAdreno.cpp` + `SweetFramebuffer.cpp` (présentation).

---

## Finding 1 — Submit synchrone (sérialisation) → **CORRIGÉ (0198)**

**Notre code (avant)** : `sweet_gpu_submit` ET `gpu_cp_submit` finissaient par
`gpu_ring_wait_idle(...)` → le CPU *busy-wait* (delay()) jusqu'à ce que le GPU
draine TOUT le ring, à chaque frame. C'est de la sérialisation CPU↔GPU pure.

**Les refs** : msm `a6xx_submit`, Adreno740 `submitUnfenced`, Snapintosh
`adreno_ring_kick` → écrivent le ring, bougent le WPTR, **retournent tout de
suite**. La synchro se fait *plus tard* via la fence.

**Le fait clé** : notre client IOKit *sépare déjà* submit et attente
(`submit()` pose `r->fence`, puis `CPU_PREP`/`WAIT_FENCE` attend) — donc le
wait-idle dans submit était **redondant**. Probable gros contributeur au
« PowerPoint », en plus des flushes de cache réglés par 0195.

**Fix 0198** : `sweet_gpu_submit` retourne après le kick WPTR ; ajout de
`gpu_ring_reserve` (back-pressure : attend que le RPTR libère de la place,
car `gpu_ring_emit` wrap sans vérifier le RPTR — sûr seulement tant qu'on
drainait à vide). `gpu_cp_submit` (tests de boot) reste synchrone.

---

## Finding 2 — Aucune récupération de hang (le freeze) → **CORRIGÉ (0196+0197)**

**Notre code (avant)** : `gpu_ring_wait_idle` bouclait `100000 × 1 ms` = **100 s
de busy-wait** si le CP était bloqué, puis `sweet_gpu_hang_dump` qui *ne reset
rien*. → freeze total jusqu'au reboot.

**Les refs** : Adreno740 `recover()` + Snapintosh `adreno_recover()` = séquence
mûre : halt bus → reset cœur → ré-init CP → avance fence → replay/resubmit,
avec garde fail-closed et rate-limiting.

**Fix 0196** : plafond du busy-wait à 3 s (msm hangcheck = 500 ms) → un wedge
devient un stall borné, pas un freeze de 100 s.

**Fix 0197** (`sweet_gpu_recover`, gated `gpurecover=1`, OFF par défaut) :
halt SQE + halt VBIF (ack best-effort) → **RBBM_SW_RESET** du cœur GPU (le GMU
reste debout : un hang CP ne wedge pas le GMU) → `gpu_cp_hw_init` + `gpu_cp_start`
→ recharge du **zap shader** (resort du mode sécurisé) → avance du slot fence à
la dernière seq soumise (débloque tous les waiters) → `gpu_lost=false`.
**Fail-closed** (toute étape qui ne settle pas ⇒ GPU déclaré lost, pas de
boucle) et **rate-limité** (32 resets/boot). Câblé dans `waitFenceCall` et à
l'échec de `gpu_ring_reserve`.

Leçons des refs intégrées : halt du bus **avant** reset (sinon des écritures
GPU en vol corrompent la mémoire après reset) ; garde fail-closed ;
rate-limiting ; reset du **cœur** (pas du GMU).

---

## Finding 3 — Cohérence cache sur lecture-retour GPU→CPU → **à surveiller**

`sweet_gpu_cache_sync` = juste une barrière `dsb sy`. Correct pour nos buffers
**non-cachés / write-combined** (arène + BOs GEM depuis 0195). Les refs
(Adreno740 `makeWriteCombined`, `INVALIDATE` dans Snapintosh adreno-ib) font un
`dc ivac` *seulement* pour les BOs **cacheables** relus par le CPU après une
écriture GPU. Chez nous les **surfaces d'affichage restent cacheables**
(0195 ne touche que les BOs GEM) : si le CPU relit une surface écrite par le GPU
sans invalidation, il peut lire du cache périmé. À vérifier sur device (bugs
graphiques résiduels, fond d'écran). Piste : invalidation ciblée dans le chemin
de présentation, ou passer les surfaces en WC comme les BOs.

## Finding 4 — Comportement SMMU sur faute → **noté (hors de notre contrôle)**

Adreno740 : `stall_on_fault=0, continue_after_fault=1` → une faute d'accès ne
wedge pas le GPU. Chez nous, stage 3c laisse le SMMU au **stream table de
l'hyperviseur** — on ne configure pas le context bank, donc on ne peut pas
changer ce comportement facilement. Si le SMMU *stalle* sur faute, un seul
mauvais accès peut provoquer le hang (→ freeze). À confirmer ; sinon la
récupération 0197 est le filet de sécurité.

Bon point : Adreno740 dit « FSR 0x400 = bit de format, pas une faute ». Notre
`sweet_gpu_hang_dump` teste bien `FSR & 0x2` (le vrai bit de faute), pas 0x400 —
pas de fausse alerte de ce côté.

## Finding 5 — Durcissement récupération (si 0197 insuffisant sur device)

Si le RBBM_SW_RESET seul ne suffit pas (le GPU ne revient pas), le chemin de
durcissement, d'après Snapintosh `adreno_recover` : reset **médié par le GMU**
+ drain complet des transactions de bus (halt GBIF/VBIF *acquitté par étapes*),
clear des fautes W1C avant reset, et vérification d'intégrité de l'image SQE
(hash) avant d'écrire. Masque VBIF à confirmer (0xf supposé pour a630).

---

## Qualité / méthode retenue des refs

- **Build local** : `tools/xnu-cc.py` (amélioré, commit 729b5d7) valide chaque
  patch en quelques secondes avec clang système + un `buildtree` CI → on ne
  gâche plus un run CI sur une erreur de compil. Le kernel *final* flashable a
  encore besoin du CI macOS (iig + libs KDK fermées d'Apple).
- **Opt-in gate** (boot-arg), **fail-closed**, **rate-limit**, **provenance**
  des constantes hardware, **pas de constante inventée** (offsets a6xx
  revérifiés sur a6xx.xml).

## Plan CI (groupé — un seul build)

Branche `fix/surface-row-align-64` = **0195 + 0196 + 0197 + 0198**. Un seul
build CI les livre tous. Tests device, dans l'ordre :
1. Sans `gpurecover` : vérifier la **fluidité** (0195 WC + 0198 async → plus de
   PowerPoint) et que le stall sur hang est borné (~3 s, 0196) et non 100 s.
2. Avec **`gpurecover=1`** : vérifier que ça **récupère** au lieu de freezer.

Boot-args : `...adreno=9 zap=1 gpuhold=1 metalplugin=1` (+ `gpurecover=1` pour
le test 2). ARENA_MIB=40.
