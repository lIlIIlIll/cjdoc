# CI, Pages and release orchestration: measurements and decisions

This document records the measurements behind issue #82 (CI/Pages/Release
orchestration) and the decisions taken from them. It exists because several of
its items are measurement-first: an optimization is only allowed after the
stage data justifies it, and a decision *not* to change something has to be as
traceable as a change.

Only actually executed results are recorded. Every number names the run or
command it came from. Where a claim needs more samples than exist, the limit is
stated instead of a conclusion.

## Where the timing evidence comes from

| Source | What it carries |
| --- | --- |
| `scripts/ci_stage.py run` (used by `check.sh` and the workflows) | per-stage `wallMs`, exit status, identity, cache state; written to `$CJDOC_CI_EVIDENCE/stages.json` and uploaded as `ci-timing-*` |
| `showcase_build.stage_timing` | per-phase site-generation timings in `showcase-stages.json` (same artifact) |
| `scripts/ci_stage.py wallclock --run ID --attempt N` | job and step level wall clock read from the Actions API, including queueing and re-run gaps |
| `scripts/measure_sdk_install.py` | paired cold/warm samples of the two combined-SDK cache shapes |
| workflow Job Summary | the human-readable roll-up of the above |

The wall-clock reader retries transient API failures and decodes `gh api
--paginate` output as a stream, because a jobs listing is more than one page and
a large run otherwise loses its evidence on the first EOF.

## What the site-generation time is actually spent on

Real Pages run `38332333489`, attempt 1, artifact
`ci-timing-pages-assemble-38332333489-1` → `showcase-stages.json`.
`site-assemble` phase total: **415.5 s**.

| Phase | Wall | Share |
| --- | ---: | ---: |
| `showcase.api` (self-API generation) | 253.9 s | 61.1% |
| `showcase.authoring` | 29.2 s | 7.0% |
| `pocketkit.generate:*` (4 locale/version runs) | 60.2 s | 14.5% |
| `pocketkit.compose:*` (2) | 30.8 s | 7.4% |
| `showcase.legacy` | 6.5 s | 1.6% |
| `showcase.navigation` | 6.0 s | 1.4% |
| `showcase.link-validate` | 5.7 s | 1.4% |
| `showcase.offline-archive` | 4.6 s | 1.1% |
| `showcase.plan-baseline` | 4.5 s | 1.1% |
| `pocketkit.diagnostics:*` (2) | 6.5 s | 1.6% |
| `pocketkit.support-index` | 2.9 s | 0.7% |
| `showcase.reports` | 2.2 s | 0.5% |
| `pocketkit.check-modes` | 2.2 s | 0.5% |
| `pocketkit.diff:*` (2) | 0.2 s | 0.0% |
| `showcase.tool-versions` | 0.2 s | 0.1% |
| `showcase.site-copy`, `showcase.homepage`, `showcase.source-copy`, `showcase.downloads` | < 0.1 s each | < 0.1% |

This is the attribution item CI-06.1 asked for: the generation cost is
overwhelmingly one phase, and the remaining phases are an order of magnitude
smaller. "6 min 41 s" for site generation was never one uniform cost.

## CI-07.4: combined SDK cache shape

Two shapes were compared by `scripts/measure_sdk_install.py` (dispatch
`workflow_dispatch` on `.github/workflows/sdk-install-measure.yml`):

* **A — `cache-extracted-and-archives`** (the current default): the cache holds
  the extracted tree *plus* both raw archives; a warm hit re-authenticates by
  re-extracting both archives into a temporary directory, then verifies the tree
  digest and stdx artifact digests against the marker.
* **B — `cache-archives-only`**: the cache holds only the two pinned archives and
  every job extracts once into a fresh directory.

Both dispatches ran 5 paired cycles and asserted that the identities produced by
each shape are equal (`identityEqualUnderBothVariants: true` in both runs).

| Dispatch | Shape | Samples | Median | Min | Max |
| --- | --- | ---: | ---: | ---: | ---: |
| `38216746376` (2026-10-12) | archives-only | 5 | 10 420 ms | 10 418 ms | 10 446 ms |
| `38216746376` | extracted+archives | 5 | 12 676 ms | 12 626 ms | 12 710 ms |
| `38358957644` (2026-10-13) | archives-only | 5 | 12 209 ms | 12 156 ms | 12 271 ms |
| `38358957644` | extracted+archives | 5 | 14 415 ms | 14 362 ms | 14 444 ms |

**Decision: keep the current default shape.**

Both dispatches show archives-only ahead of the current shape (by ~2.3 s and
~2.2 s of median per-job cost, ≈16% of the measured work in the same direction),
but they also show the machine itself varying by ~1.8 s between dispatches, and
neither covers the dominant cost. The script declares its own limit and this is
why the default is not moved on this evidence:

* `notMeasured: ["cacheRestoreMs"]` — cache fetch and unpack belong to
  `actions/cache` and are not timed here. Restoring a ~234 MB extracted SDK tree
  versus a ~265 MB archives pair is exactly the part that could reverse a 2 s
  difference between two runners, and it is unmeasured in both shapes.
* The measured quantity is only the **warm path** (post-restore validation and
  extraction). The cold path is dominated by network download and is far larger
  than either figure here, so it cannot discriminate the shapes either.
* 5 samples per shape per dispatch is enough to see a consistent direction, not
  to claim a distribution; two dispatches on different runners agree in
  direction, which is why the result is recorded rather than discarded.

Moving the default would therefore trade an unmeasured cache-restore cost for an
unmeasured cache-restore cost while changing the artifact the release path
authenticates, which is precisely the kind of change that must not be made on an
unmeasured basis. Revisit only if `cacheRestoreMs` becomes measurable, or if a
future measurement reports the restore cost for both shapes from the same runner.

## CI-05.1: Pages starts at Linux candidate readiness

Previously `resolve-candidate` polled for a *successful CI run*, which only
exists once every platform of the matrix has finished. Measured wait on real
`main` pushes (`wallclock-pages-*.json`, artifact `ci-timing-*`):

| Run | `resolve-candidate` | CI Linux candidate | Pages `assemble-site` start |
| --- | ---: | --- | --- |
| `38357201253` | 919 s (bounded 900 s wait expired) | 06:31:49 → 06:35:54 | 06:51:13 |
| `38332333489` | 921 s | candidate ready 01:29:5x | 01:48:03 |

The candidate is ready roughly 4 minutes in, while Pages waited the full 900 s
timeout. CI now publishes a readiness-marker artifact as soon as the Linux
candidate uploads, and Pages consumes that marker, so assembly starts at
candidate readiness. Publication is unchanged: `verify-site` re-checks that the
consumed run's own attempt concluded successfully, so a later matrix failure
still blocks the deploy.

Mechanism evidence (real, not synthetic): on PR #106 the marker
`cjdoc-linux-candidate-ready-38362363108-1` existed while Windows and macOS were
still running, and `scripts/ci_candidate_source.py resolve` adopted it
(`reuse: true`) while `require-ready` refused to publish
(`run attempt is in_progress/, not a successful completed CI attempt`). The
removed wait is bounded by the historical numbers above (~15 minutes); a
matched before/after wall-clock pair on the same revision is tracked by #96.

## CI-06: parallelisation and the multi-locale extraction

CI-06.2/06.4/06.6 are decided from the phase table above:

* **06.6** is satisfied by the attribution itself: the repeated directory walks,
  link validation, hashing, copying and compression are each individually timed
  and each is ≤ 6 s, so none of them justifies a risky optimization while
  `showcase.api` is 254 s. Optimizing them would move the total by < 2%.
* **06.2** overlaps the phases the table shows to be independent: self-API
  generation and the PocketKit dependency chain. Both are measured phases, the
  split is by real dependency, and the combined site is proved byte-identical.
* **06.4** ("one semantic extraction, many language renders") is **not
  implemented**, and the reason is a hard dependency rather than a preference:
  on this revision `cjdoc generate --locale` accepts only `zh-CN|en`
  (`src/cli_options.cj`: `--locale must be zh-CN or en`), so a multi-locale
  single-extraction mode does not exist to call. The `locale="all"` fast path is
  only reachable from the unmerged #64 i18n work. Until that lands there is
  nothing to align a "one extraction" contract with, so #64 remains the
  prerequisite and this item stays open with this evidence.

## DONE-03/DONE-04: paired samples

The issue requires ≥5 cold and ≥5 warm paired samples per workflow under matched
conditions. That collection, the cold/warm classification rule, the failure and
re-run tables, and the critical-path attribution are tracked by #96; the raw
wall-clock classifications for the sampled runs are the `wallclock-*.json`
documents produced by `scripts/ci_stage.py wallclock` and attached there. This
document does not restate them, because a summary that drifts from the raw
artifacts is worse than no summary.
