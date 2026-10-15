#!/usr/bin/env python3
"""Report matched warm/cold paired samples from recorded CI stage evidence.

DONE-03 asks for at least five cold and five warm paired samples per workflow under
matched conditions, reported as median and distribution with failures, cancellations
and re-runs listed separately. Two things were missing before this could be measured
at all: the cache state was never recorded, and nothing turned the recorded evidence
into a sample table.

`samples` reads the per-run stage artifacts, classifies each run by the cache state
`ci_stage.py` records, and prints the table. It deliberately refuses to invent a
classification: a run whose records carry no cache state is reported as `unknown`
rather than being assumed cold or warm, and a run is only admitted to a cell when
every stage of that run agrees on the state.

Wall time comes from the jobs API (first start to last completion), and total runner
time is the sum of every job's own duration, so parallel work is not hidden.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import statistics
import subprocess
import sys

GITHUB_TIME = "%Y-%m-%dT%H:%M:%SZ"


def _run_gh(args: list[str]) -> str:
    completed = subprocess.run(["gh", *args], capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(f"measure_paired_samples.py: gh {' '.join(args[:3])} failed: "
                         f"{completed.stderr.strip()[:300]}")
    return completed.stdout


def _decode_documents(text: str) -> dict:
    """Merge `gh api --paginate` output, which concatenates one JSON per page."""
    decoder = json.JSONDecoder()
    merged: dict = {}
    index = 0
    while index < len(text):
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index >= len(text):
            break
        value, index = decoder.raw_decode(text, index)
        if not isinstance(value, dict):
            continue
        for key, item in value.items():
            if key in ("workflow_runs", "jobs", "workflows", "artifacts") and isinstance(item, list):
                merged.setdefault(key, [])
                merged[key].extend(item)
            else:
                merged.setdefault(key, item)
    return merged


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    return dt.datetime.strptime(value, GITHUB_TIME).replace(tzinfo=dt.timezone.utc)


def workflow_runs(repository: str, workflow: str, limit: int, branch: str | None) -> list[dict]:
    """Completed runs of one workflow, newest first.

    `gh api` takes the runs endpoint either by workflow id or by file name; the id is
    resolved from the workflow list so a caller can name the workflow the way a person
    does (`CI`) without knowing the number.
    """
    # Query parameters must ride in the URL: `gh api -f` switches the request to POST,
    # which the runs/workflows endpoints answer with 404.
    workflows = _decode_documents(_run_gh(["api", f"repos/{repository}/actions/workflows?per_page=100",
                                    "--paginate"]))
    entries = workflows.get("workflows", []) if isinstance(workflows, dict) else []
    match = next((item for item in entries
                  if workflow in {item.get("name"), item.get("path"),
                                  (item.get("path") or "").rsplit("/", 1)[-1]}), None)
    if match is None:
        raise SystemExit(f"measure_paired_samples.py: no workflow matches {workflow!r}")
    # `status=completed` is asked of the API: filtering locally would consume the
    # `per_page` budget with queued and running runs, so `--limit` would return fewer
    # samples than it promises. No `--paginate` either: one page is enough for
    # `limit <= 100` and pagination would fetch the whole workflow history first.
    params = [f"per_page={min(limit, 100)}", "status=completed"]
    if branch:
        params.append(f"branch={branch}")
    query = (f"repos/{repository}/actions/workflows/{match['id']}/runs?"
             + "&".join(params))
    # Pagination is requested only when the caller asks for more than one page; a
    # `--limit` above the page size would otherwise silently return at most 100 runs
    # and miss the older samples it was asked for, while the default would fetch the
    # whole history to look at a handful of runs.
    args = ["api", query] + (["--paginate"] if limit > 100 else [])
    payload = _decode_documents(_run_gh(args))
    runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
    return [run for run in runs if run.get("status") == "completed"][:limit]


def jobs_of(repository: str, run_id: int, attempt: int) -> list[dict]:
    payload = _decode_documents(_run_gh([
        "api", f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100",
        "--paginate"]))
    return payload.get("jobs", []) if isinstance(payload, dict) else []


def job_cache_states(evidence: Path) -> dict[str, str]:
    """Map a job's artifact name prefix to the cache state its stage records carry.

    The state is per JOB, not per run: the toolchain cache key includes the platform,
    so one run legitimately records `hit` for a job on one runner and `miss` for a job
    on another. Each artifact directory is named after the job, so the directory name
    is the job identity here.
    """
    states: dict[str, str] = {}
    for path in sorted(evidence.glob("*/stages.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        found: set[str] = set()
        for stage in document.get("stages", []):
            cache = (stage.get("environment") or {}).get("cache") or {}
            found.update(cache.values())
        states[path.parent.name] = (found.pop() if len(found) == 1
                                    else "unknown" if not found else "mixed")
    return states


def matching_artifacts(repository: str, run_id: int, attempt: int) -> list[dict]:
    """The `ci-timing-*` artifacts belonging to ONE attempt.

    `gh run download <run-id>` keeps artifacts from earlier attempts, so a rerun would
    hand attempt 1's cache state to attempt 2's jobs. `workflow_run.attempt` on the
    artifact is the authority, so artifacts are selected from the API by it and
    downloaded by artifact id.
    """
    payload = _decode_documents(_run_gh([
        "api", f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100",
        "--paginate"]))
    suffix = f"-{run_id}-{attempt}"
    return [artifact for artifact in payload.get("artifacts", [])
            if str(artifact.get("name", "")).startswith("ci-timing-")
            and str(artifact.get("name", "")).endswith(suffix)]


def download_evidence(repository: str, run_id: int, attempt: int, out: Path) -> bool:
    """Download this attempt's stage artifacts, each into its own directory.

    The artifact is fetched by id, so a retained artifact from an earlier attempt
    cannot be picked up, and each artifact keeps its own directory whatever the count
    (a single-artifact download otherwise extracts into the output root, which the
    glob below would miss).
    """
    out.mkdir(parents=True, exist_ok=True)
    ok = False
    for artifact in matching_artifacts(repository, run_id, attempt):
        target = out / artifact["name"]
        if (target / "stages.json").is_file():
            ok = True
            continue
        completed = subprocess.run(
            ["gh", "api", f"repos/{repository}/actions/artifacts/{artifact['id']}/zip",
             "-H", "Accept: application/vnd.github+json"],
            capture_output=True)
        if completed.returncode != 0:
            continue
        target.mkdir(parents=True, exist_ok=True)
        import io
        import zipfile
        try:
            with zipfile.ZipFile(io.BytesIO(completed.stdout)) as archive:
                archive.extractall(target)
        except zipfile.BadZipFile:
            continue
        ok = True
    return ok


def measure(jobs: list[dict]) -> tuple[float, float]:
    """(wall minutes, total job minutes) for one run."""
    windows = [(parse_time(job.get("started_at")), parse_time(job.get("completed_at")))
               for job in jobs]
    real = [(start, end) for start, end in windows if start and end]
    if not real:
        return 0.0, 0.0
    wall = (max(end for _, end in real) - min(start for start, _ in real)).total_seconds() / 60
    total = sum((end - start).total_seconds() / 60 for start, end in real)
    return round(wall, 1), round(total, 1)


def job_minutes(job: dict) -> float:
    start, end = parse_time(job.get("started_at")), parse_time(job.get("completed_at"))
    if not start or not end:
        return 0.0
    return round((end - start).total_seconds() / 60, 1)


def job_shape(job_name: str) -> str:
    """The stable identity of a job across runs: its platform.

    DONE-03 requires samples under MATCHED conditions. Grouping by cache state alone
    would mix, for example, a Linux candidate job with a macOS acceptance job, and
    five hits of one shape against five misses of another would "satisfy" the
    requirement without ever comparing a warm run against a cold one on the same job.
    The platform prefix is the part of the job name that is stable run to run; the
    toolchain suffix is not (it changes with the SDK pin).
    """
    head = job_name.split("/", 1)[0].strip().lower()
    return head or "unknown"


def collect(repository: str, workflow: str, limit: int, cache_root: Path,
            branch: str | None = None) -> list[dict]:
    """One sample per successful JOB, because the cache state is per job.

    The paired-sample requirement is about a workflow under a cache condition; a run
    mixes conditions across platforms, so a run-level row would average them away.
    """
    samples: list[dict] = []
    for run in workflow_runs(repository, workflow, limit, branch):
        run_id = run["id"]
        latest = run.get("run_attempt", 1)
        # Every attempt of the run is inspected, not only the latest: a failed or
        # cancelled attempt 1 is part of the experiment record DONE-03 asks for, and
        # resolving to `run_attempt` would erase it.
        seen_job_keys: set[tuple[str | None, str | None]] = set()
        for attempt in range(1, latest + 1):
            produced, observed = _attempt_samples(repository, run, run_id, attempt,
                                                  cache_root, seen_job_keys)
            samples.extend(produced)
            # Every job OBSERVED in this attempt, not only the ones kept: a job the engine
            # genuinely re-ran under the same name has a new started_at, so it is not
            # suppressed, while a carried-forward one has the old started_at and is.
            seen_job_keys |= observed
    return samples


def _attempt_samples(repository: str, run: dict, run_id: int, attempt: int,
                     cache_root: Path, earlier: set[tuple[str | None, str | None]]) -> tuple[list[dict],
                                                                           set[tuple[str | None,
                                                                                     str | None]]]:
    # Called unconditionally: it skips artifact directories that are already complete
    # and retries the rest, so an interrupted or partially failed download does not
    # leave those jobs `unknown` until someone deletes the cache by hand.
    evidence = cache_root / f"{run_id}-{attempt}"
    download_evidence(repository, run_id, attempt, evidence)
    states = job_cache_states(evidence)
    # `Re-run failed jobs` executes only the failed jobs and their dependents; the
    # attempt response still carries the successful jobs from the previous attempt,
    # reported as if they belonged to this one. Their `run_attempt` says the new attempt
    # and their times are the old ones, so the only usable signal is that an untouched
    # job keeps the identical started_at it had before. Jobs whose (name, started_at)
    # already appeared in an earlier attempt are therefore excluded here, which also
    # keeps them out of the wall-clock and runner-minute totals.
    jobs = [job for job in jobs_of(repository, run_id, attempt)
            if (job.get("name"), job.get("started_at")) not in earlier]
    wall, total = measure(jobs)
    samples: list[dict] = []
    observed: set[tuple[str | None, str | None]] = set()
    for job in jobs:
        name = job.get("name") or "?"
        conclusion = job.get("conclusion") or "unknown"
        samples.append({
            "run": run_id, "attempt": attempt, "revision": run["head_sha"][:8],
            "event": run.get("event"), "job": name[:34], "shape": job_shape(name),
            # Unsuccessful jobs are kept: DONE-03 wants failures, cancellations and
            # re-runs listed separately, and dropping them here would lose them.
            "conclusion": conclusion,
            # Resolved for unsuccessful jobs too: a job that restored the cache and
            # then failed still records which condition it ran under, and DONE-03 asks
            # for failures under matched conditions. Such jobs stay out of the cells.
            "state": _job_state_for(name, states),
            "jobMinutes": job_minutes(job),
            "runWallMinutes": wall, "runRunnerMinutes": total,
        })
        observed.add((name, job.get("started_at")))
    return samples, observed


# Job name prefix -> the artifact stem that carries that job's stage evidence.
# Explicit rather than scored: `linux-x64` and `Linux candidate` both contain "linux",
# and `x64` is too short to discriminate, so a token score ties and then resolves by
# directory order -- which handed the acceptance job the candidate's cache state.
JOB_ARTIFACT_STEMS: tuple[tuple[str, str], ...] = (
    ("candidate", "build-linux-candidate"),
    ("windows", "ci-windows-x64"),
    ("macos", "ci-macos-arm64"),
    ("linux", "ci-linux-x64"),
)


def job_artifact_stem(job_name: str) -> str | None:
    """The timing artifact stem this job's evidence lands in, if it has one.

    `None` means the job records no stage evidence (the orchestration gates), which is
    a different thing from a cache-bearing job whose state was not recorded.
    """
    lowered = job_name.lower()
    for token, stem in JOB_ARTIFACT_STEMS:
        if token in lowered:
            return stem
    return None


def _job_state_for(job_name: str, states: dict[str, str]) -> str:
    """The recorded state for this job: a state, or `unknown` when it has none.

    `unknown` therefore covers both "the job has an artifact but it carries no state"
    and "the artifact was not downloaded"; callers that need to tell those apart use
    `job_artifact_stem`.
    """
    stem = job_artifact_stem(job_name)
    if stem is None:
        return "unknown"
    for directory, state in states.items():
        if stem in directory:
            return state
    return "unknown"


def describe(values: list[float]) -> str:
    if not values:
        return "n=0"
    if len(values) == 1:
        return f"n=1 value={values[0]:.1f}m"
    return (f"n={len(values)} median={statistics.median(values):.1f}m "
            f"min={min(values):.1f}m max={max(values):.1f}m")


CLASSIFIED_STATES = ("hit", "miss")


def report(samples: list[dict], workflow: str, out: Path,
           provenance: str | None = None) -> dict:
    successful = [s for s in samples if s["conclusion"] == "success"]
    other = [s for s in samples if s["conclusion"] != "success"]
    # Only classified states form cells and requirements. A job with no timing
    # artifact (`Classify changes`, `CI required`) can never be hit or miss, and
    # demanding five of each for it would keep DONE-03 unmet forever.
    classified = [s for s in successful if s["state"] in CLASSIFIED_STATES]
    cells: dict[tuple[str, str], list[float]] = {}
    for sample in classified:
        cells.setdefault((sample["shape"], sample["state"]), []).append(sample["jobMinutes"])
    lines = [f"# Paired samples: {workflow}", ""]
    if provenance:
        # Emitted by the reporter so the checked-in file is genuinely its output and the
        # regeneration command it shows is the one that produced it (the `--out` is
        # included, since a command without it writes nothing).
        lines += [provenance, ""]
    lines += ["One row per JOB. The toolchain cache key includes the platform, so a single run",
             "legitimately records `hit` on one runner and `miss` on another. Cells are keyed",
             "by **(job shape, cache state)**: DONE-03 asks for samples under MATCHED",
             "conditions, so a Linux hit is never pooled with a macOS miss.",
             "",
             "A job whose artifact carries no cache state is `unknown` and is never assumed to",
             "be either condition. Failed and cancelled jobs are listed separately below and",
             "are excluded from the cells, not from the record.",
             "",
             "| run | attempt | revision | event | job | shape | conclusion | cache | "
             "job wall | run wall | run runner |",
             "| --- | ---: | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: |"]
    for sample in sorted(samples, key=lambda s: (s["run"], s["job"])):
        lines.append("| {run} | {attempt} | `{revision}` | {event} | {job} | {shape} | "
                     "{conclusion} | {state} | {jobMinutes:.1f}m | {runWallMinutes:.1f}m | "
                     "{runRunnerMinutes:.1f}m |".format(**sample))
    # Workflow-level totals, which the per-job column above cannot express: a run's wall
    # time and its total runner time are what the wall-clock and cost comparisons use.
    # Keyed by (run, ATTEMPT): keying by run alone collapses a re-run's attempts and
    # lets a cancelled attempt 1 supply the attempt 2 timing.
    seen: dict[tuple[int, int], tuple[float, float]] = {}
    for sample in samples:
        seen.setdefault((sample["run"], sample["attempt"]),
                        (sample["runWallMinutes"], sample["runRunnerMinutes"]))
    if seen:
        walls = [value[0] for value in seen.values()]
        runners = [value[1] for value in seen.values()]
        lines += ["", "### Workflow level (one row per run attempt)", "",
                  "| run | attempt | wall | runner |", "| --- | ---: | ---: | ---: |"]
        for run_id, attempt in sorted(seen):
            wall, runner = seen[(run_id, attempt)]
            lines.append(f"| {run_id} | {attempt} | {wall:.1f}m | {runner:.1f}m |")
        lines += ["", f"* wall across {len(walls)} run attempt(s): {describe(walls)}",
                  f"* runner minutes across {len(runners)} run attempt(s): "
                  f"{sum(runners):.1f}m total, max {max(runners):.1f}m"]
    lines += ["", "## Matched cells (successful jobs only)", ""]
    for key in sorted(cells):
        shape, state = key
        lines.append(f"* **{shape} / {state}**: {describe(cells[key])}")
    # Requirement shapes come from every cache-bearing job, not only from the cells: a
    # platform whose artifacts expired or whose samples all predate the recording would
    # otherwise vanish from the report instead of showing as an unmet cell.
    # Drawn from ALL samples, not only the successful ones: a platform whose every
    # occurrence failed or was cancelled would otherwise drop out of the requirement
    # section, and the remaining cells could read as met while that platform has no
    # successful sample at all. Only successful jobs enter `cells`.
    requirement_shapes = {s["shape"] for s in samples
                          if job_artifact_stem(s["job"]) is not None}
    requirement_shapes |= {key[0] for key in cells}
    lines += ["", "## Requirement check", "",
              "5 successful samples per matched cell (job shape x condition), per DONE-03:", ""]
    for shape in sorted(requirement_shapes):
        for state in ("miss", "hit"):
            count = len(cells.get((shape, state), []))
            verdict = "met" if count >= 5 else "NOT met"
            lines.append(f"* {shape} / **{state}**: {count} collected — {verdict}")
    unclassified = [s for s in successful if s["state"] not in CLASSIFIED_STATES]
    if unclassified:
        never = sorted({s["shape"] for s in unclassified
                        if job_artifact_stem(s["job"]) is None})
        unrecorded = sorted({s["shape"] for s in unclassified
                             if job_artifact_stem(s["job"]) is not None})
        parts = [f"{len(unclassified)} successful job(s) carry no cache state and are "
                 "excluded from the cells."]
        if never:
            parts.append(f"Of those, {', '.join(never)} record no stage evidence at all, "
                         "so they can never be either condition and are not requirements.")
        if unrecorded:
            parts.append(f"The rest ({', '.join(unrecorded)}) are cache-bearing jobs whose "
                         "state was not recorded -- from runs predating the recording, or "
                         "from artifacts that expired -- so they remain requirements showing "
                         "as 0 collected above rather than disappearing.")
        lines += ["", " ".join(parts)]
    lines += ["", "## Failures, cancellations and re-runs (excluded from the cells)", ""]
    if other:
        for sample in sorted(other, key=lambda s: (s["run"], s["job"])):
            lines.append(f"* run `{sample['run']}` attempt {sample['attempt']} "
                         f"(`{sample['revision']}`, {sample['event']}): {sample['job']} — "
                         f"**{sample['conclusion']}**, cache {sample['state']}")
    else:
        lines.append("* none: every sampled job concluded successfully")
    reruns = sorted({s["attempt"] for s in samples if s["attempt"] > 1})
    lines.append("")
    if reruns:
        lines.append(f"Re-run attempts present in this sample: {', '.join(map(str, reruns))}. "
                     "They are retained, not resolved to the latest attempt.")
    else:
        lines.append("No re-runs in this sample.")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {"cells": {f"{shape}/{state}": len(values)
                      for (shape, state), values in cells.items()},
            "failures": len(other), "report": str(out), "samples": len(samples),
            "runs": {f"{run_id}/{attempt}": {"wallMinutes": value[0],
                                             "runnerMinutes": value[1]}
                     for (run_id, attempt), value in sorted(seen.items())}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="owner/name")
    parser.add_argument("--workflow", required=True,
                        help="workflow name, path, or file name, e.g. CI / ci.yml")
    parser.add_argument("--branch", default="main",
                        help="branch to sample; the paired-sample requirement is about the "
                             "merged main, so this defaults to it")
    parser.add_argument("--limit", type=int, default=20, help="runs to inspect")
    parser.add_argument("--cache-root", type=Path, default=Path("target/paired-samples"),
                        help="where downloaded stage evidence is cached (repo-relative by "
                             "default so the emitted provenance is reproducible)")
    parser.add_argument("--out", type=Path, required=True, help="report path")
    args = parser.parse_args()
    samples = collect(args.repository, args.workflow, args.limit, args.cache_root,
                      args.branch)
    if not samples:
        raise SystemExit("measure_paired_samples.py: no completed runs found")
    provenance = ("Generated by `python3 scripts/measure_paired_samples.py "
                  f"--repository {args.repository} --workflow {args.workflow} "
                  f"--branch {args.branch} --limit {args.limit} "
                  f"--cache-root {args.cache_root} --out {args.out}`. "
                  "Point-in-time capture: regenerate with that command rather than "
                  "editing this file.")
    result = report(samples, args.workflow, args.out, provenance)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
