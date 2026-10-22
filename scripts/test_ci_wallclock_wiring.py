"""Criterion 2 of issue #96: every measured workflow attaches its own wall clock.

The wall clock must describe the run that produced it. Recomputing it later from
the API reads a different state (re-runs, retained artifacts expiring, jobs still
in flight), so each of the three measured workflows classifies its own run and
uploads the document as a run artifact.

Two properties matter and both are asserted here rather than left to review:

* the classifier runs inside the workflow it measures, and
* it is never part of a gate. `ci_required.PLANNED_JOBS` exists precisely so an
  evidence collector cannot fail the required check, and `publish` must not need
  the release clock, because a failing collector must not be able to block or
  unblock a publication.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest

import ci_required

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MEASURED = ("ci.yml", "pages.yml", "release.yml")
# The last job on the chain each document publishes: `required` is the terminal
# gate in CI, `deploy` publishes the showcase and `publish` the release.
PUBLISHERS = {"ci.yml": "required", "pages.yml": "deploy",
              "release.yml": "publish"}


def function_block(text: str, name: str) -> str:
    """The body of the job-level `name:` entry, up to the next job.

    Jobs sit at two spaces of indentation, so the next job is the next line that
    starts with exactly two spaces and a non-space character. Splitting on `"\\n  "`
    would cut at the first four-space body line instead.
    """
    marker = f"\n  {name}:\n"
    if marker not in text:
        raise AssertionError(f"workflow has no `{name}` job")
    body = text.split(marker, 1)[1]
    ends = [match.start() for match in re.finditer(r"\n {2}\S", body)]
    return body[:min(ends)] if ends else body


def _needs_names(fragment: str) -> set[str]:
    """The job names in one fragment of a `needs:` list, brackets stripped."""
    text = re.sub(r"#.*", "", fragment).strip()
    names: set[str] = set()
    for piece in text.strip("[]").split(","):
        name = piece.strip().strip("'\"")
        if not name:
            continue
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise AssertionError(f"unparsed `needs:` entry: {piece!r}")
        names.add(name)
    return names


def job_graph(text: str) -> dict[str, set[str]]:
    """Every job under `jobs:` mapped to the jobs its `needs:` names.

    Parsed from the workflow text rather than from a literal list so a job added
    later is covered by the dependency assertions without anyone remembering to
    extend them.

    Every valid YAML spelling is read, and anything unrecognised raises instead of
    yielding an empty set. That matters because an empty set silently satisfies
    every assertion below: a `needs:` the parser cannot see would let a workflow
    with a dependency cycle -- which GitHub refuses to load, so the required check
    never reports -- pass this module. Comments inside the list, deeper
    indentation, trailing comments and both block and flow sequences are handled
    because they are ordinary edits in a file that already comments its `needs:`.
    """
    body = text.split("\njobs:\n", 1)[1]
    graph: dict[str, set[str]] = {}
    current: str | None = None
    # "block" while reading `- name` lines, "flow" while a `[...]` is still open.
    collecting: str | None = None

    def finish(line: str) -> None:
        nonlocal collecting
        if collecting == "flow":
            raise AssertionError(
                f"`needs:` flow sequence is not closed before {line!r} "
                f"(parsed {sorted(graph.get(current or '', ()))})")
        collecting = None

    for line in body.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.fullmatch(r"  [A-Za-z0-9_-]+:", line):
            finish(line)
            current = line.strip().rstrip(":")
            graph[current] = set()
            continue
        if current is None:
            continue
        needs = re.fullmatch(r"    needs:(.*)", line)
        if needs:
            finish(line)
            value = needs.group(1).strip()
            # Union rather than replace: YAML rejects a duplicate key, so a second
            # `needs:` in one job is already a broken workflow. Keeping both lists
            # means the assertions see every edge the file declares instead of the
            # last one winning and hiding the rest.
            if not value:
                collecting = "block"
                continue
            graph[current] |= _needs_names(value)
            collecting = "flow" if "[" in value and "]" not in value else None
            continue
        if collecting == "block":
            item = re.fullmatch(r"\s*-\s*(.+?)\s*(?:#.*)?", line)
            if not item:
                raise AssertionError(f"unparsed `needs:` block entry: {line!r}")
            graph[current] |= _needs_names(item.group(1))
            continue
        if collecting == "flow":
            graph[current] |= _needs_names(line)
            if "]" in line:
                collecting = None
            continue
        if re.match(r" {4}\S", line):
            # Another job-level key. A list left open here is a spelling this parser
            # does not understand, and `finish` turns that into a failure.
            finish(line)
    finish("")
    return graph


def reached(graph: dict[str, set[str]], start: str) -> set[str]:
    """Every job `start` waits for, directly or through another dependency."""
    seen: set[str] = set()
    frontier = list(graph.get(start, ()))
    while frontier:
        name = frontier.pop()
        if name in seen:
            continue
        seen.add(name)
        frontier.extend(graph.get(name, ()))
    return seen


class WallClockWiringTest(unittest.TestCase):
    def workflow(self, name: str) -> str:
        return (PROJECT_ROOT / ".github/workflows" / name).read_text(encoding="utf-8")

    def test_every_measured_workflow_uploads_its_own_wall_clock(self) -> None:
        for name in MEASURED:
            with self.subTest(workflow=name):
                text = self.workflow(name)
                block = function_block(text, "wallclock")
                self.assertIn("scripts/ci_stage.py wallclock", block)
                self.assertIn("--output target/ci-evidence/wallclock.json", block)
                # The artifact name is per-workflow and per-run, so three
                # workflows never overwrite one another's classification.
                self.assertIn("name: ci-wallclock-", block)
                self.assertIn("${{ github.run_id }}-${{ github.run_attempt }}", block)
                # The job-level guard, not the upload step's: the step carries its
                # own `if: always()`, so a search anywhere in the block is
                # satisfied after the job guard is deleted -- and the collector
                # then skips exactly on the failed runs it exists to record.
                header: list[str] = []
                for line in block.splitlines():
                    if line == "    steps:":
                        break
                    if re.fullmatch(r" {4}\S.*", line):
                        header.append(line.strip())
                self.assertIn("if: always()", header,
                              f"{name}: `wallclock` needs a job-level `if: always()`")
                self.assertIn("actions: read", block)
                # `always()` with no dependency would start at run begin and
                # classify a run that has not run yet.
                self.assertIn("needs:", block)

    def test_no_job_depends_on_itself(self) -> None:
        """A self-edge makes the workflow unloadable, so no job would ever report.

        The clock's `needs` list is nearly identical to the gate's, and an edit
        aimed at one lands on the other by line. A `needs` cycle is not a
        self-reference that resolves: GitHub rejects the workflow, so the single
        required check never runs at all -- worse than a failing run, because
        branch protection has no conclusion to gate on.
        """
        for name in MEASURED:
            with self.subTest(workflow=name):
                graph = job_graph(self.workflow(name))
                for job, needs in graph.items():
                    self.assertNotIn(job, needs, f"{name}: `{job}` needs itself")

    def test_the_dependency_graph_is_acyclic(self) -> None:
        """Any cycle, not only a self-edge, stops the workflow from loading."""
        for name in MEASURED:
            with self.subTest(workflow=name):
                graph = job_graph(self.workflow(name))
                state: dict[str, str] = {}

                def visit(job: str, path: tuple[str, ...]) -> None:
                    if state.get(job) == "done":
                        return
                    self.assertNotEqual(state.get(job), "open",
                                        f"{name}: dependency cycle {' -> '.join(path + (job,))}")
                    state[job] = "open"
                    for need in sorted(graph.get(job, ())):
                        if need in graph:
                            visit(need, path + (job,))
                    state[job] = "done"

                for job in graph:
                    visit(job, ())

    def test_the_wall_clock_never_gates_a_required_or_publishing_job(self) -> None:
        """An evidence collector failing must not fail CI or change publication."""
        self.assertNotIn("wallclock", ci_required.PLANNED_JOBS)
        for name in MEASURED:
            with self.subTest(workflow=name):
                text = self.workflow(name)
                graph = job_graph(text)
                # Only the gate and publisher names the workflow actually has: a
                # missing name would otherwise skip the assertion silently, which is
                # exactly how a `deploy` that started needing the clock would pass.
                for job in ("required", "publish", "deploy", "verify-site"):
                    if job not in graph:
                        continue
                    self.assertNotIn("wallclock", graph[job],
                                     f"{name}:{job} must not depend on the collector")

    def test_every_clock_waits_for_every_job_on_the_chain_it_reports(self) -> None:
        """A clock must not read a job that is still running.

        The Jobs API reports a running job's `completed_at` as null, which
        classifies as 0 ms and drops it from `nonOverlappingChain.chain`, so the clock
        has to start after the last job it measures. The invariant is transitive
        rather than a literal list: every job other than the clock itself must be
        reachable from the clock's `needs`, whether directly or through another
        dependency. Pinning one name would miss a dropped edge to any job the
        clock still waits for indirectly, and asserting a full literal list would
        fail on a correct graph that reaches a job through an intermediate.
        """
        for name in MEASURED:
            with self.subTest(workflow=name):
                graph = job_graph(self.workflow(name))
                publisher = PUBLISHERS[name]
                waiting = graph["wallclock"]
                # The measured chain is what the terminal publisher depends on:
                # deriving it from the publisher rather than from the full job list
                # keeps an unrelated job (a notifier, a lint) out of the invariant
                # instead of demanding a dependency on it.
                chain = reached(graph, publisher) | {publisher}
                missing = sorted(chain - reached(graph, "wallclock"))
                self.assertEqual(missing, [],
                                 f"{name}: the clock could read still-running "
                                 f"jobs {missing}")
                self.assertEqual(waiting & {"wallclock"}, set(),
                                 f"{name}: the clock must not depend on itself")

    def test_the_release_clock_waits_for_the_work_it_measures(self) -> None:
        """Every release job, the publisher included, must have finished first.

        Without `publish` in `needs`, the clock starts at the same instant as the
        publisher, reads it as `in_progress`, and attributes 0 ms to it -- so the
        artifact could never reproduce the chain the document publishes. Waiting
        is still not gating: nothing depends on this job.
        """
        block = function_block(self.workflow("release.yml"), "wallclock")
        self.assertIn("guard", block)
        self.assertIn("release-candidate", block)
        self.assertIn("publish", block.split("needs:", 1)[1].split("\n", 1)[0])


if __name__ == "__main__":
    unittest.main()
