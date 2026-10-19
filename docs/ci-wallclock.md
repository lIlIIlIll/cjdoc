# CI, Pages and Release wall clock with critical-path attribution (issue #82, DONE-04)

Every number here was read back from the GitHub API for runs on the merged
`main` (or, for Release, its tag), and cross-checked with
`scripts/ci_stage.py wallclock` on the same run IDs. Nothing is extrapolated and
no sample is dropped: re-runs, outliers and queueing are named.

Reproduce a single run:

```bash
python scripts/ci_stage.py wallclock --run <RUN_ID> --attempt 1 \
    --repository lIlIIlIll/cjdoc --output target/ci-evidence/wallclock.json
```

Three clocks are reported, because collapsing them hides the actual cost:

* **wall** — `run_started_at` to `updated_at`, i.e. what a user waits for;
* **job span** — first job start to last job end, i.e. execution without the
  controller's own queueing;
* **job-minutes** — the sum of every job's duration, i.e. total runner time,
  where parallel work is not hidden.

`wall − job span` is the pre-start gap (queueing, runner acquisition). It is
large on some Pages runs and negligible on CI, which is itself a finding.

## PR-required CI (`ci.yml`)

| run | revision | wall | job span | gap | total job-min | longest job | critical path |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| `39198382507` | `b0c3e5fb` | 55.4 m | 55.1 m | 0.3 m | 131.8 | linux-x64 50.1 m | linux-x64 acceptance |
| `39194009025` | `c5177d9d` | 54.9 m | 54.9 m | 0.1 m | 126.8 | linux-x64 49.4 m | linux-x64 acceptance |
| `38640674939` | `5aab6cc5` | 27.4 m | — | — | 67.8 | windows-x64 23.7 m | windows-x64 acceptance |
| `38630501874` | `2d840445` | 28.4 m | — | — | 72.6 | windows-x64 24.6 m | windows-x64 acceptance |
| `38612145185` | `30700d66` | 55.8 m | 55.7 m | 0.1 m | 103.3 | linux-x64 50.2 m | linux-x64 acceptance |
| `38606162290` | `1ba5beb5` | 28.2 m | — | — | 62.7 | linux-x64 22.7 m | linux-x64 acceptance |

Median wall **41.7 m**, range 27.4–55.8 m. The three platform acceptance jobs
run in parallel, so the wall clock is governed by the slowest platform, not by
the sum of the jobs. `Linux candidate` (282 s in `39198382507`) is a producer
consumed by the other jobs, and `CI required` is a fixed-cost summary job.

`38612145185` is a genuine run (`run_attempt: 1`), not a re-run, and its linux
job is far above its peers; it is kept and the median is reported alongside the
range rather than in place of it. Queueing is negligible on all three CI runs
measured in detail (0.3 m at most), so CI wall clock really is execution time.

## Pages / showcase (`pages.yml`)

| run | revision | wall | job span | gap | total job-min | critical path |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `39198382577` | `b0c3e5fb` | 57.3 m | 33.3 m | **24.0 m** | 45.1 | verify-site 13.8 m |
| `38640674884` | `5aab6cc5` | 29.0 m | 28.9 m | 0.1 m | 42.4 | verify-site 8.9 m |
| `38630501893` | `2d840445` | 29.7 m | 29.6 m | 0.1 m | 38.0 | assemble-site 8.8 m |
| `38606162319` | `1ba5beb5` | 44.9 m | 15.5 m | **29.4 m** | 26.9 | browser shard 1 6.8 m |
| `38600196225` | `5cc01475` | 25.1 m | 25.0 m | 0.1 m | 35.9 | assemble-site 8.2 m |

Job span median **28.9 m**, range 15.5–33.3 m; total job-minutes 26.9–45.1.
The wall clock is *not* a good summary here: two of five runs spent 24–29
minutes waiting before their first job started (runner acquisition, since these
are `workflow_run`-triggered), while the other three started immediately. The
same two runs are the only ones whose wall clock exceeds their job span.

## Release (`release.yml`)

Tag-triggered, so it runs rarely. The last fully successful run is
`38131066496` (tag `v0.7.2-rc-perf-check`, revision `c43bfd2d`):

| run | wall | total job-min | critical path |
| --- | ---: | ---: | --- |
| `38131066496` | 39.1 m | 82.5 | release gate linux-x64 32.2 m |

Per job: release gate linux-x64 32.2 m, windows-x64 25.1 m, macos-arm64 10.4 m,
package 4.1–6.2 m each, publish 0.3 m. The linux release gate dominates because
it runs the full local acceptance plus the real-repository smoke and the frozen
performance ceiling; packaging on all three platforms happens after the gates
and is not on the critical path.

## Build reuse is real, not nominal

On every Pages run sampled, `Build Linux candidate locally` is recorded at
**0 ms** while `Reuse the CI Linux candidate` succeeds (~17 s). Pages therefore
consumes the CI-built Linux candidate instead of building a second copy
(CI-05.1). The duplicate work removed is the producer's own build, measured at
4.4–4.7 m on the candidate job.

## What this does not establish

`docs/paired-samples-main.md` (issue #96) remains the authority for the
cold/warm paired-sample requirement. Five successful samples **per matched
condition** are still not collected; that report prints its own counts as
`NOT met` rather than pooling samples across revisions or cache states.
