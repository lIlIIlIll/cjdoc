"""Wall-clock classification from already-fetched Actions API payloads.

This module is the calculation only: no `gh` subprocess, no stage records, no
retained log streams. A change to how an attempt is classified -- which records
are carried, which clock is the wall -- touches nothing else, and the transport
(`ci_stage.wallclock`) can be replaced without re-reading this file.
"""

from __future__ import annotations

import datetime as dt

WALLCLOCK_SCHEMA = "cjdoc.ci-wallclock/2"


def _milliseconds(start: str | None, end: str | None) -> int:
    if not start or not end:
        return 0
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return max(0, round((parse(end) - parse(start)).total_seconds() * 1000))


def non_overlapping_chain(intervals: list[tuple[str, int, int]]) -> dict[str, object]:
    """The longest chain of jobs that did not overlap in time.

    Derived only from observed start/end times, because the Jobs API reports no
    dependency graph. A job extends the chain when it started no earlier than the
    previous one ended.

    This is NOT the dependency critical path, and the field names say `chain`
    rather than `criticalPath` for that reason. Two independent jobs -- `pages.yml`'s
    source reproduction and its browser shards are siblings that each need only
    `assemble-site` -- can be serialized by runner availability, and a chain built
    from timestamps alone would then join them and exceed the real dependency path.
    The number is what actually happened, which is the question this document asks,
    but it is not an attribution of the wall clock to a `needs` edge.

    `equalsLongestJob` reports the flat case, so a reader cannot mistake "the
    longest job" for a measured chain.

    `intervals` is `(name, startMs, endMs)` with times relative to one origin.
    """
    ordered = sorted((start, end, name) for name, start, end in intervals)
    best: list[int] = []
    previous: list[int] = []
    for index, (start, end, _name) in enumerate(ordered):
        wall = max(0, end - start)
        best_index, best_total = -1, 0
        for earlier in range(index):
            if ordered[earlier][1] <= start and best[earlier] > best_total:
                best_index, best_total = earlier, best[earlier]
        best.append(best_total + wall)
        previous.append(best_index)
    if not best:
        # Every field is present here too: a consumer that reads `longestJobMs`
        # must not need a special case for a run with no timings.
        return {"chain": [], "wallMs": 0, "equalsLongestJob": True, "longestJob": "",
                "longestJobMs": 0}
    # One index decides both the chain and its wall: computing the maximum twice
    # lets a later, shorter chain overwrite the number while `chain` keeps naming
    # the longer one, so the document would contradict itself.
    peak = max(range(len(best)), key=lambda index: best[index])
    link = peak
    chain: list[str] = []
    while link != -1:
        chain.append(ordered[link][2])
        link = previous[link]
    chain.reverse()
    longest = max(ordered, key=lambda item: item[1] - item[0])
    return {
        "chain": chain,
        "wallMs": best[peak],
        # True means the run was flat: no chain is longer than its single longest
        # job, so attributing the wall clock to a sequence would be invented.
        "equalsLongestJob": len(chain) == 1,
        "longestJob": longest[2],
        "longestJobMs": max(0, longest[1] - longest[0]),
    }


def _attempt_jobs(jobs_payload: dict[str, object], attempt: int) -> list[dict]:
    """The job records the listing holds for the attempt being described."""
    jobs = jobs_payload.get("jobs", []) if isinstance(jobs_payload, dict) else []
    return [job for job in jobs if job.get("run_attempt") == attempt]


def _carried_jobs(jobs: list[dict], attempt: int, latest_attempt: int,
                  run_origin: str | None) -> set[int]:
    """Ids of records a re-run copied from an earlier attempt with old timestamps.

    Those jobs did not run in this attempt, so they get the same 0 ms a skipped
    job gets -- anywhere else their durations would be counted twice across
    attempts and would contradict the chain, which drops them.

    The test is a completed record that ended before the run origin. A job that has
    not completed is still running in this attempt, and classifying mid-run must
    keep the steps it has recorded so far; scoping to the latest attempt keeps an
    older attempt's own records intact, since only that attempt's jobs can be
    mistaken for carried ones.
    """
    return {
        id(job) for job in jobs
        if attempt == latest_attempt and run_origin
        and job.get("completed_at") and job["completed_at"] < run_origin
    }


def _job_clocks(jobs: list[dict], carried: set[int]) -> tuple[dict[str, int], dict[str, dict[str, int]]]:
    """Per-job wall and, for jobs that report steps, per-step wall."""
    job_wall: dict[str, int] = {}
    step_wall: dict[str, dict[str, int]] = {}
    for job in jobs:
        name = job.get("name", "")
        if id(job) in carried:
            job_wall[name] = 0
            continue
        job_wall[name] = _milliseconds(job.get("started_at"), job.get("completed_at"))
        if job.get("steps"):
            step_wall[name] = {step.get("name", ""): _milliseconds(step.get("started_at"), step.get("completed_at"))
                               for step in job["steps"] if step.get("completed_at")}
    return job_wall, step_wall


def _attempt_anchor(attempt: int, latest_attempt: int, run_origin: str | None,
                    started: list[str]) -> str | None:
    """The origin the attempt's intervals are measured from.

    The origin depends on which attempt is being described, because the two
    cases have opposite failure modes:

    * latest attempt -- `run_started_at` is its own origin, and a re-run carries
      the previous attempt's unchanged job records with their original
      timestamps. Anchoring on the earliest job start would then measure from
      before this attempt existed: a span longer than the run's own wall and a
      chain outlasting the run. Anchored on the run origin those carried records
      clamp to zero length and drop out, which is the truth: this attempt did not
      run them.
    * older attempt -- the reverse. `run_started_at` belongs to the latest
      attempt, so every job of this one lands before the origin and clamps to
      (0, 0): a non-zero wall beside a zero span and a chain that lost every job.
      The attempt's own jobs are the only available origin.
    """
    if attempt >= latest_attempt and run_origin:
        return run_origin
    return min(started) if started else None


def _intervals(jobs: list[dict], anchor: str | None,
               carried: set[int]) -> list[tuple[str, int, int]]:
    """`(name, startMs, endMs)` per completed job, relative to the anchor.

    Carried records are excluded here too, not merely clamped: against the anchor
    they would clamp to a start of 0, which becomes the minimum, so the span would
    run from the attempt origin instead of from the first job that actually ran.
    `wall - job span` is documented as the pre-start gap plus the post-completion
    tail, so a phantom 0 start would report no queueing at all.
    """
    return [
        (job.get("name", ""), _milliseconds(anchor, job.get("started_at")),
         _milliseconds(anchor, job.get("completed_at")))
        for job in jobs
        if job.get("started_at") and job.get("completed_at") and id(job) not in carried
    ]


def _wall_clock(run: dict[str, object], attempt: int, latest_attempt: int,
                run_origin: str | None,
                intervals: list[tuple[str, int, int]]) -> tuple[int, str]:
    """The wall a user waits for, and the name of the clock it was read from.

    The three clocks `docs/maintainer/ci-wallclock.md` tabulates, computed here rather than in
    the table's author: a number a reader cannot reproduce from the artifact is not
    evidence. `wall` is what a user waits for; the job span excludes the
    controller's own pre-start queueing; job-minutes do not hide parallel work.

    `updated_at` is also a run-level timestamp, so for an older attempt it ends
    the latest attempt rather than this one. There the number is not a wall at
    all, and `wallSource` says so instead of publishing an overstatement.

    A run that has not finished has no wall yet. The collector job runs inside the
    run it measures, so it always sees itself `in_progress` and `updated_at` is
    whatever the API happened to have flushed -- the number moves between two reads
    of the same run and stops before the collector's own upload. Publishing it as
    `wall` would claim a completion time the run does not have. `wallSource` names
    the clock that was actually read so a reader is never handed the wrong one.
    """
    if run.get("status") != "completed":
        # Measured through the last job that has finished -- on a run whose publisher
        # is skipped (every `pull_request` Pages run) that is the last verification
        # job, not a publisher, so the name says `terminal-job` and claims no more.
        # The collector cannot see its own end, so this is a lower bound.
        return max((end for _name, _start, end in intervals), default=0), "terminal-job"
    if attempt == latest_attempt:
        return _milliseconds(run_origin, run.get("updated_at")), "run"
    # An older attempt, or one the run never had: either way the run-level wall
    # is not this attempt's, and publishing it beside an empty job list would
    # read as a measured run that simply had no jobs.
    return 0, "attempt-jobs"


def _queued_milliseconds(run: dict[str, object], attempt: int, run_origin: str | None,
                         started: list[str]) -> int:
    """The wait before this attempt's first job starts.

    Both ends must belong to this attempt. `created_at` is when the RUN was
    created, which for a re-run is the first attempt's creation: measured from
    there, a re-run reports the interval spanning the previous attempt as its own
    queue delay. A re-run's own start is `run_started_at`, so that is the origin
    it gets.
    """
    queue_origin = run.get("created_at") if attempt <= 1 else run_origin
    in_attempt = [start for start in started if start >= (queue_origin or start)]
    return _milliseconds(queue_origin, min(in_attempt)) if in_attempt else 0


def _job_span(intervals: list[tuple[str, int, int]]) -> int:
    """First start to last end: what the attempt's jobs occupied on the clock."""
    return (max(end for _name, _start, end in intervals)
            - min(start for _name, start, _end in intervals)) if intervals else 0


def classify_wallclock(run: dict[str, object], jobs_payload: dict[str, object],
                       attempt: int) -> dict[str, object]:
    """Build the wall-clock document from already-fetched API payloads."""
    jobs = _attempt_jobs(jobs_payload, attempt)
    started = [job["started_at"] for job in jobs if job.get("started_at")]
    latest_attempt = int(run.get("run_attempt", attempt))
    run_origin = run.get("run_started_at") or run.get("created_at")
    carried = _carried_jobs(jobs, attempt, latest_attempt, run_origin)
    job_wall, step_wall = _job_clocks(jobs, carried)
    partial = latest_attempt > 1 or any(
        int(job.get("run_attempt", attempt)) > 1 for job in jobs)
    rerun_gaps = [
        {"job": job.get("name", ""), "runAttempt": job.get("run_attempt"),
         "gapMs": _milliseconds(run.get("run_started_at"), job.get("started_at"))}
        for job in jobs if int(job.get("run_attempt", attempt)) > 1
    ]
    anchor = _attempt_anchor(attempt, latest_attempt, run_origin, started)
    intervals = _intervals(jobs, anchor, carried)
    wall_ms, wall_source = _wall_clock(run, attempt, latest_attempt, run_origin, intervals)
    queued_ms = _queued_milliseconds(run, attempt, run_origin, started)
    job_span_ms = _job_span(intervals)
    if wall_source == "attempt-jobs":
        # Same span, reported as the wall: this attempt has no run-level wall to
        # read, and 0 next to a non-zero span would read as a measurement.
        wall_ms = job_span_ms
    return {
        "schemaVersion": WALLCLOCK_SCHEMA,
        "runId": str(run.get("id", "")),
        "attempt": attempt,
        "workflow": run.get("name", ""),
        "headSha": run.get("head_sha", ""),
        "queuedMs": queued_ms,
        "wallMs": wall_ms,
        "wallSource": wall_source,
        "jobSpanMs": job_span_ms,
        "jobMinutes": round(sum(job_wall.values()) / 60_000, 1),
        "jobWallMs": job_wall,
        "stepWallMs": step_wall,
        "nonOverlappingChain": non_overlapping_chain(intervals),
        "manualRerunGapMs": rerun_gaps,
        "partialRerun": partial,
    }
