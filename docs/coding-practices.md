# Coding practices for this repo — the dumb, blunt version

A short rulebook for whoever (human or AI) touches `ios-fajita`. It is written
**blunt on purpose**: "pense bête". Every rule here is paid for by a real mistake
made on this project, named in the entry. When in doubt, pick the boring option.

The one-line version: **don't guess, don't be clever, fail closed, prove it.**

---

## 1. Don't guess a hardware constant — read it from a public source

A register bit, an event number, a cache opcode: look it up, paste the source,
then use it. Numbers from a different chip generation are wrong even when they
look right.

- **What it cost us:** I once "remembered" SMMU `SCTLR` bit 5 as stall-on-fault.
  Wrong — bit 5 is `CFRE`, stall-on-fault (`CFCFG`) is bit 7. The whole theory
  built on top of it was junk until I re-read the Arm SMMU bits and the `FSR`.
- **The a7xx trap:** event `0x31` is `CACHE_CLEAN` on a7xx but `CACHE_INVALIDATE`
  on our a6xx. Copying a value from a newer Adreno because "it's the same family"
  corrupts silently.
- **Rule:** every hardware constant gets a comment with its source
  (`a6xx.xml`, the Arm SMMU spec, the msm driver). No source → don't commit it.
  This is already in `AGENTS.md`; it is rule #1 because it is the easiest to break.

## 2. Read the code before you theorise about it

Grep the actual line before you write a paragraph explaining what it does.

- **What it cost us:** the GPU audit's central theory was "the client maps the
  ring cacheable, the kernel only barriers, so the GPU reads stale descriptors."
  One `grep` of `sweet_drm.c` showed the shim maps **write-combine**
  (`kIOMapWriteCombineCache`). The theory was dead on arrival; I'd written pages
  before checking one line. The real bug was a shader faulting on a wild IOVA.
- **Rule:** before explaining behaviour, quote the line (`file:line`). A claim
  about code with no `file:line` behind it is a guess wearing a lab coat.

## 3. Fail closed, make it opt-in

New runtime behaviour is OFF by default, gated by a boot-arg or compile flag, and
when unsure it does nothing rather than something.

- **What it cost us:** `0199` turned on `HUPCF` (continue-after-fault) so the GPU
  would run past a fault. It ran past the fault straight into corrupted memory and
  **panicked the kernel on the device**. `0201` put recovery and HUPCF back OFF by
  default. A faulting GPU that stops is a bug report; one that continues is a
  crash.
- **Rule:** default state is the safe one. The experiment lives behind
  `gpu<thing>=1`. If the flag is absent, behave like before the patch existed.

## 4. Prove the compile locally before you spend a CI run

The macOS/arm64e link is the only thing that truly needs CI. Everything short of
it can be checked on this Linux box in seconds.

- **The tools:** kernel → `tools/xnu-cc.py <ci.log> <buildtree> <source-substring>`
  (system clang, no macOS) and `tools/check-hunk-counts.py xnu/patches`. GPU
  driver → `ferdza/chlorophyll`'s `turnip/host-check.sh` (compiles Turnip + the
  AIR frontend + ir3 on Linux).
- **What it cost us:** a CI run died on the `renegade` step; building it locally
  (55 s) showed the code was fine and the runner's environment was the problem —
  a diagnosis that would have cost several macOS runs if done by re-triggering CI.
- **Rule:** green local check first, then **group** several patches into one CI
  run. macOS runners are expensive and often at capacity (see `AGENTS.md`).

## 5. Say "I was wrong" fast, in writing

When a theory dies, kill it loudly where it was written, and say what replaced it.
Do not quietly edit it away or, worse, defend it.

- **What it cost us:** nothing — because when the coherency theory and the SMMU
  bit were wrong, I put a `CORRECTION:` block right in the doc and re-oriented.
  That is the behaviour to keep. The failure mode to avoid is doubling down to
  look consistent.
- **Rule:** a withdrawn claim gets a dated correction next to it, not a delete.
  The repo's value is an honest trail, not a clean-looking one.

## 6. Measure before you optimise; don't call the wrong thing slow

- **What it cost us:** I blamed `IOLog` for the "powerpoint" slowness. But logging
  is muted once the GUI presents (`sweetfb_noconsole=1`), so it cost microseconds,
  not milliseconds. The real costs were elsewhere (arena flush, per-pixel convert).
  Guessing the hot spot wasted a ranking.
- **Rule:** a performance claim needs a number. "This is slow" without a
  measurement is a hypothesis, label it as one.

## 7. Separate observation from guess, everywhere

In commits, docs, and chat: what the hardware **did** vs what you **think** it
means are different kinds of sentence. `AGENTS.md` demands it; it is here because
it is the habit that makes all the rules above possible.

- **Rule:** "FSR read back `0x402`" is an observation. "so the GPU faulted on a
  descriptor" is a guess. Never let the second borrow the authority of the first.

## 8. Don't rewrite shared history

Never force-push or rewrite commits that aren't yours without the user saying
"réécris l'historique" (or equivalent) in plain words.

- **Rule:** your commits, your attribution. The user's commit `16f8ba6` stays
  exactly as it is unless they tell you otherwise. A stop-hook complaining about
  unpushed commits is usually a stale tracking ref, not a reason to rewrite.

## 9. Reuse the proven thing instead of inventing

Before writing a driver/shim/stack from scratch, find the project that already
made it work on this exact SoC and copy the shape.

- **What it bought us:** Bergamota already proved Turnip on the A630
  (same SDM845/Adreno 630). We reused the kernel and adopted its `MSM_PARAM`
  values rather than re-deriving them. The connectivity plan leans on Snapintosh
  (XNU Qualcomm Wi-Fi) and Linux `ath10k_snoc`/`hci_qca` the same way.
- **Rule:** "who already did this on a630/SDM845?" is the first research question,
  not the last. A working reference beats a clever idea.

---

### The checklist before you commit

- [ ] Every magic number has a source comment.
- [ ] Every claim about existing code cites `file:line`.
- [ ] New behaviour is opt-in and fails closed.
- [ ] Local compile-check is green (`xnu-cc.py` / `host-check.sh`).
- [ ] Observations and guesses are labelled as such.
- [ ] `NOTES-FAJITA.md` + the relevant `docs/` page updated (handoff rule).
- [ ] You didn't touch commits that aren't yours.
