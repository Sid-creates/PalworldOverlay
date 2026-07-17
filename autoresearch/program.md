# autoresearch (PalworldAssist)

Karpathy-style autonomous improvement loop for Lifmunk/effigy tracking.

## Setup

1. **Run tag**: `jul16` → branch `autoresearch/jul16`
2. **In-scope files** (read these):
   - `autoresearch/program.md` — this file
   - `autoresearch/bench.mjs` — **READ-ONLY** evaluation harness
   - `companion/shared/relicTracking.js` — **THE ONLY FILE YOU EDIT**
   - `companion/src/lib/relicTracking.test.ts` — must keep passing (crash gate)
3. **Initialize** `autoresearch/results.tsv` with header only (leave untracked)
4. Confirm setup, then kick off experimentation. Do not wait for further human approval after that.

## What you CAN do

- Modify `companion/shared/relicTracking.js` only: constants, algorithms, helpers, exports used by the bench.
- If you add/rename exports, update `companion/shared/relicTracking.d.ts` in the **same commit** (typing only — no logic there).

## What you CANNOT do

- Modify `autoresearch/bench.mjs` (evaluation ground truth).
- Weaken or delete tests to inflate the score.
- Install new packages.
- Edit the Lua bridge in this loop (port winning constants later in a separate human-facing change).
- Commit `autoresearch/results.tsv` or `autoresearch/run.log`.

## Goal

**Maximize `score:`** (higher is better).

The bench simulates pickup / present / possess / false-positive scenarios against the pure tracking helpers. It also micro-benchmarks hot paths. Fixed wall budget: the harness always finishes in a few seconds (not 5 minutes — this domain verifies cheaply).

Secondary soft constraints (printed, not the keep rule):
- `bench_ms:` — prefer not to explode
- `false_pos:` — high false positives should hurt the score (already baked in)

**Simplicity criterion**: All else equal, simpler is better. Tiny gains with ugly complexity → discard. Equal score with less code → keep.

## First run

Always establish baseline: run the bench on current `relicTracking.js` with no edits, commit that as baseline if needed, log it.

## Output format

```
---
score:            0.000000
pickup_f1:        0.000000
present_hit:      0.000000
possess_hit:      0.000000
false_pos:        0.000000
bench_ms:         0.0
cases_pass:       0
cases_total:      0
```

Extract with:

```
rg "^score:" autoresearch/run.log
```

## Logging results

Append to `autoresearch/results.tsv` (TAB-separated):

```
commit	score	bench_ms	status	description
```

status: `keep` | `discard` | `crash`

## The experiment loop

LOOP FOREVER on branch `autoresearch/jul16`:

1. Note current git HEAD (best-so-far).
2. Hack `companion/shared/relicTracking.js` with one coherent experimental idea.
3. `git add` that file (+ `.d.ts` if needed) and `git commit`.
4. Run: `node autoresearch/bench.mjs > autoresearch/run.log 2>&1`
5. Also run: `npm --prefix companion test > autoresearch/test.log 2>&1`
   - If tests fail → treat as crash (fix + revert), unless you can fix a dumb typo in one retry.
6. `rg "^score:|^false_pos:|^bench_ms:" autoresearch/run.log`
7. Append a row to `autoresearch/results.tsv` (do not commit it).
8. If `score` improved (strictly higher than best-so-far) → **keep** (advance HEAD).
9. If equal or worse → **discard**: `git reset --hard <best-so-far>`.

**Keep rule refinement**: If `score` ties the best-so-far, keep only when the diff clearly simplifies code (net lines deleted without new abstractions). Otherwise discard.

When correctness saturates, the score still moves via `bench_ms` (faster ⇒ higher). Prefer speed/simplicity experiments, or ask the human to raise the eval ceiling in `bench.mjs` (humans may edit the harness; the agent may not during a run).

**NEVER STOP**: Do not ask the human whether to continue. Do not offer stopping points. Keep inventing hypotheses until manually interrupted. If stuck, re-read this file and the bench scenarios, combine near-misses, try radical but still single-file changes.

## Hypotheses worth exploring

- Confirm radii / sticky drop / present near / possess pick distances
- Multi-frame disappearance confirmation (miss N scans before collect)
- XY-only keys vs XYZ (Z jitter false misses)
- Weighted present scoring (prefer unmarked seeds near player)
- Possess inference with 2nd-nearest fallback / Z-aware match
- Hot/cold cadence thresholds
- Deduping / watch eviction policy under PRESENT_MAX pressure
- Resilience to `0,0,0` and combat location jitter
