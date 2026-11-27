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

A matched cell is keyed by (job shape, cache state, environment), where the
environment is the runner image, SDK/stdx identity, toolchain target and effective
compile options. The source revision is NOT part of the key: DONE-03 asks for
"before (main) vs after (branch)" samples, which by definition come from different
revisions, so keying on the commit made the requirement unreachable -- each push
became its own cell with one sample. The revision is retained per sample and shown
in every table, so a cell's samples can always be traced back to their commits.

Wall time comes from the jobs API (first start to last completion), and total runner
time is the sum of every job's own duration, so parallel work is not hidden.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import urllib.parse
import sys

try:
    from .paired_sample_report import BROWSER_FONT_AXES, report
except ImportError:  # Direct script execution.
    from paired_sample_report import BROWSER_FONT_AXES, report

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


def resolve_workflow_file(repository: str, workflow: str) -> str:
    """The workflow's file name for a name, path or file the user supplied."""
    workflows = _decode_documents(_run_gh([
        "api", f"repos/{repository}/actions/workflows?per_page=100"]))
    entries = workflows.get("workflows", []) if isinstance(workflows, dict) else []
    for item in entries:
        path = item.get("path") or ""
        if workflow in {item.get("name"), path, path.rsplit("/", 1)[-1]}:
            return path.rsplit("/", 1)[-1]
    raise SystemExit(f"measure_paired_samples.py: no workflow matches {workflow!r}")


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
    # One page is the budget, and a larger `--limit` is REFUSED rather than paginated:
    # `--paginate` fetches the workflow's whole history before the slice, which on a
    # long-lived workflow is thousands of requests for a sample set of dozens. The
    # caller can raise this deliberately once there is a reason to.
    if limit > 100:
        raise SystemExit("measure_paired_samples.py: --limit above 100 would paginate the "
                         "workflow's entire history; request at most 100 runs")
    params = [f"per_page={limit}", "status=completed"]
    if branch:
        # Percent-encoded: a valid ref may contain characters that end or alter the
        # query (`feature/a&b`, `release#1`), which would silently select other runs.
        params.append("branch=" + urllib.parse.quote(branch, safe=""))
    query = (f"repos/{repository}/actions/workflows/{match['id']}/runs?"
             + "&".join(params))
    payload = _decode_documents(_run_gh(["api", query]))
    runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
    return [run for run in runs if run.get("status") == "completed"][:limit]


def jobs_of(repository: str, run_id: int, attempt: int) -> list[dict]:
    payload = _decode_documents(_run_gh([
        "api", f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100",
        "--paginate"]))
    return payload.get("jobs", []) if isinstance(payload, dict) else []


# The fields that make up a matched condition. DONE-03 names the browser and font set
# as part of it, so the last three slots exist to keep those axes in the signature.
IDENTITY_FIELDS = ("runnerImage", "sdkVersion", "stdxDigest", "toolchainTarget",
                   "toolchainFingerprint", "browserVersion", "browserIdentity",
                   "fontSetDigest")
# Stage kinds that drive a real browser. A job whose evidence contains none of these
# has no browser/font condition to match, so the axis is not applicable to it rather
# than missing from it: `ci.yml` installs Chromium only for the Linux job's `html-a11y`
# stage, so macOS and Windows build-and-test without ever opening a page.
#
# `reading` is here because it really launches Chromium --
# `showcase_contract/browser_reading_regressions.run` calls `playwright.chromium.launch`
# -- and a browser stage missing from this set is excused as "not applicable" while it
# rendered pages, which is the one direction the applicability rule must never take.
# It reports no identity of its own and publishes no `ci-timing-*` artifact, so it
# contributes no cell today; were one built from it, the missing axis would qualify the
# verdict rather than excuse it.
BROWSER_STAGE_KINDS = frozenset({"browser", "browser-shard", "reading"})
# Cache keys a stage kind MUST carry before its record counts as a warmth measurement.
# A browser shard restores the CJK fonts AND the Playwright browser build, and either
# miss lengthens the job. An artifact written before the second key was recorded
# carries `{"fonts": "hit"}` alone; collapsed to a bare `hit` it would pool a shard
# that downloaded Chromium with a genuinely warm one -- the false pairing the second
# key exists to prevent. A partial record is therefore not a state at all.
REQUIRED_CACHE_KEYS = {"browser-shard": frozenset({"fonts", "playwright"})}


def job_conditions(evidence: Path) -> dict[str, str]:
    """Per artifact directory, the toolchain/runner identity its stages recorded.

    DONE-03 requires paired samples under MATCHED conditions, so a cell must not pool
    a hit from one toolchain pin with a miss from another. The signature covers the
    runner image, SDK/stdx identity, toolchain fingerprint, toolchain target and
    effective compile options. The source revision is NOT part of it: DONE-03's
    before/after samples are different commits by definition (see the docstring header).
    """
    conditions: dict[str, str] = {}
    identity_fields = IDENTITY_FIELDS

    def stage_identity(source: dict) -> str:
        """One canonical serialization of a stage's comparable identity.

        The first stage and every later stage go through THIS function, so identical
        environments always serialize identically. Building the first stage one way and
        later stages another made every later stage look divergent, which split
        artifacts that share an environment into different cells.
        """
        value = "|".join(str(source.get(field, "")) for field in identity_fields)
        return value + "|" + ",".join(
            str(option) for option in (source.get("compileOptions") or []))

    for path in sorted(evidence.glob("*/stages.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        stages = document.get("stages", [])
        if not stages:
            continue
        environment = stages[0].get("environment") or {}
        signature = stage_identity(environment)
        # EVERY stage is read, not only the first: a job whose later stage compiled with
        # different flags or a different toolchain must not be pooled with one that did
        # not. Each diverging stage contributes its complete identity tuple, so the
        # stage boundaries are preserved -- two artifacts differing in the same fields
        # but in a different order of stages cannot collide.
        for index, stage in enumerate(stages[1:], start=2):
            later = stage_identity(stage.get("environment") or {})
            if later != signature.split("|stage", 1)[0]:
                signature += f"|stage{index}={later}"
        # The browser/font axis is attested by the stages that RENDERED, not by every
        # stage: a preflight or compile stage never has a Chromium version, and
        # requiring one from it would make the axis unreachable for the multi-stage job
        # DONE-03 actually samples. The marker is part of the signature, so two
        # artifacts whose browser stages attest different axes never share a cell.
        attested: list[str] = []
        for stage in stages:
            if stage.get("kind") not in BROWSER_STAGE_KINDS:
                continue
            recorded = stage.get("environment") or {}
            for field, _name in BROWSER_FONT_AXES:
                if str(recorded.get(field) or "").strip() and field not in attested:
                    attested.append(field)
        if any(stage.get("kind") in BROWSER_STAGE_KINDS for stage in stages):
            signature += "|browser=" + ",".join(attested)
        conditions[path.parent.name] = signature
    return conditions


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
        partial = False
        for stage in document.get("stages", []):
            cache = (stage.get("environment") or {}).get("cache") or {}
            found.update(cache.values())
            required = REQUIRED_CACHE_KEYS.get(stage.get("kind"))
            if required is not None and not required <= set(cache):
                # One recorded key cannot speak for a job whose other cost-bearing
                # cache went unrecorded. `unknown` (not `mixed`) is the honest label:
                # `mixed` claims the job really ran split, and this one was never
                # measured on the missing axis.
                partial = True
        if partial:
            states[path.parent.name] = "unknown"
            continue
        states[path.parent.name] = (found.pop() if len(found) == 1
                                    else "unknown" if not found else "mixed")
    return states


def job_browser_usage(evidence: Path) -> dict[str, bool]:
    """Per artifact directory, whether its stages drove a real browser.

    DONE-03's sample condition names the browser/font set. A job that never opens a
    browser has no such condition to match, so the axis is not applicable to its cells
    instead of missing from them. Applicability is derived from recorded stage kinds
    rather than from a job-name list: `ci.yml` installs Chromium only for the Linux
    job's `html-a11y` stage, but a workflow change that adds or removes that stage must
    move the answer with it, and a hard-coded platform list would not.
    """
    usage: dict[str, bool] = {}
    for path in sorted(evidence.glob("*/stages.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        usage[path.parent.name] = any(
            stage.get("kind") in BROWSER_STAGE_KINDS
            for stage in document.get("stages", []))
    return usage


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


def _readable_stage_record(path: Path) -> bool:
    """Whether a cached `stages.json` is complete enough to use.

    A truncated file is worse than a missing one: it is taken as cached and then breaks
    every later report. Validating the JSON here means an interrupted download is
    retried instead.
    """
    try:
        json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return True


def download_evidence(repository: str, run_id: int, attempt: int,
                      out: Path) -> list[str]:
    """Download this attempt's stage artifacts, each into its own directory.

    The artifact is fetched by id, so a retained artifact from an earlier attempt cannot
    be picked up, and each artifact keeps its own directory whatever the count (a
    single-artifact download otherwise extracts into the output root, which the state
    glob would miss).

    Returns the names of artifacts that could NOT be collected. "Some artifact
    succeeded" is not the same answer as "the evidence is complete": a job whose
    artifact is missing becomes `unknown` and drops out of its cell, which would make a
    failed collection look like an unmet requirement.
    """
    import io
    import zipfile

    out.mkdir(parents=True, exist_ok=True)
    failed: list[str] = []
    for artifact in matching_artifacts(repository, run_id, attempt):
        target = out / artifact["name"]
        if (target / "stages.json").is_file() and \
                _readable_stage_record(target / "stages.json"):
            continue
        completed = subprocess.run(
            ["gh", "api", f"repos/{repository}/actions/artifacts/{artifact['id']}/zip"],
            capture_output=True)
        if completed.returncode != 0 or not completed.stdout:
            failed.append(artifact["name"])
            continue
        # Extract into a temporary directory and rename into place, so an interrupted
        # run cannot leave a half-written `stages.json` behind.
        staging = out / f".{artifact['name']}.partial"
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(parents=True, exist_ok=True)
        try:
            with zipfile.ZipFile(io.BytesIO(completed.stdout)) as archive:
                archive.extractall(staging)
        except (zipfile.BadZipFile, OSError):
            shutil.rmtree(staging, ignore_errors=True)
            failed.append(artifact["name"])
            continue
        if not (staging / "stages.json").is_file() or \
                not _readable_stage_record(staging / "stages.json"):
            shutil.rmtree(staging, ignore_errors=True)
            failed.append(artifact["name"])
            continue
        if target.exists():
            shutil.rmtree(target, ignore_errors=True)
        staging.rename(target)
    return failed


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
    acquisition_failures: list[dict] = []
    for run in workflow_runs(repository, workflow, limit, branch):
        run_id = run["id"]
        latest = run.get("run_attempt", 1)
        # Every attempt of the run is inspected, not only the latest: a failed or
        # cancelled attempt 1 is part of the experiment record DONE-03 asks for, and
        # resolving to `run_attempt` would erase it.
        seen_job_keys: set[tuple[str | None, str | None]] = set()
        for attempt in range(1, latest + 1):
            produced, observed = _attempt_samples(repository, run, run_id, attempt,
                                                  cache_root, seen_job_keys,
                                                  acquisition_failures, workflow)
            samples.extend(produced)
            # Every job OBSERVED in this attempt, not only the ones kept: a job the engine
            # genuinely re-ran under the same name has a new started_at, so it is not
            # suppressed, while a carried-forward one has the old started_at and is.
            seen_job_keys |= observed
    if acquisition_failures:
        # Carried to `report` so a partial collection is stated rather than silently
        # producing `unknown` jobs and an apparently unmet requirement.
        samples.append({"_acquisitionFailures": acquisition_failures})
    return samples


def _attempt_samples(repository: str, run: dict, run_id: int, attempt: int,
                     cache_root: Path, earlier: set[tuple[str | None, str | None]],
                     acquisition_failures: list[dict],
                     workflow: str) -> tuple[list[dict],
                                             set[tuple[str | None, str | None]]]:
    # Called unconditionally: it skips artifact directories that are already complete
    # and retries the rest, so an interrupted or partially failed download does not
    # leave those jobs `unknown` until someone deletes the cache by hand.
    evidence = cache_root / f"{run_id}-{attempt}"
    missing = download_evidence(repository, run_id, attempt, evidence)
    if missing:
        # Reported, not swallowed: a job whose artifact is missing would silently be
        # `unknown` and drop out of its matched cell, so the report could claim a
        # requirement unmet while collection actually failed.
        acquisition_failures.append({"run": run_id, "attempt": attempt,
                                     "artifacts": missing})
    states = job_cache_states(evidence)
    conditions = job_conditions(evidence)
    browser_usage = job_browser_usage(evidence)
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
            # The full SHA is kept as non-key metadata: the revision must not split a
            # cell (that is the environment's job), but an 8-hex prefix can collide
            # and would then silently merge two commits in the displayed provenance.
            "revisionFull": run["head_sha"],
            "event": run.get("event"), "job": name[:34], "shape": job_shape(name),
            # Unsuccessful jobs are kept: DONE-03 wants failures, cancellations and
            # re-runs listed separately, and dropping them here would lose them.
            "conclusion": conclusion,
            # Resolved for unsuccessful jobs too: a job that restored the cache and
            # then failed still records which condition it ran under, and DONE-03 asks
            # for failures under matched conditions. Such jobs stay out of the cells.
            "state": _job_state_for(name, states, workflow),
            "condition": _job_condition_for(name, conditions, workflow),
            # Recorded per sample so `report` never has to re-derive the mapping from a
            # job name alone, which is workflow-specific.
            "hasEvidence": job_artifact_stem(name, workflow) is not None,
            # Whether this job's stages drove a browser, which decides if DONE-03's
            # browser/font condition applies to it at all.
            "browserDriven": _job_browser_for(name, browser_usage, workflow),
            "workflow": workflow,
            "jobMinutes": job_minutes(job),
            "runWallMinutes": wall, "runRunnerMinutes": total,
        })
        observed.add((name, job.get("started_at")))
    return samples, observed


# Job name prefix -> the artifact stem that carries that job's stage evidence, PER
# WORKFLOW. Explicit rather than scored: `linux-x64` and `Linux candidate` both contain
# "linux" and `x64` is too short to discriminate, so a token score ties and then resolves
# by directory order -- which handed the acceptance job the candidate's cache state.
#
# The stems are workflow-specific because each workflow names its own timing artifact
# (`ci.yml` uses `ci-linux-x64`/`ci-<platform>`, `pages.yml` uses `pages-assemble`,
# `daily.yml` uses `daily`), and matching one workflow's jobs against another's stems
# reports real evidence as `unknown`.
JOB_ARTIFACT_STEMS: dict[str, tuple[tuple[str, str], ...]] = {
    "ci.yml": (
        ("candidate", "build-linux-candidate"),
        ("windows", "ci-windows-x64"),
        ("macos", "ci-macos-arm64"),
        ("linux", "ci-linux-x64"),
    ),
    "pages.yml": (
        ("assemble", "pages-assemble"),
        # Each browser shard records the Chromium and font set it rendered with, so its
        # record is a sample in its own right. The index is part of the stem because
        # both shards are separate artifacts: a shared stem would resolve every shard to
        # whichever directory the glob found first, so shard 0 would report shard 1's
        # condition. The indexes mirror the workflow's `shard: [0, 1]` matrix; a shard
        # added there without an entry here reports `unknown` rather than borrowing its
        # sibling's evidence.
        ("browser shard 0", "pages-browser-shard-0"),
        ("browser shard 1", "pages-browser-shard-1"),
    ),
    "daily.yml": (
        # The daily artifact is `ci-timing-daily-*` but its only job is named
        # `linux-x64 / Cangjie <version> STS`, so the job token is the platform.
        ("linux", "daily"),
    ),
    "build-linux-candidate.yml": (
        ("candidate", "build-linux-candidate"),
    ),
}


def stems_for(workflow: str) -> tuple[tuple[str, str], ...]:
    """The job->artifact mapping for a workflow, refusing one with no mapping.

    A silent empty mapping would report every job as `unknown` while looking like a
    legitimate "no samples" result, so an unsupported workflow is an error.
    """
    candidates = [workflow, workflow.rsplit("/", 1)[-1], f"{workflow}.yml"]
    for key in candidates:
        if key in JOB_ARTIFACT_STEMS:
            return JOB_ARTIFACT_STEMS[key]
    raise SystemExit(f"measure_paired_samples.py: no artifact mapping for workflow "
                     f"{workflow!r} (known: {', '.join(sorted(JOB_ARTIFACT_STEMS))}); add "
                     "one rather than reporting its evidence as unknown")


def job_artifact_stem(job_name: str, workflow: str = "ci.yml") -> str | None:
    """The timing artifact stem this job's evidence lands in, if it has one.

    `None` means the job records no stage evidence (the orchestration gates), which is
    a different thing from a cache-bearing job whose state was not recorded.
    """
    lowered = job_name.lower()
    for token, stem in stems_for(workflow):
        if token in lowered:
            return stem
    return None


def _job_state_for(job_name: str, states: dict[str, str],
                   workflow: str = "ci.yml") -> str:
    """The recorded state for this job: a state, or `unknown` when it has none.

    `unknown` therefore covers both "the job has an artifact but it carries no state"
    and "the artifact was not downloaded"; callers that need to tell those apart use
    `job_artifact_stem`.
    """
    stem = job_artifact_stem(job_name, workflow)
    if stem is None:
        return "unknown"
    for directory, state in states.items():
        if stem in directory:
            return state
    return "unknown"


def _job_condition_for(job_name: str, conditions: dict[str, str],
                       workflow: str = "ci.yml") -> str:
    """The matched-condition signature of the artifact belonging to this job."""
    stem = job_artifact_stem(job_name, workflow)
    if stem is None:
        return ""
    for directory, signature in conditions.items():
        if stem in directory:
            return signature
    return ""


def _job_browser_for(job_name: str, usage: dict[str, bool],
                     workflow: str = "ci.yml") -> bool:
    """Whether this job's recorded stages drove a browser.

    A job whose artifact is missing reports False: absence of evidence is not evidence
    that the job opened a page, and claiming applicability would demand an axis it
    never had. The reverse error is caught by `report`, which treats a shape as
    browser-driving if ANY of its artifacts recorded the stage.
    """
    stem = job_artifact_stem(job_name, workflow)
    if stem is None:
        return False
    return any(driven for directory, driven in usage.items() if stem in directory)


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
    # Resolve the name the user gave to the workflow file, so both the run listing and
    # the job->artifact mapping agree on which workflow this is; an unsupported workflow
    # is refused here rather than reported as "no samples".
    workflow_file = resolve_workflow_file(args.repository, args.workflow)
    stems_for(workflow_file)
    samples = collect(args.repository, workflow_file, args.limit, args.cache_root,
                      args.branch)
    if not samples:
        raise SystemExit("measure_paired_samples.py: no completed runs found")
    # Quoted with shlex: a workflow name may contain spaces ("Build Linux candidate")
    # and a path may too, and an unquoted rendering would split into extra arguments and
    # fail when copied.
    command = " ".join(shlex.quote(part) for part in (
        "python3", "scripts/measure_paired_samples.py",
        "--repository", args.repository, "--workflow", args.workflow,
        "--branch", str(args.branch), "--limit", str(args.limit),
        "--cache-root", str(args.cache_root), "--out", str(args.out)))
    provenance = (f"Generated by `{command}`. Point-in-time capture: regenerate with that "
                  "command rather than editing this file.")
    result = report(samples, args.workflow, args.out, provenance)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
