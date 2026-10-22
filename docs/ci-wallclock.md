# CI, Pages and Release wall clock and where its time went (issue #82, DONE-04)

Every number here was read back from the GitHub API and cross-checked with
`scripts/ci_stage.py wallclock` on the same run IDs.

These fifteen runs are a **sample, not a census**, and the medians below
describe the sample rather than the population. The history holds 358
successful `ci.yml` runs and 343 successful `pages.yml` runs, of which the tables
show seven and six, plus two of the eight successful `release.yml` runs. The
sample was chosen to cover each observed job shape (the 17-step and 21–22-step
`linux-x64` definitions, the reuse and the local-build Pages shapes) and to name
the outliers rather than to be random: the most recent 20 `main` runs of
`ci.yml` alone contain 18 successful runs (`pages.yml`: 12 of 20), so other
unlisted runs share the shapes tabulated here. Every run that *is* listed is
accounted for individually — re-runs, outliers and queueing are named one by one
— but a run not listed has not been classified, and nothing here should be read
as a per-run cost of the workflow as a whole.

Thirteen of the fifteen runs are `push` events whose revision is an ancestor of
`main`; the other two are named where they appear — `39194009025` is a
`pull_request` run from `feat/issue-83-dependency-aware-links-v15-stack` at
`c5177d9d`, and `38131066496` is a tag (`v0.7.2-rc-perf-check`) pushed on a
feature branch at `c43bfd2d`. Neither revision is reachable from `main`
(`git merge-base --is-ancestor` fails for both), which is why they are kept and
labelled rather than pooled with the thirteen.

Reproduce a single run:

```bash
python scripts/ci_stage.py wallclock --run <RUN_ID> --attempt 1 \
    --repository lIlIIlIll/cjdoc --output target/ci-evidence/wallclock.json
```

The document is `cjdoc.ci-wallclock/2`. Version 1 called the chain field
`criticalPath`; it was renamed here, and the version bumped with it, because the
number is a non-overlapping execution sequence and not the dependency critical
path (see below). Issue #82's DONE-04 asks for `执行关键路径` — "the execution
critical path" — and issue #96's Done-when item 2 renders that as "critical-path
attribution". What the artifact can attribute from the Actions API is the
execution sequence: the API exposes no `needs` graph, so no field here claims a
dependency path. The criterion is met by reporting the sequence under a name
that says what it is, not by keeping a field name the number does not earn.

No workflow on `main` ever emitted version 1 — the `wallclock` job lands with
this change — so the bump breaks no producer. The version 1 documents that do
exist are the two artifacts this branch uploaded before the rename
(`ci-wallclock-39707863509-1`, `ci-wallclock-pages-39707863550-1`), which are
superseded by the `wallclock` jobs that now write version 2, and issue #96
comment `6318233984`, which predates the rename and is left as it stands — it is
a point-in-time capture, not a maintained document. Comment
[`6318438417`](https://github.com/lIlIIlIll/cjdoc/issues/96#issuecomment-6318438417)
is the only one regenerated at version 2; its earlier body held the same three
documents.

All three measured workflows run this classifier themselves — `ci.yml`,
`pages.yml` and `release.yml` each have a `wallclock` job that re-reads the run's
own jobs (`actions: read`) and uploads `ci-wallclock-<run>-<attempt>` (plus a
`pages-` or `release-` segment in the two workflows whose artifact name must
distinguish them from CI's). Each one waits for every job on the chain it
reports, including the last: `ci.yml` needs `required`, `pages.yml` needs
`deploy`, `release.yml` needs `publish`. Without that edge the clock would read
the final job while it is still running, and the Jobs API reports a running
job's `completed_at` as null — classified as 0 ms and dropped from the chain —
so the artifact could not reproduce the row this document prints. On a
`pull_request` event `deploy` is skipped and the clock still runs under
`always()`; the two named `pull_request` exceptions in "Build reuse is real, not
nominal" (`39208991635`, `39213457031`) end at
`Verify the final site and every branch` for exactly that reason. No row in the
Pages table below is a `pull_request` run, so all six end at `Publish showcase`.

Attaching it to the run is the point: a figure recomputed later from the API
describes a different state of the run (expired artifacts, re-runs,
still-running jobs) rather than the one that produced the numbers.

The collector is deliberately **not** part of any gate. In `ci.yml` it is absent
from `ci_required.PLANNED_JOBS`, and `pages.yml`'s `deploy` and `release.yml`'s
`publish` never need it: the Actions API can be flaky or rate-limited, and an
evidence collector failing must be neither able to fail a required check nor to
block or unblock a publication. `scripts/test_ci_wallclock_wiring.py` asserts
those two properties in each workflow rather than leaving them to review.

Three clocks are reported, because collapsing them hides the actual cost:

* **wall** — `run_started_at` to `updated_at`, i.e. what a user waits for. Both
  are run-level and describe the latest attempt, so `wallSource` says which clock
  the number is: `run` for the run-level span, and `attempt-jobs` when an older
  attempt was classified — there the wall is that attempt's own first job start
  to last job end, because the run-level end belongs to a different attempt.
  A re-run's job listing carries the previous attempt's unchanged records with
  their original timestamps. Those jobs did not run in this attempt, so they get
  the 0 ms a skipped job gets: they drop out of the chain instead of stretching
  the span past the run, and they are not billed to `jobMinutes`, which would
  otherwise count the same runner minutes in both attempts. `queuedMs` for a
  re-run is measured from that attempt's own start rather than from `created_at`,
  which is when the *run* was created;
* **job span** — first job start to last job end, i.e. execution without the
  controller's own queueing;
* **job-minutes** — the sum of every job's duration, i.e. total runner time,
  where parallel work is not hidden.

`wall − job span` is the pre-start gap (queueing, runner acquisition) plus the
tail after the last job ends. It is large on some Pages runs and negligible on
CI, which is itself a finding. The identity needs `wallSource: run`: when it is
`attempt-jobs` the wall *is* the span, so the difference is 0 by construction
and says nothing about queueing — there `queuedMs` is the only queue figure.

The document also describes the sequence the run actually executed:
`nonOverlappingChain` carries `chain`, `wallMs`, `equalsLongestJob`, `longestJob`
and `longestJobMs`. The chain is
derived from observed start/end times only — a job extends the chain when it
started no earlier than the previous link ended, so an inclusive handoff (a job
starting at the instant the previous one stopped) is a link, while a zero-length
job is a point in time and cannot shadow a real chain. The Jobs API exposes no
dependency graph, so it never invents an ordering for jobs that overlapped.

It is a **non-overlapping execution sequence, not the dependency critical
path**, and the field name says so. Two `needs` siblings can be serialized by
runner availability — `source-reproduction` and the two `browser-shard` jobs in
`pages.yml` each need only `assemble-site` — and a chain built from timestamps
alone would then join them and exceed the real dependency path. The number
answers "what did this run actually spend its time on", which is the question
these tables ask; it does not attribute the wall clock to a `needs` edge.

`equalsLongestJob: true` means the run was flat and the chain is a single job;
none of the runs below is flat, so every `chain` column names both the parallel
jobs and the sequence that actually serialised, and the separate "longest job"
column keeps the two apart.

Three real documents, one per measured workflow, are reproduced verbatim in
[issue #96 comment 6318438417](https://github.com/lIlIIlIll/cjdoc/issues/96#issuecomment-6318438417)
(regenerated at schema `cjdoc.ci-wallclock/2`, so it carries the same field names
as this document):

| workflow | run | chain (`nonOverlappingChain.chain`, verbatim) | chain wall |
| --- | --- | --- | ---: |
| CI | `39559560039` | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required | 56.3 m |
| Pages | `39198382577` | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 1 → Verify the final site and every branch → Publish showcase | 33.0 m |
| Release | `39217926544` | Release candidate / linux-x64 <matrix> → Publish verified release | 71.1 m |

Job names below are the ones the Actions API reports, abbreviated only where a
matrix suffix repeats: `<matrix>` stands for `/ Cangjie 1.2.0 STS + stdx`, which
every platform job carries.

## PR-required CI (`ci.yml`)

| run | revision | wall | job span | gap | total job-min | longest job | non-overlapping chain |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `39198382507` | `b0c3e5fb` | 55.4 m | 55.1 m | 0.3 m | 131.8 | linux-x64 <matrix> 50.1 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 55.0 m |
| `39194009025` | `c5177d9d` | 54.9 m | 54.9 m | 0.1 m | 126.8 | linux-x64 <matrix> 49.4 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 54.7 m |
| `38640674939` | `5aab6cc5` | 27.4 m | 27.4 m | 0.1 m | 67.8 | windows-x64 <matrix> 23.7 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 27.2 m |
| `38630501874` | `2d840445` | 28.4 m | 28.4 m | 0.1 m | 72.7 | windows-x64 <matrix> 24.6 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 28.2 m |
| `38612145185` | `30700d66` | 55.8 m | 55.7 m | 0.1 m | 103.3 | linux-x64 <matrix> 50.2 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 55.5 m |
| `38606162290` | `1ba5beb5` | 28.2 m | 27.0 m | 1.2 m | 62.7 | linux-x64 <matrix> 22.7 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 26.9 m |
| `39559560039` | `1483f14f` | 56.5 m | 56.5 m | 0.1 m | 136.1 | linux-x64 <matrix> 51.0 m | Classify changes → Linux candidate / Linux candidate <matrix> → linux-x64 <matrix> → CI required = 56.3 m |

Six of the seven are `push` runs on `main`; `39194009025` is a `pull_request`
run for `feat/issue-83-dependency-aware-links-v15-stack`. It is kept because
`pull_request` is the event the required check actually gates a merge on, and
its 54.9 m sits inside the `push` range; it is not a different pipeline.

Median wall **54.9 m**, range 27.4–56.5 m (n=7). The three platform acceptance
jobs run in parallel, so the wall clock is governed by the slowest platform, not
by the sum of the jobs: total job-minutes are 62.7–136.1 against a 27–57 minute
wall. `Linux candidate` (4.7 m in `39198382507`) is a producer consumed by the other
jobs, and `CI required` is a fixed-cost summary job (0.1–0.2 m; 0.17 m on
`39194009025`).

The range is bimodal because the measured job is not the same job across this
window: four runs (`38640674939`, `38630501874`, `38606162290`, `38612145185`)
record 17 steps on `linux-x64`, and three (`39198382507`, `39194009025`,
`39559560039`) record 21–22. Against the 17-step set they gained four steps
each: `Set up the optional highlight runtime` (and its `Post` counterpart),
`Verify the real optional highlight worker` and `Upload real optional-worker
evidence`. Only `39559560039` additionally carries `Install browser acceptance
dependencies`, which is where its 22nd step comes from. Pooling them is still
the honest choice — they are the successful runs of one workflow — but the
median describes a distribution over two job definitions, so both groups are
named here instead of the median being read as a single per-run cost. Within the
17-step group `38612145185` is a genuine outlier at 55.8 m (`run_attempt: 1`, not
a re-run) against 27–28 m for
its peers; it is kept, and the range is reported alongside the median rather
than in place of it. Queueing is negligible across all seven: 0.1 m on five of
them, 0.3 m on `39198382507` and 1.2 m at worst on `38606162290`, so the CI wall
clock really is execution time.

## Pages / showcase (`pages.yml`)

| run | revision | wall | job span | gap | total job-min | longest job | non-overlapping chain |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `39198382577` | `b0c3e5fb` | 57.3 m | 33.3 m | 24.0 m | 45.1 | Verify the final site and every branch 13.8 m | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 1 → Verify the final site and every branch → Publish showcase = 33.0 m |
| `38640674884` | `5aab6cc5` | 29.0 m | 28.9 m | 0.1 m | 42.4 | Verify the final site and every branch 8.9 m | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 1 → Verify the final site and every branch → Publish showcase = 28.6 m |
| `38630501893` | `2d840445` | 29.7 m | 29.6 m | 0.1 m | 38.0 | Assemble final site 8.8 m | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 1 → Verify the final site and every branch → Publish showcase = 24.2 m |
| `38606162319` | `1ba5beb5` | 44.9 m | 15.5 m | 29.5 m | 26.9 | Browser shard 1 6.8 m | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 1 → Verify the final site and every branch → Publish showcase = 15.2 m |
| `38600196225` | `5cc01475` | 25.1 m | 25.0 m | 0.1 m | 35.9 | Assemble final site 8.2 m | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 0 → Verify the final site and every branch → Publish showcase = 24.7 m |
| `39559560070` | `1483f14f` | 58.3 m | 58.2 m | 0.1 m | 71.1 | Verify the final site and every branch 33.6 m | Resolve Linux candidate source → Reuse the CI Linux candidate → Assemble final site → Browser shard 1 → Verify the final site and every branch → Publish showcase = 58.0 m |

Job span median **29.2 m**, range 15.5–58.2 m (n=6); total job-minutes
26.9–71.1. The wall clock is *not* a good summary here: two of the six runs spent
24.0 m and 29.5 m waiting before their first job started (runner acquisition),
while the other four started within 0.1 m (`wall − jobSpan` is 0.05–0.08 m on
those four, which is the controller's own bookkeeping, not queueing). The 58.2 m
span on `39559560070` is a single slow job rather than queueing — `Verify the
final site and every branch` takes 33.6 m there against 1.2–13.8 m on the five
older runs — so the spread is job duration, not dispatch.

## Release (`release.yml`)

Tag-triggered, so it runs rarely: the history holds 33 runs across 19 tags, 8 of
which succeeded. Seven of those ran `publish` successfully; the eighth,
`33493898094` (`v0.7.0`), reports `Publish verified release` as `skipped`, so it
never published. Two of the seven are analysed below: `38131066496` (tag
`v0.7.2-rc-perf-check`, revision `c43bfd2d`) on a feature branch, and
`39217926544` (tag `v0.7.2-rc2`, revision `b0c3e5fb`) on merged `main`. The
other five are `38117943741` (`v0.7.2-rc-ci-test6`, folded `release-candidate`
shape), `37907298402` (`v0.7.2-rc1`, gate + package on Cangjie 1.2.0 STS),
`33946404189` (`v0.7.2`), `33540838431` (`v0.7.1`) and `33497050568` (`v0.7.0`,
all three gate + package on Cangjie 1.1.3). They are left out because these two
rows exist to answer one question — what the loop costs on a branch versus on
merged `main` — and the five older runs answer "what did it cost at an earlier
revision", which is a different question with a different toolchain. Nothing is
dropped silently: every successful publisher in the history is named here:

| run | revision | wall | job span | gap | total job-min | longest job | non-overlapping chain |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `38131066496` | `c43bfd2d` | 39.1 m | 39.0 m | 0.1 m | 82.5 | Release gate / linux-x64 <matrix> 32.2 m | Release gate / linux-x64 <matrix> → Package / macos-arm64 → Publish verified release = 38.8 m |
| `39217926544` | `b0c3e5fb` | 71.2 m | 71.2 m | 0.1 m | 145.7 | Release candidate / linux-x64 <matrix> 70.7 m | Release candidate / linux-x64 <matrix> → Publish verified release = 71.1 m |

Per job on `38131066496` (`jobWallMs`): `Release gate / linux-x64` 32.2 m,
`windows-x64` 25.1 m, `macos-arm64` 10.4 m, `Package / linux-x64` 4.1 m,
`Package / windows-x64` 4.1 m, `Package / macos-arm64` 6.2 m,
`Publish verified release` 0.3 m. The linux release
gate dominates because it runs the full local acceptance plus the real-repository
smoke and the frozen performance ceiling. Packaging does sit on the chain, not
beside it: the gates are a dependency of packaging, so the 6.6 m by which the
chain exceeds its longest job is `Package / macos-arm64` (373 s) plus
`Publish verified release` (21 s) — 394 s, i.e. 6.6 m. `39217926544` runs a
different job shape — `release-candidate` folds packaging into the per-platform
candidate job, so there is no separate `package` link — and its linux candidate
takes 70.7 m, which is the whole run. The two rows are therefore not samples of
one population and are not pooled: they show the loop on a branch and on `main`,
not a before/after.

Every cell in these three tables is read from the corresponding `wallclock.json`
(`wallMs`, `wallSource`, `jobSpanMs`, `jobMinutes`, `jobWallMs`, `nonOverlappingChain`);
the doc does not carry a number the artifact cannot reproduce. Every row below is
a latest attempt, so every row's `wallSource` is `run`.

## Build reuse is real, not nominal

On all six Pages runs sampled (`39198382577`, `38640674884`, `38630501893`,
`38606162319`, `38600196225`, `39559560070`), `Reuse the CI Linux candidate`
succeeds while `Build Linux candidate locally` is `skipped`, so it carries
**0 ms** in `jobWallMs`. Pages therefore consumes the CI-built Linux candidate
instead of building a second copy (CI-05.1). The duplicate work removed is the
producer's own build: across these seven CI runs the `Linux candidate` job spans
4.0–5.1 m (`jobWallMs`), almost all of it the `Build the Linux candidate` step at
222–291 s.

The exception is `39213457031` (and `39208991635`), where `Build Linux candidate
locally` ran for 5.2 m and 5.0 m and `Reuse the CI Linux candidate` is
`skipped`. Both are `pull_request` events, and
`ci_candidate_source.py resolve` refuses reuse outright for that event —
"pull requests never reuse a cross-run artifact" — so a fork cannot influence a
published site. Reuse is therefore a property of `push`-triggered Pages runs,
not of Pages in general.

## The release loop on the merged `main` (DONE-04 item 3)

Run `39217926544` is not the first release loop on `main` — `v0.7.0`, `v0.7.1`
and `v0.7.2` each published from an ancestor of `main` under the older
gate + package graph. It is the first run of the **current** folded
`release-candidate` graph on `main`, and the first prerelease tag pushed from a
then-current `main` revision. Tag `v0.7.2-rc2` was pushed at `b0c3e5fb27ae`:

| job | result | wall |
| --- | --- | ---: |
| Release candidate / linux-x64 | success | 70.7 m |
| Release candidate / windows-x64 | success | 42.5 m |
| Release candidate / macos-arm64 | success | 32.1 m |
| Publish verified release | success | 0.5 m |
| **run** | **success** | **71.2 m** (145.7 job-minutes) |

`Publish verified release` logged `release_flags=--prerelease`, uploaded the
per-platform binaries, archives and `.sha256` files, and published the release;
all three platform candidate receipts were accepted by the packaging gate.

The throwaway tag and release were then removed as the issue requires, and the
removal was recorded: the release and the `v0.7.2-rc2` tag no longer exist
(`releases` are `v0.7.0`, `v0.7.1`, `v0.7.2-rc1`; the same three tags are the only
remote tags), while the run `39217926544` and its logs remain retrievable and
`b0c3e5fb27ae` is still an ancestor of `main`.

## What this does not establish

`docs/paired-samples-main.md` (issue #96) remains the authority for the
cold/warm paired-sample requirement, and it prints its own counts rather than
pooling samples across revisions or cache states. One cell now reaches the
recorded-axes threshold: on `macos15-20260907.0337.1` with the pinned SDK and
stdx, macOS has 10 warm and 5 cold samples under one matched condition
(paired = min(10, 5) = 5). That cell runs no browser stage, so DONE-03's
browser/font axis is not applicable to it rather than unrecorded; the report
names that explicitly instead of printing a bare `met`. The axis is only
attested where a browser stage actually ran -- the Linux acceptance matrix and
the Pages browser shards -- and those cells must record it to earn an unqualified
verdict. The Pages reading job opens a browser too and its `reading` stage kind
is therefore classified as browser-driving, but it records no browser identity
and publishes no timing artifact, so it contributes no attested cell. No other
cell is close — `windows-x64` splits its cold samples
across
two runner images (2 and 3, neither side reaching five), and `linux-x64` has
warm samples but no cold sample on any single condition.
