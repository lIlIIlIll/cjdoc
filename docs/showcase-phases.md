# Showcase phase attribution and the parallelisation decision (issue #82 / #93)

Issue #93 covers CI-06.2, 06.4 and 06.6, and it is measurement-first: parallelise
only what the data justifies, and record a decision *not* to parallelise just as
traceably.

The data below is one real Pages run, read from its uploaded
`showcase-stages.json` artifact:

```bash
gh run download 39213457031 -n ci-timing-pages-assemble-39213457031-1
```

Run `39213457031`, revision `7d15f276`, assembly stage `site-assemble`, all 21
phases `exitCode: 0`. The recorded field is `wallMs` per phase.

## Per-phase wall time

| phase | wall | share |
| --- | ---: | ---: |
| `showcase.api` | 459.5 s | 63.9% |
| `pocketkit.generate:all:demo-v2` | 57.1 s | 7.9% |
| `pocketkit.generate:all:demo-v1` | 53.0 s | 7.4% |
| `pocketkit.compose` | 49.9 s | 6.9% |
| `showcase.authoring` | 41.8 s | 5.8% |
| `showcase.link-validate` | 10.2 s | 1.4% |
| `showcase.navigation` | 9.3 s | 1.3% |
| `showcase.offline-archive` | 7.5 s | 1.0% |
| `showcase.plan-baseline` | 7.2 s | 1.0% |
| `showcase.legacy` | 6.3 s | 0.9% |
| `pocketkit.diagnostics:en` | 3.9 s | 0.5% |
| `showcase.reports` | 3.6 s | 0.5% |
| `pocketkit.diagnostics:zh-CN` | 3.6 s | 0.5% |
| `pocketkit.support-index` | 3.2 s | 0.4% |
| `pocketkit.check-modes` | 2.3 s | 0.3% |
| `pocketkit.diff` | 0.1 s | 0.0% |
| `showcase.tool-versions`, `showcase.downloads`, `showcase.source-copy`, `showcase.homepage`, `showcase.site-copy` | < 0.2 s each | ~0% |
| **sum** | **718.8 s** | 100% |

The previously unattributed "6 m 41 s" figure is now fully attributed: no phase
is unexplained, and every phase has its own id.

## The shape is already concurrent, and this run proves it

`scripts/showcase_build/integration.py` joins two branches with
`BranchRunner().pair(api_branch, pocketkit_branch)`. The per-phase numbers
confirm the model, because the phase sum (718.8 s) **exceeds** the assembly job's
wall clock:

| component | wall |
| --- | ---: |
| API branch (`showcase.api`) | 459.5 s |
| PocketKit branch (`check-modes` + `support-index` + `generate` + `diagnostics` + `compose` + `diff`, including the private `showcase.source-copy`) | 173.1 s |
| post-join tail (`site-copy` onwards) | 86.0 s |
| model: `max(459.5, 173.1) + 86.0` | 545.5 s |
| measured `Assemble final site` job wall | **573.2 s** |

The measured job wall is 573.2 s against a 718.8 s serial sum, so **145.6 s
(20.3%) of serial work is already overlapped**; the 27.7 s difference between the
model and the measurement is process startup and the git/CLI steps the phases do
not cover. What matters is the direction: the job is faster than the sum of its
phases, which is only possible if they overlap. CI-06.2's "evaluate parallel
branches after the index barrier" is therefore already realised for the two
independent branches, and no further branch-level parallelisation of these phases
is waiting to be unlocked.

## Decision on the remaining candidates

**06.2 — additional locale/version branching inside PocketKit: not implemented.**
The serial chain inside the PocketKit branch is measured and small:
`support-index` 3.2 s (the barrier), then `generate:all:demo-v1` 53.0 s,
`generate:all:demo-v2` 57.1 s, `diagnostics` 3.6–3.9 s each, `compose` 49.9 s.
Splitting the two versions across processes would overlap at most ~110 s against
the 459.5 s API branch that already governs the join, so it would not shorten the
assembly job — the API branch is the critical path and stays so. Adding
concurrency here would buy wall clock only if API dropped below PocketKit, which
is not the observed shape. Recorded rather than implemented, per #82's rule.

**06.4 — "one extraction, many renders": implemented, and already exercised.**
`cjdoc generate --all-languages` performs one extraction and projects every
language from it (#122 records its delivery after #64 merged); `generate_api`
above runs `--locale en --doc-version main --agent-full` with all formats in one
invocation. No `ThreadPoolExecutor` was added, which is still correct.

**06.6 — profile before optimising repetitive traversal: profiled, nothing to
change.** The phases that would pay for it (`link-validate` 10.2 s, `navigation`
9.3 s, `offline-archive` 7.5 s, `plan-baseline` 7.2 s) total under 5% of the
build. Optimising them cannot move the critical path, and the input-identity
checks they perform are exactly what must not be removed. No change.

## What would actually shorten this job

`showcase.api` alone is 63.9% of the work: one `cjdoc generate` over the
repository itself with every format, `--agent-full` and `--no-cache`. Any real
win has to come from that invocation (for example its own internal
extraction/render split), not from adding branches around it. That is a
generator-side change with its own acceptance, and it is not claimed here.
