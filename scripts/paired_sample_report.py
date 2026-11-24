"""Matched-condition evaluation and Markdown reporting for CI timing samples."""

from __future__ import annotations

import statistics
from pathlib import Path

# Named for a reader: the signature slot and the axis DONE-03 actually asks about.
BROWSER_FONT_AXES = (("browserVersion", "browser version"),
                     ("browserIdentity", "browser identity"),
                     ("fontSetDigest", "font set"))


def browser_attested_axes(condition: str) -> set[str]:
    """Axes attested by the browser-driving stages recorded inside one condition.

    The axis belongs to the stage that rendered, not to the job: `ci.yml`'s Linux
    acceptance artifact starts with a preflight stage that has no browser and only
    later runs `html-a11y` with one. Asking every stage tuple for a Chromium version
    would make the axis unreachable for exactly the job DONE-03 samples, so
    `job_conditions` records which axes the browser-kind stages attested and this reads
    that marker. A browser stage that reported nothing leaves its axes out, so a job
    with a real browser stage that stayed silent is still qualified rather than excused.
    """
    marker = "|browser="
    index = condition.rfind(marker)
    if index < 0:
        return set()
    reported = set(condition[index + len(marker):].split(","))
    return {name for field, name in BROWSER_FONT_AXES if field in reported}


def unrecorded_axes(conditions: set[str]) -> list[str]:
    """Axes DONE-03 names that NO condition in the report recorded a value for.

    Every sample page records these slots, and only the browser stages fill them. A
    sample whose job never runs such a stage records nothing here, which is why the
    caller decides applicability separately: for a browser-driving cell a blank slot
    means the axis was not compared, and a five-count then reads as closing DONE-03
    when it did not. The caller qualifies the verdict with the names returned here.

    The attestation comes from the stages that actually drive a browser (see
    `browser_attested_axes`). Requiring it of EVERY stage was wrong in the direction
    that matters: a multi-stage job's first tuple is a preflight stage that never has a
    browser, so no such job could ever attest the axis.
    """
    attested: set[str] = set()
    for condition in conditions:
        if not condition:
            continue
        attested |= browser_attested_axes(condition)
    return [name for (_field, name) in BROWSER_FONT_AXES if name not in attested]


def requirement_verdict(met: bool, unrecorded: list[str],
                        browser_applicable: bool = True) -> str:
    """The verdict text, never claiming more than the recorded axes support.

    `browser_applicable` is False for a job shape whose stages never drive a browser.
    DONE-03's browser/font condition describes a rendering sample, so a job that builds
    and tests without opening a page has no such condition to match: the axis is not
    applicable to it rather than missing from it, and saying "not recorded" would
    describe a gap that does not exist. The wording still names the axis, so a reader
    can tell "matched on every axis" from "axis not applicable" -- the two are not the
    same claim and must not print identically.
    """
    if not met:
        return "NOT met"
    if not browser_applicable:
        return ("met -- browser/font axis not applicable (no stage of this job drives a "
                "browser)")
    if not unrecorded:
        return "met"
    return ("met on the recorded axes only -- " + ", ".join(unrecorded)
            + " not recorded, so this is not yet a full DONE-03 match")


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
    # `collect` may attach the acquisition failures; they are not samples.
    acquisition_failures = [s["_acquisitionFailures"] for s in samples
                            if "_acquisitionFailures" in s]
    samples = [s for s in samples if "_acquisitionFailures" not in s]
    successful = [s for s in samples if s["conclusion"] == "success"]
    other = [s for s in samples if s["conclusion"] != "success"]
    # Only classified states form cells and requirements. A job with no timing
    # artifact (`Classify changes`, `CI required`) can never be hit or miss, and
    # demanding five of each for it would keep DONE-03 unmet forever.
    classified = [s for s in successful if s["state"] in CLASSIFIED_STATES]
    # Keyed by (shape, state, CONDITION): a cell is only a paired sample when the two
    # conditions being compared ran under the same toolchain, runner image and flags.
    cells: dict[tuple[str, str, str], list[float]] = {}
    for sample in classified:
        cells.setdefault((sample["shape"], sample["state"], sample.get("condition", "")),
                         []).append(sample["jobMinutes"])
    lines = [f"# Paired samples: {workflow}", ""]
    if provenance:
        # Emitted by the reporter so the checked-in file is genuinely its output and the
        # regeneration command it shows is the one that produced it (the `--out` is
        # included, since a command without it writes nothing).
        lines += [provenance, ""]
    seen = _append_attempt_tables(lines, samples)
    _append_matched_cells(lines, cells, classified)
    seen_unrecorded = _append_requirements(lines, samples, cells)
    _append_excluded_samples(lines, successful, other, acquisition_failures, samples)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    paired = {}
    for shape, _state, condition in cells:
        key = f"{shape}|{condition}"
        paired[key] = min(len(cells.get((shape, "miss", condition), [])),
                          len(cells.get((shape, "hit", condition), [])))
    return {"cells": {f"{shape}/{state}|{condition}": len(values)
                      for (shape, state, condition), values in cells.items()},
            "pairedPerCondition": paired,
            "unrecordedAxes": [name for _field, name in BROWSER_FONT_AXES
                               if name in seen_unrecorded],
            "failures": len(other), "report": str(out), "samples": len(samples),
            "runs": {f"{run_id}/{attempt}": {"wallMinutes": value[0],
                                             "runnerMinutes": value[1]}
                     for (run_id, attempt), value in sorted(seen.items())}}


def _append_attempt_tables(lines: list[str], samples: list[dict]) -> dict[tuple[int, int], tuple[float, float]]:
    lines += ["One row per JOB. The toolchain cache key includes the platform, so a single run",
             "legitimately records `hit` on one runner and `miss` on another. Cells are keyed",
             "by **(job shape, cache state)**: DONE-03 asks for samples under MATCHED",
             "conditions, so a Linux hit is never pooled with a macOS miss.",
             "",
             "A job whose artifact carries no cache state is `unknown` and is never assumed to",
             "be either condition. Failed and cancelled jobs are listed separately below and",
             "are excluded from the cells, not from the record.",
             "",
             "| run | attempt | revision | event | job | shape | environment | conclusion "
             "| cache | job wall | run wall | run runner |",
             "| --- | ---: | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: |"]
    for sample in samples:
        # A sample dict assembled by an older caller may predate the condition field;
        # the run table shows the environment, so default it rather than crash.
        sample.setdefault("condition", "")
        # The condition is itself a pipe-delimited signature, so it must not be
        # inserted raw into a Markdown row: every `|` would start a new cell and
        # shift the conclusion and timings into the wrong columns. Escape the pipes
        # (and backslashes) so the row keeps its column count.
        display_condition = (sample["condition"]
                             .replace("\\", "\\\\")
                             .replace("|", "\\|"))
        sample.setdefault("displayCondition", display_condition)
    for sample in sorted(samples, key=lambda s: (s["run"], s["job"])):
        # The environment is a column, not only a cell key: a cell may pool several
        # revisions, so without it the report cannot say which commit ran under which
        # environment and the revision-keyed view could not be reconstructed.
        lines.append("| {run} | {attempt} | `{revision}` | {event} | {job} | {shape} | "
                     "{displayCondition} | {conclusion} | {state} | {jobMinutes:.1f}m | "
                     "{runWallMinutes:.1f}m | {runRunnerMinutes:.1f}m |".format(**sample))
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
    return seen


def _append_matched_cells(lines: list[str], cells: dict[tuple[str, str, str], list[float]],
                          classified: list[dict]) -> None:
    lines += ["", "## Matched cells (successful jobs only)", "",
              "Each cell is one (job shape, cache state, matched environment) triple. The",
              "condition signature is the runner image, SDK version, stdx digest, toolchain",
              "fingerprint, toolchain target and compile options observed across the job's",
              "stages (a divergent later stage gives the artifact a signature of its own,",
              "and the axes its browser stages attested are part of that signature). The",
              "source revision is",
              "NOT part of the key: DONE-03's before/after samples are different commits by",
              "definition. Every sample keeps its own revision AND its environment, both",
              "shown in the run table, so the revision-keyed view stays reconstructible.",
              "",
              "**Browser/font axis:** DONE-03 also names the browser/font set, and only a",
              "job that drives a browser has that condition to match. The Linux acceptance",
              "matrix and the Pages browser shards publish the Chromium version and a",
              "font-family digest, which `ci_stage` merges into the stage environment. The",
              "Pages reading job's `reading` stage launches a browser too, so it counts as",
              "browser-driving; it reports no identity and publishes no timing artifact, so",
              "it yields no cell today. A cell whose browser stage recorded the",
              "axis can earn a plain `met`; a cell that drives a browser but did not record",
              "it is printed as `met on the recorded axes only` and names the axis it could",
              "not compare. A cell whose job runs no browser stage is printed as",
              "`browser/font axis not applicable`, which is a deliberately different",
              "string: an unmeasured axis is never reported as one that matched.", ""]
    for key in sorted(cells):
        shape, state, condition = key
        # Inline code cannot contain a raw pipe in a table, and these bullets may be
        # rendered inside one; escape it for the same reason as the run table.
        safe_condition = condition.replace("|", "\\|") if condition else ""
        detail = f" `{safe_condition}`" if condition else " (condition not recorded)"
        # Revision is not part of the key, so name the commits a cell covers; without
        # this the cell could silently pool measurements from unrelated code.
        # The FULL SHA, never a prefix: an 8-hex prefix can collide, and truncating
        # here would silently merge two commits in the provenance this annotation
        # exists to make auditable.
        cell_revisions = sorted({s.get("revisionFull") or s["revision"]
                                 for s in classified
                                 if s["shape"] == shape and s["state"] == state
                                 and s.get("condition", "") == condition})
        if len(cell_revisions) > 1:
            detail += " revisions=" + ",".join(cell_revisions)
        lines.append(f"* **{shape} / {state}**{detail}: {describe(cells[key])}")


def _append_requirements(lines: list[str], samples: list[dict],
                         cells: dict[tuple[str, str, str], list[float]]) -> set[str]:
    # Requirement shapes come from every cache-bearing job, not only from the cells: a
    # platform whose artifacts expired or whose samples all predate the recording would
    # otherwise vanish from the report instead of showing as an unmet cell.
    # Drawn from ALL samples, not only the successful ones: a platform whose every
    # occurrence failed or was cancelled would otherwise drop out of the requirement
    # section, and the remaining cells could read as met while that platform has no
    # successful sample at all. Only successful jobs enter `cells`.
    requirement_shapes = {s["shape"] for s in samples if s.get("hasEvidence")}
    requirement_shapes |= {key[0] for key in cells}
    lines += ["", "## Requirement check", "",
              "5 successful samples per matched cell (job shape x condition), per DONE-03:", ""]
    # A requirement is (shape, condition), and BOTH conditions must be shown for each.
    # Iterating the observed (shape, state) pairs would print "5 hits under condition A"
    # and "5 misses under condition B" as two met rows while no single matched condition
    # had both -- which is exactly what DONE-03's paired comparison forbids.
    conditions_by_shape: dict[str, set[str]] = {}
    for (shape, _state, condition), _values in cells.items():
        conditions_by_shape.setdefault(shape, set()).add(condition)
    # EVERY cache-bearing sample contributes its environment, including failed and
    # cancelled ones: an environment that only ever failed must still appear as an
    # unmet requirement (with zero counts) instead of vanishing, or a platform whose
    # samples all failed would look requirement-free.
    for sample in samples:
        if sample.get("hasEvidence"):
            conditions_by_shape.setdefault(sample["shape"], set()).add(
                sample.get("condition", ""))
    # A cache-bearing shape with no successful sample at all still appears, so a
    # platform that only ever failed cannot vanish from the requirement section.
    for shape in requirement_shapes:
        conditions_by_shape.setdefault(shape, set())
    # DONE-03 names the browser/font set, and only a job that drives a browser has that
    # condition to match. Applicability is derived per job SHAPE from the stage kinds
    # the evidence records, never from a platform name: `ci.yml` installs Chromium only
    # for the Linux job, but a workflow edit that adds or removes the stage must move
    # the answer with it.
    #
    # A shape counts as browser-driving if ANY of its artifacts recorded a browser
    # stage. That direction is deliberate: an artifact that predates the stage would
    # otherwise make a genuinely browser-driving shape look inapplicable, and the report
    # would then excuse the axis on the strength of the OLDEST sample -- the same
    # failure the per-condition qualification exists to prevent.
    #
    # A sample that carries no `browserDriven` field counts as driving a browser, which
    # is the conservative reading: an omitted field must never be the thing that excuses
    # an axis, or a caller that forgets to populate it silently weakens the requirement.
    browser_shapes: set[str] = set()
    for sample in samples:
        if sample.get("browserDriven", True):
            browser_shapes.add(sample["shape"])
    # DONE-03 names the browser/font set. A producer now records it, but only the
    # stages that really launch a browser do, so a cell can be missing it for two
    # distinct reasons: its job has no browser stage (not applicable), or its job has
    # one that did not report (unrecorded). Only the second qualifies a verdict.
    #
    # Computed PER CONDITION, not from the union of every condition: old artifacts
    # without these slots keep appearing in the report, and a union would mark the axis
    # recorded because the NEW conditions supply it -- handing an old cell a bare "met"
    # it never earned.
    #
    # The returned list is the conservative one: an axis appears if ANY condition fails
    # to record it, so an empty `unrecordedAxes` means every cell in the report was
    # compared on every axis DONE-03 names. Order follows the declaration above so the
    # value reads the same way every run.
    #
    # Only browser-driving shapes contribute: a shape whose stages never open a page
    # cannot record the axis and is not asked to, so letting it into this union would
    # report the axis as missing forever and no cell could ever earn a plain "met".
    seen_unrecorded: set[str] = set()
    for shape, values in conditions_by_shape.items():
        if shape not in browser_shapes:
            continue
        for condition in values:
            seen_unrecorded.update(unrecorded_axes({condition}))
    for shape in sorted(conditions_by_shape):
        conditions = conditions_by_shape[shape]
        applicable = shape in browser_shapes
        if not conditions:
            for state in ("miss", "hit"):
                lines.append(f"* {shape} / **{state}**: 0 collected — NOT met "
                             "(no successful sample under any matched condition)")
            continue
        for condition in sorted(conditions):
            label = f"`{condition}`" if condition else "(condition not recorded)"
            condition_unrecorded = unrecorded_axes({condition})
            for state in ("miss", "hit"):
                count = len(cells.get((shape, state, condition), []))
                verdict = requirement_verdict(count >= 5, condition_unrecorded,
                                              applicable)
                lines.append(f"* {shape} / **{state}** {label}: {count} collected — "
                             f"{verdict}")
            paired = min(len(cells.get((shape, "miss", condition), [])),
                         len(cells.get((shape, "hit", condition), [])))
            paired_verdict = requirement_verdict(paired >= 5, condition_unrecorded,
                                                 applicable)
            lines.append(f"  * paired samples under this condition: {paired} — "
                         f"{paired_verdict}")
    return seen_unrecorded


def _append_excluded_samples(lines: list[str], successful: list[dict], other: list[dict],
                             acquisition_failures: list[list[dict]], samples: list[dict]) -> None:
    unclassified = [s for s in successful if s["state"] not in CLASSIFIED_STATES]
    if unclassified:
        never = sorted({s["shape"] for s in unclassified if not s.get("hasEvidence")})
        # NOT `unrecorded`: that name holds the missing DONE-03 axes above and is
        # returned to the caller, so reusing it here silently replaced the axis list
        # with a list of job shapes whenever a job had no cache state.
        #
        # `mixed` is separated from `unknown` because they mean different things and
        # only one of them is the artifact's fault. A job that restores several timed
        # caches (a Pages browser shard restores fonts AND the Playwright browser
        # build) really did run with one hit and one miss; calling that "carry no
        # cache state" would describe a recorded condition as an unrecorded one.
        unrecorded_state = sorted({s["shape"] for s in unclassified
                                   if s.get("hasEvidence") and s["state"] == "unknown"})
        # Gated on `hasEvidence` exactly like `unknown_count`, or a shape whose samples
        # all lacked stage evidence would print "0 job(s) (<shape>) restored caches in
        # different states" -- a count and a name that contradict each other.
        mixed_state = sorted({s["shape"] for s in unclassified
                              if s.get("hasEvidence") and s["state"] == "mixed"})
        # Counted by predicate, not by subtraction. A job with no stage evidence at all
        # is `unknown` too, and the sentences below name it separately ("record no stage
        # evidence at all"), so "the rest" must not include it or the paragraph would
        # claim a job is both evidence-less and merely unrecorded.
        unknown_count = sum(1 for s in unclassified
                            if s.get("hasEvidence") and s["state"] == "unknown")
        mixed_count = sum(1 for s in unclassified
                          if s.get("hasEvidence") and s["state"] == "mixed")
        if not mixed_state:
            # No job recorded a split condition, so keep the exact sentence the
            # checked-in capture `docs/maintainer/paired-samples-main.md` was generated with: that
            # file is reporter output, and rewording it here would make the committed
            # capture unreproducible from the code that claims to have produced it.
            parts = [f"{len(unclassified)} successful job(s) carry no cache state and "
                     "are excluded from the cells."]
            if never:
                parts.append(f"Of those, {', '.join(never)} record no stage evidence at "
                             "all, so they can never be either condition and are not "
                             "requirements.")
            if unrecorded_state:
                parts.append(f"The rest ({', '.join(unrecorded_state)}) are cache-bearing "
                             "jobs whose state was not recorded -- from runs predating the "
                             "recording, or from artifacts that expired -- so they remain "
                             "requirements showing as 0 collected above rather than "
                             "disappearing.")
        else:
            # A job that restores more than one timed cache can legitimately record one
            # hit and one miss. Saying it "carries no cache state" would blame the
            # artifact for a condition it recorded correctly, and would hide the one
            # fact a reader needs: it is excluded from BOTH cells, so no amount of
            # waiting turns it into a sample.
            parts = [f"{len(unclassified)} successful job(s) are excluded from the "
                     "cells."]
            if never:
                parts.append(f"Of those, {', '.join(never)} record no stage evidence at "
                             "all, so they can never be either condition and are not "
                             "requirements.")
            if mixed_state:
                parts.append(f"{mixed_count} job(s) ({', '.join(mixed_state)}) restored "
                             "caches in different states -- typically one hit and one "
                             "miss -- so they are neither wholly warm nor wholly cold and "
                             "cannot be pooled with either.")
            if unrecorded_state:
                parts.append(f"The remaining {unknown_count} ({', '.join(unrecorded_state)}) "
                             "are cache-bearing jobs whose state was not recorded -- from "
                             "runs predating the recording, or from artifacts that expired "
                             "-- so they remain requirements showing as 0 collected above "
                             "rather than disappearing.")
        lines += ["", " ".join(parts)]
    if acquisition_failures:
        flat = [item for group in acquisition_failures for item in group]
        lines += ["", "## Evidence that could not be collected", "",
                  f"{len(flat)} run attempt(s) yielded no stage evidence, so their jobs are",
                  "absent from the cells above and the requirement counts are a lower bound:",
                  ""]
        for item in flat:
            names = ", ".join(f"`{name}`" for name in item["artifacts"])
            lines.append(f"* run `{item['run']}` attempt {item['attempt']}: could not "
                         f"collect {names}")
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
