# Documentation — sommaire

Point d'entrée de la doc du projet (iOS 16 + Metal/Adreno 630 sur OnePlus 6T).

## Démarrer

- **[../README.md](../README.md)** — présentation, ce qui marche, build & flash,
  layout du dépôt. **À lire en premier.**
- **[../PORTING.md](../PORTING.md)** — notes hardware et plan de bring-up.
- **[../AGENTS.md](../AGENTS.md)** — règles de travail (handoff, commits,
  sécurité des étapes destructives).

## Vue d'ensemble

- **[architecture.md](architecture.md)** — **les grosses pièces** : chaîne de
  boot (shim/ADT/payload), port XNU, UFS, affichage, GPU kernel, user client
  IOKit, présentation, driver Metal userspace, entrées, logs, sécurité.

## GPU / Metal (le chantier actuel)

- **[gpu-progress.md](gpu-progress.md)** — journal vivant : série de patchs
  0193→0198 (ce que fait chacun + état), trouvailles, à-vérifier-sur-device,
  cap long terme, **journal de test**.
- **[gpu-reference-audit.md](gpu-reference-audit.md)** — comparaison de notre
  code avec les projets de référence, findings priorisés, ce qui est corrigé et
  ce qui reste.
- **[gpu-multiring-design.md](gpu-multiring-design.md)** — design du chantier
  long terme : soumission concurrente / multi-ring (étage logiciel sûr, puis
  préemption HW optionnelle), avec le risque a630 documenté.

## Recherche

- **[research-and-similar-projects.md](research-and-similar-projects.md)** — le
  paysage (ios-sweet, Bergamota/Chlorophyll, HackiOS, msm/freedreno,
  UniXNU/Adreno740, Snapintosh) et ce qu'on tire de chacun.

## Historique & référence profonde

- **[../NOTES-FAJITA.md](../NOTES-FAJITA.md)** — handoff de travail exhaustif :
  état, registres, traps, numéros, prochaines étapes (gros fichier).
- **[../NOTES.md](../NOTES.md)** — notes de la base ios-sweet.
- **IOS16_README.md** — historique de la base iOS 16 (s'il est présent).

## Outils clés

- `tools/xnu-cc.py` — **compile-check local** d'un patch kernel (secondes, sans
  macOS) avant de dépenser un run CI. Voir [gpu-progress.md](gpu-progress.md).
- `tools/build-fajita.sh` — construit le boot image (kernel + ADT + payload).
- `tools/check-hunk-counts.py` — vérifie que chaque patch s'applique en ordre.
- `tools/sweet-log-pull.sh` / `tools/sweet-log.py` — récupère et filtre le log.

---

État résumé (**2026-11-02**) : l'UI iOS est rendue par le GPU (Metal). Chantier
en cours = **vitesse** (0195 WC, 0198 submit async) et **freezes** (0196 cap du
wait, 0197 récupération de hang, ON par défaut). Kernel 0193→0198 = run CI
`41540055327`. Détails dans [gpu-progress.md](gpu-progress.md).
