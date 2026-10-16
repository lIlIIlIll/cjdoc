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

## Pinned STS native-test launcher

The native deadline launches `cjpm test --jobs 1 --parallel 1` through Bash,
so Windows resolves the extensionless STS wrapper instead of bypassing it for
`cjpm.exe`. The wrapper's temporary `-O1` manifest override and restoration trap
therefore cover the native compilation too. The Windows native log in
[run 38847649307](https://github.com/lIlIIlIll/cjdoc/actions/runs/38847649307)
recorded the bundled LLVM crashing while compiling markdown at `-O2`.

The Windows `with_stdx.py` launcher also waits for its child and propagates its
exit status; it must not report a completed gate merely because CRT `exec*`
started a separate process.

This preserves the suite, deadline, serial test scheduling and committed compile
defaults. A Linux routing/status/cleanup probe is not native Windows compile proof.

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

### Re-measured after #64 and #110

The table above is the pre-#64 shape, taken from `38332333489` (2026-10-12). Two
changes moved it, so the attribution is repeated on the merged `main`
(`2d840445`, three independent runs):

| Phase | `38630501893` | `38616758091` | `38612144866` |
| --- | ---: | ---: | ---: |
| `showcase.api` | 413.5 s | 424.1 s | 409.6 s |
| `pocketkit.generate:all:demo-v2` | 66.5 s | 69.3 s | 68.0 s |
| `pocketkit.generate:all:demo-v1` | 66.1 s | 63.7 s | 62.7 s |
| `showcase.authoring` | 48.9 s | 49.6 s | 47.6 s |
| **`site-assemble` elapsed** | **504.5 s** | **515.4 s** | **498.4 s** |

The shares are computed against `site-assemble`'s own elapsed `wallMs`, **not** the
sum of the phases. Since #110 overlaps self-API generation with the whole PocketKit
branch, the phase durations are concurrent and their sum (633.6-663.7 s) exceeds the
stage's real duration by about 25%. A share of the sum would therefore understate
every phase, and the 06.6 decision below depends on the correct denominator.

Shares of the elapsed stage, per run:

What changed:

* The four `pocketkit.generate:*` phases (one per locale and version, 60.2 s
  combined) are now **two** `pocketkit.generate:all:*` phases. That is CI-06.4's
  one-extraction-many-renders arriving via #64, and it is why the per-locale
  generation cost disappeared as a separate line. (The earlier note below explains
  the composition and diagnostics phases that this collapse also removed until they
  were restored.)
* Version composition and the per-language diagnostics stopped carrying a phase when
  the per-locale chain was collapsed, so they had silently dropped out of the phase
  evidence this document relies on. **They are timed again** (`pocketkit.diff`,
  `pocketkit.compose`, `pocketkit.diagnostics:<locale>` in
  `examples/pocketkit/reproduce.py`); a local `--locale both` run now reports
  47.3 s for compose, 3.9 s + 3.8 s for the two diagnostics passes and 0.1 s for the
  diff, out of a 162 s PocketKit branch. The runs in the table above predate that
  restore, so their PocketKit numbers are the generation phases only.
* The phase total is larger than the pre-#64 415.5 s (633.6-663.7 s now). #64 added
  work inside `site-assemble` -- authorized translations and version composition --
  and `showcase.api` and `showcase.authoring` both grew with it (253.9 -> 410-424 s
  and 29.2 -> 47.6-49.6 s), as did aggregate PocketKit generation (60.2 -> 126-136 s).
  **This is not an apples-to-apples comparison**: both the workload and the
  implementation changed, so these numbers show that more work moved inside
  `site-assemble`; they do not establish that no phase regressed, and no phase is
  claimed to have stayed flat.

Two phases dominate and both are real generation work, not duplicated overhead:
`showcase.api` (this repository documenting itself) is about 82% of the elapsed
stage, and the two `pocketkit.generate:all:*` extractions are about 13% each (one
extraction per version, already reduced from four by CI-06.4).
`showcase.authoring` is about 9.6%. Measured shares, not shares of the summed phase
durations.

The phases 06.6 actually names -- `showcase.site-copy`, `showcase.homepage`,
`showcase.source-copy`, `showcase.downloads`, `showcase.link-validate`,
`showcase.offline-archive`, `showcase.reports`, `showcase.navigation` -- total
**25.4-25.8 s, about 5% of the elapsed stage**, with no single one above 1.6%. That
is the evidence behind 06.6: they are individually timed, and removing all of them
entirely could not move the stage by more than that 5%.

They are not, however, hidden behind the concurrent API work. Only
`showcase.source-copy` runs inside the overlapping branch; `BranchRunner().pair(...)`
joins the API and PocketKit branches before `site-copy`, `reports`, `navigation`,
`downloads`, `homepage`, `offline-archive` and `link-validate`, which therefore all
run serially on the stage's critical path
(`scripts/showcase_build/integration.py`). Their combined 5% is what bounds them,
not any concurrency. The two PocketKit generation phases are explicitly NOT in that
group; they are the second-largest cost and were reduced by removing extra
extractions (CI-06.4), not by micro-optimizing file work.

## CI-07.4: combined SDK cache shape

Two shapes were compared by `scripts/measure_sdk_install.py` (dispatch
`workflow_dispatch` on `.github/workflows/sdk-install-measure.yml`):

* **A — `cache-extracted-and-archives`** (the current default): the cache holds
  the extracted tree *plus* both raw archives; a warm hit re-authenticates by
  re-extracting both archives into a temporary directory, then verifies the tree
  digest and stdx artifact digests against the marker.
* **B — `cache-archives-only`**: the cache holds only the two pinned archives and
  every job extracts once into a fresh directory.

Three dispatches ran 5 paired cycles each and asserted that the identities
produced by each shape are equal (`identityEqualUnderBothVariants: true` in every
run).

| Dispatch | Shape | Samples | Median | Min | Max |
| --- | --- | ---: | ---: | ---: | ---: |
| `38216746376` (2026-10-12) | archives-only | 5 | 10 420 ms | 10 418 ms | 10 446 ms |
| `38216746376` | extracted+archives | 5 | 12 676 ms | 12 626 ms | 12 710 ms |
| `38358957644` (2026-10-13) | archives-only | 5 | 12 209 ms | 12 156 ms | 12 271 ms |
| `38358957644` | extracted+archives | 5 | 14 415 ms | 14 362 ms | 14 444 ms |
| `38364098523` (2026-10-13) | archives-only | 5 | 10 497 ms | 10 489 ms | 10 512 ms |
| `38364098523` | extracted+archives | 5 | 12 750 ms | 12 699 ms | 12 755 ms |

**Decision: keep the current default shape.**

All three dispatches put archives-only ahead of the current shape, by 2 253 ms,
2 206 ms and 2 253 ms of median, i.e. 16.3-17.8% of the measured work each time,
and the direction never flips. The measurement is nonetheless not sufficient to
change the default, because the machine varies between dispatches by up to
1 789 ms (the archives-only median moves from 10 420 ms to 12 209 ms between the
first two dispatches) and because neither shape's dominant cost is covered. The
script declares its own limit and this is why the default is not moved on this
evidence:

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

* **06.6** is satisfied by the attribution itself, re-measured on the merged
  `main` against the stage's own elapsed time (the section above): the repeated
  directory walks, link validation, hashing, copying and compression that this item
  names total about 25 s, roughly 5% of a 498-515 s `site-assemble`, with no single
  phase above 1.6%; `showcase.api` alone is about 82%. They run serially after the
  concurrent API/PocketKit branches join, so they are on the critical path -- their
  combined 5% is what bounds what optimizing them could achieve, and it is not worth
  a risky optimization. (The pre-#64 figures for this bullet
  were "≤ 6 s against a 254 s `showcase.api`"; both have since grown, and the phase
  table above carries the current numbers and the correct denominator.)
* **06.2** overlaps the phases the table shows to be independent: self-API
  generation and the PocketKit dependency chain. Both are measured phases, the
  split is by real dependency, and the combined site is proved byte-identical.
* **06.4** ("one semantic extraction, many language renders") is **delivered by
  #64** (`feat(i18n): publish author translations through Doc IR v13`, `30700d6`),
  which this item waited on. `cjdoc generate --all-languages` performs one
  extraction and projects every language from it: `src/cli_runner.cj` renders the
  agent artifacts and `validation.html` per entry of
  `documentation.languageOptions.languages` from the single `documentation` value,
  and `examples/pocketkit/reproduce.py` calls `generate(..., locale="all")` once
  per version before `assemble(generated[version], locale)` per language. Measured
  on the merged `main`: one `generate --project examples/pocketkit/demo-v2
  --all-languages` run completes in 37 s and writes `html/en` and `html/zh-CN`
  (129 files each, contents differ) with a single `docs.json`
  (`cjdoc.doc-ir/13`, `languages: ["en", "zh-CN"]`).

## Merged state and the two failure modes found while landing this

The orchestration work merged to `main` in five pull requests: #106 (bounded
subprocess waits, candidate readiness), #107 (shard balancing from real per-case
timings), #110 (showcase branch overlap, coordinator signal cleanup), #119
(native-stage evidence in failure diagnostics) and #120 (subprocess heap cap). Each
merged only with its own full acceptance run green on linux, Windows and macOS.

Two failures were diagnosed while landing them, and both are recorded here because
they were previously reported with the wrong cause:

* **The intermittent stall is not one unbounded read.** The same case
  (`SourcePipelineSuite6.headerlessDependencyUsesItsModuleNameForSerialAndParallelJobs`)
  wedged on `linux-x64` and on macOS, twice inside one day, for unrelated revisions
  whose only delta was a Doc IR digest. Five genuine unbounded waits were fixed
  (stream reads, the supervisor handshake, `process.wait()`, and the example-runner
  stream and status waits). The executed evidence is per path, not one test for all
  five: `BoundedProcessTimeoutTest.escapingDescendantCannotOutliveTheTimeout` covers
  the trailing-read path (45 s on the old code, 2.01 s after), and
  `DoctestConfigSuite` covers the doctest path
  (`subprocessPipeWaitDeadlineRemainsTimeoutNotOutputLimit`,
  `subprocessPipesDrainBeforeReapingShortLivedChildren`); the handshake bound is
  enforced by construction and was checked with a 1 ms budget during review.
  The residual stall survived all five.

  Diagnosis was Linux-only and came from outside the tests: the whole process tree
  (`cjpm` -> `std.testrunner` -> its workers) was parked in `futex_do_wait` with no
  runnable thread, reproduced locally once, and it is not reproducible. The macOS
  stalls were observed through their symptom only (a job with no output for over an
  hour and leftover processes); no wait channel was captured there, and macOS has no
  `wchan` column, so the futex diagnosis is explicitly a Linux finding.

  The mitigation runs on every platform. `check.sh` bounds the native suite at 40
  minutes (more than twice the longest healthy run) through
  `scripts/run_with_timeout.py`, a Python wrapper used because macOS has no `timeout`
  binary and Git Bash resolves Windows' unrelated `timeout.exe`; Python is already a
  requirement on all three runners. It kills the command's process group on expiry
  and exits 124, so a wedge fails naming the phase on Linux and macOS alike instead
  of consuming the job budget. It refreshes a process-tree snapshot while the stage
  runs, which `ci_diagnostics.py` collects into the failure artifact. A descendant
  that starts its own session escapes the group, as it does in the supervisor path;
  the wrapper does not claim otherwise.

* **`Out of memory` is a capacity limit, not a leak.** The generator documenting
  *this* repository exceeded the 512MB default (`active units 127779 of 131072`,
  `objectCapacity` 10.6% live against 89% fragmented). Raising the ambient heap was
  not sufficient on its own: `memoryBoundedCommand` caps every native child with
  `prlimit --as`, and a child that inherits a heap larger than that cap cannot
  reserve pages at all (`allocate create page failed! Out of Memory!`, measured from
  `rc=0` at 512MB to `rc=1` at 2GB for the same command). The child heap is now
  pinned to a quarter of the cap, which equals the previous effective value, and
  only then is the ambient heap raised for the self-documentation stages
  (`CJDOC_SMOKE_HEAP`, default 2GB, applied in `check.sh`, `release_check.sh` and
  `daily.yml`).

## DONE-03/DONE-04: paired samples

The issue requires ≥5 cold and ≥5 warm paired samples per workflow under matched
conditions. That collection, the cold/warm classification rule, the failure and
re-run tables, and the critical-path attribution are tracked by #96; the raw
wall-clock classifications for the sampled runs are the `wallclock-*.json`
documents produced by `scripts/ci_stage.py wallclock` and attached there. This
document does not restate them, because a summary that drifts from the raw
artifacts is worse than no summary.

## Item-to-evidence map

Each row names the item, the implementation that delivers it, the test or run
that demonstrates it, and the exact revision or artifact the claim rests on.
"Delivered" means the code and its tests exist and were executed; a row whose
evidence is a pull request also names that request, because nothing here is
merged until the maintainer merges it.

| Item | Implementation | Demonstration | Evidence |
| --- | --- | --- | --- |
| 01.1-01.3 timing inventory | `scripts/ci_stage.py` (`run`, `summarize`), `showcase_build.stage_timing`, `ci-timing-*` artifacts | every stage and showcase phase writes `wallMs`, identity, cache state; Job Summary renders it | `showcase-stages.json` with 25 phase ids from run `38332333489` |
| 01.4 wall-clock classes | `scripts/ci_stage.py wallclock` | separates queueing, job wall time, per-step wall time, re-run gaps | `wallclock-*.json` documents; queueing is reported separately (e.g. queuedMs 71 s on run `38363309607`) |
| 01.5 workflow/script contract checks before expensive builds | `files: scripts/ci_required.py`, `scripts/ci_changes.py`, `scripts/test_ci_stage.py` | routing and the aggregate gate are unit- and contract-tested | `python -m unittest scripts.test_ci_stage` (13 tests, OK) |
| 02.1 single sealed site | `pages.yml` `assemble-site` uploads `cjdoc-showcase-site-<run>-<attempt>` with a fingerprint | the site is generated once and every branch consumes that artifact | `Assemble final site` + `Verify the final site and every branch` in any Pages run |
| 02.2-02.5 parallel final verification | `source-reproduction`, `browser-shard`, `reading-regressions`, `verify-site` | the three branches run in parallel and `verify-site` re-binds every branch to the sealed site | Pages jobs on run `38373947823` (all branches success, verify success) |
| 03.1-03.8 browser sharding | `scripts/showcase_contract/browser_sharding.py`, `browser.py` | `tests/showcase_contract/test_browser_sharding.py` | 24 sharding tests OK, including negative cases and a real-data balance test |
| 04.1-04.8 layered CI | `scripts/check.sh` stages driven by `ci.yml` | each consumer stage is handed the binary and identity it needs | `ci.yml` `linux-acceptance` stage list; `scripts/test_release_candidate.py` guards the layout |
| 05.1 Pages starts at candidate readiness | `scripts/ci_candidate_source.py`, readiness marker in `build-linux-candidate.yml`, `pages.yml` adoption + `require-ready` | `scripts/test_ci_candidate_source.py`; live adoption of a real in-flight run | 18 unit tests OK; `resolve` returned `reuse: true` for run `38362363108` while its matrix was still running, and `require-ready` refused to publish (`in_progress`) |
| 05.2-05.6 shared toolchain and identity | one reusable `build-linux-candidate.yml`; `ci_stage.py verify-identity` | the same workflow builds the candidate for CI and Pages; each consumer re-verifies the manifest | `verify-identity` runs in both the CI acceptance job and the Pages site job |
| 06.1 showcase phase attribution | `showcase_build.stage_timing` phase ids | the per-phase table in this document | `showcase-stages.json` from run `38332333489` |
| 06.2-06.3 overlap only what is independent | `scripts/showcase_build/parallel.py`, `integration.py` | real serial/overlapped A/B on one machine | 507.8 s and 476.4 s serial vs 391.4 s overlapped (1.22-1.30x), same binary and provenance |
| 06.4 one extraction / many renders | `--all-languages` in `src/cli_options.cj` + `src/cli_runner.cj` (#64), used by `examples/pocketkit/reproduce.py` | one `generate` per version, then one render per language | run `38630501874` on `2d840445`; local `--all-languages` run: 37 s, `html/en` and `html/zh-CN` (129 files each, differing), one `docs.json` with `languages: ["en", "zh-CN"]` |
| 06.5-06.6 source ZIP reproduction and profiling | `check_showcase_source.py`, the phase attribution (`showcase_build.stage_timing`) | the archive is re-run from the ZIP with the generating binary; the named phases total ~25 s of a ~500 s `site-assemble` | `Reproduce the downloaded source bundle` job, plus the three re-measurement runs `38630501893` / `38616758091` / `38612144866` (elapsed-stage shares) |
| 07.1-07.3, 07.5-07.6 cache correctness | `install_cangjie_sdk.py` marker + verified archives, `with_stdx.py` fingerprints, cache keys carrying arch/channel/component identity | cache tests and the cold/warm equality assertion of the measurement script | `scripts/test_install_cangjie_sdk.py`, `scripts/test_with_stdx.py`; `identityEqualUnderBothVariants: true` |
| 07.4 cache shape measurement | `scripts/measure_sdk_install.py`, `sdk-install-measure.yml` | three dispatches of 5 paired cycles | see the CI-07.4 table above |
| 08.1-08.6 release closure | `release.yml` per-platform candidate + receipt, `release_check.sh`, `verify_release.py` | `scripts/test_release_candidate.py`, `test_release_evidence.py`, `test_release_transaction.py` | those suites pass; the orchestration work is merged to `main`, but a real tagged run is still pending (see below) |
| 09.1-09.5 failure feedback | `ci_diagnostics.py`, bounded log capture, no default golden regeneration | `scripts/test_ci_scripts.py` | diagnostics are collected on failure only, into a bounded directory |
| 10.1-10.7 routing, cancellation and Daily | `ci_changes.py`, `ci_required.py`, concurrency groups, `daily.yml` | routing table and the aggregate-gate tests | `scripts.test_ci_scripts` and `scripts.test_ci_stage` |

### Items that are not delivered

One row above is deliberately not "delivered", and it is recorded rather than
quietly closed:

* **DONE-03 / DONE-04** cannot be satisfied by the history that exists. The
  enumeration found exactly one source-matched warm Pages pair and no
  source-matched Release samples at all, so the ≥5-pairs-per-cold/warm-cell
  requirement is not met by any amount of re-reporting. The raw collection and
  its limits are attached to #96; a successful tag run would add one sample, not
  fill the cells.

## Optional highlight-worker failure evidence

`highlight_ci.py` keeps raw command output private. A failed `worker-acceptance`
step may publish `tracebackLocations`: only an allowlisted repository-relative
acceptance/observer script and its numeric source line. The child record is limited
to 8 KiB and 16 locations and validated before publication. Exception text, local
variables, command arguments, environment values and raw output are not copied.
These locations diagnose a failure; they do not turn it into acceptance.

Observer cleanup retains each acquired process handle or queue after signalling.
Its native exit wait is limited to three seconds per process before checking the
unchanged stopped predicate; existing identity-query deadlines still apply. A live
process or failed query remains an error, not a successful cleanup.
An already-terminated Windows handle is accepted only when that same acquired
handle proves exit; access-denied alone is not success. Procfs `ENOENT`/`ESRCH`
means the process disappeared, including during a read; permission and other
query failures still propagate.

