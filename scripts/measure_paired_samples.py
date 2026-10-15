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
            if key in ("workflow_runs", "jobs", "workflows") and isinstance(item, list):
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
    query = f"repos/{repository}/actions/workflows/{match['id']}/runs"
    if branch:
        query += f"?branch={branch}"
    separator = "&" if "?" in query else "?"
    payload = _decode_documents(_run_gh(["api", f"{query}{separator}per_page={min(limit, 100)}",
                                        "--paginate"]))
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


def download_evidence(repository: str, run_id: int, attempt: int, out: Path) -> bool:
    out.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        ["gh", "run", "download", str(run_id), "--repo", repository,
         "--pattern", "ci-timing-*", "--dir", str(out)],
        capture_output=True, text=True)
    return completed.returncode == 0


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


def collect(repository: str, workflow: str, limit: int, cache_root: Path,
            branch: str | None = None) -> list[dict]:
    """One sample per successful JOB, because the cache state is per job.

    The paired-sample requirement is about a workflow under a cache condition; a run
    mixes conditions across platforms, so a run-level row would average them away.
    """
    samples: list[dict] = []
    for run in workflow_runs(repository, workflow, limit, branch):
        run_id, attempt = run["id"], run.get("run_attempt", 1)
        evidence = cache_root / f"{run_id}-{attempt}"
        if not any(evidence.glob("*/stages.json")):
            download_evidence(repository, run_id, attempt, evidence)
        states = job_cache_states(evidence)
        wall, total = measure(jobs_of(repository, run_id, attempt))
        for job in jobs_of(repository, run_id, attempt):
            if job.get("conclusion") != "success":
                continue
            name = job.get("name") or "?"
            record = _job_state_for(name, states)
            samples.append({
                "run": run_id, "attempt": attempt, "revision": run["head_sha"][:8],
                "event": run.get("event"), "job": name[:34],
                "state": record, "jobMinutes": job_minutes(job),
                "runWallMinutes": wall, "runRunnerMinutes": total,
            })
    return samples


def _job_state_for(job_name: str, states: dict[str, str]) -> str:
    """The recorded state of the artifact directory that belongs to this job.

    Artifact directories are named `ci-timing-<kind>[-<platform>]-<run>-<attempt>`, so
    the directory sharing the job's most distinctive token is the right one. The match
    is by the longest shared token rather than by all tokens: a job name carries
    toolchain words (`Cangjie`, `STS`, `stdx`) that the artifact name does not repeat.
    Nothing matching leaves the sample `unknown` rather than guessed.
    """
    def tokens(text: str) -> set[str]:
        return {token.lower() for token in text.replace("/", " ").replace("-", " ").split()
                if len(token) > 3}

    job_tokens = tokens(job_name)
    best_state, best_score = "unknown", 0
    for directory, state in states.items():
        score = len(job_tokens & tokens(directory))
        if score > best_score:
            best_state, best_score = state, score
    return best_state


def describe(values: list[float]) -> str:
    if not values:
        return "n=0"
    if len(values) == 1:
        return f"n=1 value={values[0]:.1f}m"
    return (f"n={len(values)} median={statistics.median(values):.1f}m "
            f"min={min(values):.1f}m max={max(values):.1f}m")


def report(samples: list[dict], workflow: str, out: Path) -> dict:
    cells: dict[str, list[float]] = {}
    for sample in samples:
        cells.setdefault(sample["state"], []).append(sample["jobMinutes"])
    lines = [f"# Paired samples: {workflow}", "",
             "One row per successful JOB. The toolchain cache key includes the platform, so a",
             "single run legitimately records `hit` on one runner and `miss` on another; a",
             "run-level row would average those conditions together. A job whose artifact",
             "carries no cache state is `unknown` and is never assumed to be either condition.",
             "",
             "`job` is that job's own duration; `run wall` and `run runner` are the run's first",
             "start to last completion and the sum of all its jobs, repeated per row for context.",
             "",
             "| run | attempt | revision | event | job | cache | job wall | run wall | run runner |",
             "| --- | ---: | --- | --- | --- | --- | ---: | ---: | ---: |"]
    for sample in sorted(samples, key=lambda s: (s["run"], s["job"])):
        lines.append("| {run} | {attempt} | `{revision}` | {event} | {job} | {state} | "
                     "{jobMinutes:.1f}m | {runWallMinutes:.1f}m | {runRunnerMinutes:.1f}m"
                     "|".format(**sample))
    lines += ["", "## Per cache cell (successful jobs only)", ""]
    for state in ("miss", "hit", "unknown", "mixed"):
        if state in cells:
            lines.append(f"* **{state}**: {describe(cells[state])}")
    lines += ["", "## Requirement check", "",
              "5 successful samples per condition, per DONE-03:", ""]
    for state in ("miss", "hit"):
        count = len(cells.get(state, []))
        verdict = "met" if count >= 5 else "NOT met"
        lines.append(f"* **{state}**: {count} collected — {verdict}")
    unknown = len(cells.get("unknown", []))
    if unknown:
        lines += ["", f"{unknown} job(s) could not be classified and are excluded from the cells."]
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return {"cells": {k: len(v) for k, v in cells.items()}, "report": str(out),
            "samples": len(samples)}


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
                        help="where downloaded stage evidence is cached")
    parser.add_argument("--out", type=Path, required=True, help="report path")
    args = parser.parse_args()
    samples = collect(args.repository, args.workflow, args.limit, args.cache_root,
                      args.branch)
    if not samples:
        raise SystemExit("measure_paired_samples.py: no completed runs found")
    result = report(samples, args.workflow, args.out)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
