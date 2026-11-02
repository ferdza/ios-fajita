# GPU / Metal — journal de progression et trouvailles

Doc de travail vivante sur l'accélération GPU (Adreno 630 / SDM845). Pour
l'historique exhaustif (registres, traps) voir [`NOTES-FAJITA.md`](../NOTES-FAJITA.md) ;
pour la comparaison avec les autres projets voir [`gpu-reference-audit.md`](gpu-reference-audit.md).

État au **2026-11-02**. Toute ligne « device » non datée = **pas encore vérifiée sur
le téléphone** (observation vs supposition distinguées).

---

## Où on en est

Le chemin **Metal est fonctionnel** : CoreAnimation rend l'interface iOS via le GPU
(Chlorophyll = Mesa/freedreno ir3 habillé en driver Metal, côté kernel Bergamota +
le user client IOKit compatible msm). Sur device l'UI s'affiche **correctement**
(icônes nettes, dock, status bar — photo 2026-11-02).

Deux problèmes restaient, tous deux attaqués par la série 0193–0198 :
- **Lenteur** (« PowerPoint ») — cache + sérialisation du submit.
- **Freeze** sur hang GPU — busy-wait de 100 s + aucune récupération.

## La série de patchs GPU (sur la base 0193–0194 déjà validée device)

| Patch | Fait quoi | Risque | État |
| --- | --- | --- | --- |
| 0193 | Aligne le pitch des surfaces sur 64 (freedreno refusait les masques d'icônes) | faible | ✅ device (refus 39→2) |
| 0194 | Ne présente que les frames complètes (fence done) au lieu d'attendre 50 ms | faible | ✅ device (UI correcte) |
| 0195 | BOs GEM en **write-combined** (plus de flush par-ligne des framebuffers débordés) | faible | 🔨 à tester device (vitesse) |
| 0196 | Plafonne le busy-wait du drain ring à **3 s** (était 100 s = le freeze) | faible | 🔨 à tester device |
| 0197 | **Récupération de hang** : reset cœur GPU (RBBM_SW_RESET) + ré-init CP + recharge zap + avance fence. Fail-closed, rate-limité (32/boot). **ON par défaut**, `gpurecover=0` pour désactiver | moyen | 🔨 à tester device |
| 0198 | **Submit asynchrone** : plus de wait-idle dans le submit Metal (le client attend la fence lui-même) + back-pressure ring `gpu_ring_reserve` | moyen | 🔨 à tester device |

Base kernel assemblée depuis le buildtree CI + git apply ; chaque patch
**compile-vérifié en local** (`tools/xnu-cc.py`) avant tout run CI.

## Trouvailles clés (de la comparaison avec les refs)

- Le submit Metal **attendait le drain complet du ring à chaque frame** →
  sérialisation CPU/GPU. Le client sépare déjà submit et WAIT_FENCE, donc le
  wait-idle était redondant (→ 0198).
- `gpu_ring_emit` wrap le wptr **sans vérifier le rptr** : sûr seulement tant
  qu'on drainait à vide ; en async il faut une back-pressure (→ 0198).
- Le bon reset pour un hang **CP** est le soft-reset du **cœur GPU**
  (RBBM_SW_RESET), pas le SYSRESET du **GMU** (qui réinitialiserait le
  microcontrôleur). Offset a630 = `0x043` (≠ `0x073` de l'a8xx de Snapintosh —
  revérifié sur a6xx.xml, jamais inventé).
- Halter le bus (VBIF) **avant** le reset, sinon des écritures GPU en vol
  corrompent la mémoire après reset.
- `sweet_gpu_hang_dump` lit déjà le bon bit de faute SMMU (`FSR & 0x2`), pas le
  bit de format `0x400` — pas de fausse alerte.

## À vérifier / décider sur device

- **Surfaces cacheables** (Finding 3) : si le CPU relit une surface écrite par le
  GPU, risque de cache périmé (wallpaper qui ne charge pas, bugs graphiques ?).
  Deux options (WC vs invalidation ciblée) — **on tranche après le test device**.
- **SMMU stall on fault** (Finding 4) : si le SMMU stalle sur faute, un mauvais
  accès peut provoquer le hang. Context bank détenu par l'hyperviseur → difficile
  à changer ; 0197 est le filet.
- **Durcissement récup** (Finding 5) : si RBBM_SW_RESET seul ne ramène pas le
  GPU, passer au reset médié GMU + drain de bus acquitté (façon Snapintosh).

## Cap long terme

Chantier perf plus ambitieux : **multi-ring / soumission concurrente** (façon
UniXNU/Adreno740). Le user client a déjà une notion de `queueid` — point
d'accroche. Gros chantier, à concevoir avant de coder.

## Journal de test device

| Date | Kernel (SHA court) | Boot-args | Résultat |
| --- | --- | --- | --- |
| 2026-11-02 | 0193+0194 | adreno=9 zap=1 gpuhold=1 metalplugin=1 | UI correcte mais « PowerPoint » + freeze sur hang |
| _à remplir_ | 7147885 (0193→0198) | …metalplugin=1 (+ `gpurecover=1`) | _en attente du test_ |

> Kernel 0193→0198 : run CI `41540055327`, SHA256
> `7147885556c48c3128add8ca515985604e469c4b16ce10ecc9073424cabd4255`.
> ⚠️ Construit avant que 0197 passe en ON-par-défaut : pour ce binaire précis,
> ajouter `gpurecover=1` pour tester la récupération. Le prochain build l'aura
> activé par défaut.
