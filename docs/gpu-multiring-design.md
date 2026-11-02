# Design — soumission concurrente / multi-ring (a630)

Design du chantier perf long terme choisi : plusieurs files de soumission, pour
que l'UI (compositeur, SpringBoard) ne soit pas bloquée derrière un gros rendu
d'app. **Document de conception — pas encore implémenté.** À confronter aux
résultats device de 0193→0198 (si le submit async mono-ring 0198 est déjà
fluide, la partie HW préemption n'est pas urgente).

Refs : UniXNU/Adreno740 (recover/preempt multi-ring, a7xx), Snapintosh
(a8xx), msm/freedreno a6xx. Voir [research-and-similar-projects.md](research-and-similar-projects.md).

---

## 1. Ce que ça apporte (et ce que ça n'apporte pas)

- **Apporte** : de la **priorité/réactivité**. Le compositeur peut passer devant
  un rendu d'app long → l'UI reste réactive même quand une app charge le GPU.
- **N'apporte pas** : du débit brut sur une seule charge. Pour un seul rendu,
  un ring suffit. Le gain mono-charge vient déjà de 0195 (WC) + 0198 (async).

Donc : **à juger après le test de 0198.** Si mono-ring async est fluide pour
l'usage UI, ce chantier est un « nice-to-have » de réactivité, pas une urgence.

## 2. Ce que notre code a déjà

- Le user client IOKit expose déjà une notion de **`queueid`** (`QUEUE_IDS`,
  masque `fQueues` dans `SweetAdreno.cpp`) — point d'accroche naturel.
- Un **seul ring** (`gpu_cp_wptr`, `GPU_CP_RING`), un **seul compteur de fence**
  (`gpu_cp_seq`), un slot de fence dans le scratch, un seul espace d'adressage.
- Submit **asynchrone** + back-pressure `gpu_ring_reserve` (0198), et une
  **récupération** mono-ring (`sweet_gpu_recover`, 0197).

## 3. Grounding matériel — ⚠️ risque a630

La préemption Adreno **open-source n'est prouvée que sur a7xx+** (les séries msm
sont intitulées « preemption for A7XX targets », activées sur a750/a7xx testés).
Nos deux refs qui préemptent sont a7xx (Adreno740) et a8xx (Snapintosh). Pour
**a630** (SDM845), la préemption HW existait en **downstream CAF/Qualcomm** mais
n'est pas bien documentée en OSS. Incertitudes à lever avant de s'engager :

- le firmware **SQE** qu'on charge supporte-t-il `CP_CONTEXT_SWITCH` sur a630 ?
- layout exact du **preempt record** a630 (WPTR sauvé, SMMU info, GPU_RO) ;
- registres `CP_CONTEXT_SWITCH_CNTL` (niveau ringbuffer) — offsets à **revérifier
  sur a6xx.xml**, jamais repris d'un a7xx.

Conclusion : ne pas porter directement la préemption HW d'un ref a7xx. Approche
**étagée**, le niveau sûr d'abord.

## 4. Design étagé

### Étage A — multi-queue logiciel → un seul ring (sûr, d'abord)
Pas de préemption HW. Le kernel ordonne plusieurs files client dans **le ring
unique**, par priorité :

- Par `queueid`, une petite structure de file (priorité, dernière fence).
- `sweet_gpu_submit(queueid, …)` : au lieu d'émettre directement, **met en file**
  les IBs ; un **scheduler** vide les files vers le ring en respectant la
  priorité (compositeur > app), toujours en async + `gpu_ring_reserve`.
- **Espace de fences** : garder un compteur global `gpu_cp_seq` (comme
  Adreno740 : les rings partagent une numérotation), mais mémoriser la dernière
  fence par file pour `WAIT_FENCE`.
- Gain : l'ordre de soumission privilégie l'UI. Limite : ne **préempte pas** un
  IB déjà en vol (une frame d'app déjà soumise finit avant que l'UI passe).
- Risque : faible (on reste sur le modèle ring prouvé). Surtout du scheduling.

### Étage B — préemption HW ringbuffer (a630, avancé, optionnel)
Deux rings matériels + `CP_CONTEXT_SWITCH` pour que le GPU bascule sur le ring
haute priorité quand il a du travail, en préemptant le ring bas.

- Allouer un **2e ring** + un **preempt record** par ring (layout a630 à établir).
- Programmer `CP_CONTEXT_SWITCH_CNTL` (niveau ringbuffer), postambule qui reset
  les perf counters à la préemption (noté nécessaire par les revieweurs msm).
- Intégrer la **récupération multi-ring** façon Adreno740 (`recover` qui gère le
  ring fautif, avance les fences des deux, rejoue) — adapter à notre `sweet_gpu_recover`.
- Gain : vraie préemption (l'UI passe devant un rendu long en cours).
- Risque : **élevé sur a630** (firmware/record/registres non prouvés OSS). À ne
  tenter qu'après l'étage A, avec validation device prudente et un **gate**
  boot-arg (`gpupreempt=1`, OFF par défaut), fail-closed.

## 5. Ce qu'il faudrait toucher

| Zone | Étage A | Étage B |
| --- | --- | --- |
| `sweet_gpu.c` submit | mise en file + scheduler | + 2e ring, preempt record, CP_CONTEXT_SWITCH |
| fences | dernière fence par file | idem + fence par ring partagée |
| `SweetAdreno.cpp` | router par `queueid`, WAIT_FENCE par file | idem |
| recover (0197) | inchangé | étendre au multi-ring (modèle Adreno740) |
| boot-arg | — | `gpupreempt=1` (opt-in, fail-closed) |

## 6. Validation

- Étage A : compile-check local (`xnu-cc.py`), puis device — mesurer la
  **réactivité UI** sous charge (une app qui rend lourd pendant qu'on scrolle).
- Étage B : d'abord **confirmer le support préemption a630** (firmware SQE,
  registres) par un test minimal isolé (un `CP_CONTEXT_SWITCH` sur deux rings
  triviaux, lu en retour) **avant** toute intégration — comme les tests de boot
  existants (`gpu_cp_nop_test`, etc.). Si le HW ne suit pas, on reste à l'étage A.

## 7. Recommandation

1. Tester d'abord 0193→0198. Si l'UI est fluide, **étage A** suffit pour la
   réactivité sous charge — faible risque, gros confort.
2. N'aborder l'**étage B** (préemption HW a630) que si l'étage A ne suffit pas,
   avec un test de faisabilité isolé d'abord, car a630 n'est pas balisé en OSS.
