#!/usr/bin/env python3
"""Decide which Linux candidate a Pages run consumes, and prove it is ready.

Pages used to poll `gh run list --workflow ci.yml --status success`, which only
becomes true after every platform of the cross-platform matrix has finished.
The Linux candidate itself is ready minutes earlier (issue #82, item CI-05.1), so
each CI run now publishes a *readiness marker* artifact as soon as its Linux
candidate succeeds. A marker is one JSON document whose name encodes the
producing run and attempt; its existence is the readiness claim and its payload
binds the candidate bytes.

Only a run whose Linux candidate genuinely passed and whose consumed branch is
still satisfied may publish a site. The binding therefore has two halves:

* `resolve-candidate` may adopt a marker, which makes site assembly start at
  candidate readiness instead of at whole-matrix success.
* `verify-site` (and therefore `deploy`) must still show a ready, finished,
  successful CI run for the same commit, so a later matrix failure still blocks
  publication. The fast path changes *when* Pages starts, never *what* it needs.

Everything here is read-only against the GitHub API. Selecting a candidate is
always explicit: a marker is accepted only when exactly one ready candidate
matches the commit, and an ambiguous or contradictory state falls back to a
local build rather than guessing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True

MARKER_PREFIX = "cjdoc-linux-candidate-ready"
MARKER_SCHEMA = "cjdoc.linux-candidate-ready/1"
CANDIDATE_WORKFLOW = "ci.yml"
CANDIDATE_WORKFLOW_NAME = "CI"
CANDIDATE_ARTIFACT_PREFIX = "cjdoc-linux-candidate"
DEFAULT_DEADLINE_SECONDS = 900
DEFAULT_POLL_SECONDS = 30
# The publication gate waits for the consumed attempt to become terminal; it is
# bounded so a genuinely stuck CI run still fails the deployment.
DEFAULT_GATE_SECONDS = 1800

# A single blip in a status read must not abort discovery or make the publication
# gate reject an otherwise valid deployment; retry briefly before giving up.
STATUS_READ_TRIES = 3
_SHA256 = frozenset("0123456789abcdef")


class ResolutionError(SystemExit):
    """A state we refuse to guess about; the caller must fall back or fail."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def marker_name(run_id: int | str, run_attempt: int | str) -> str:
    return f"{MARKER_PREFIX}-{run_id}-{run_attempt}"


def is_digest(value: object) -> bool:
    """A SHA-256 hex digest."""
    return isinstance(value, str) and len(value) == 64 and set(value) <= _SHA256


def is_object_id(value: object) -> bool:
    """A full commit or tree object id.

    Only the full form is accepted: an abbreviated sha could collide with another
    commit of the same prefix, and a marker must bind one exact revision.
    """
    return isinstance(value, str) and len(value) in {40, 64} and set(value) <= _SHA256


# ---------------------------------------------------------------- GitHub API

def _decode_stream(text: str) -> list[object]:
    """Decode `gh api --paginate` output, which may concatenate JSON documents."""
    decoder = json.JSONDecoder()
    values: list[object] = []
    index = 0
    while index < len(text):
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index >= len(text):
            break
        value, index = decoder.raw_decode(text, index)
        values.append(value)
    return values


def gh_api(path: str, *, paginate: bool = True, tries: int = 5) -> object:
    """Read one REST resource, retrying the transient failures `gh` reports.

    A truncated body is one of those transient failures: `gh api` can exit 0 with
    a cut-off page, so a JSON decode error must be retried exactly like a nonzero
    status. Treating it as fatal would abort candidate discovery (or the
    publication check) on the very flakiness the retry loop exists for.
    """
    args = ["gh", "api"] + (["--paginate"] if paginate else []) + [path]
    last = ""
    for attempt in range(tries):
        completed = subprocess.run(args, capture_output=True, text=True)
        if completed.returncode == 0:
            # An empty body is the most complete form of the transient EOF this loop
            # exists for: `gh api` exits 0 with nothing, which would otherwise look
            # like "no runs" or "no artifacts" and make discovery fall back or the
            # publication gate reject a valid deployment.
            if not completed.stdout.strip():
                last = "empty response body"
            else:
                try:
                    values = _decode_stream(completed.stdout)
                except ValueError as error:
                    last = f"malformed JSON response: {error}"
                else:
                    if not paginate:
                        return values[0] if values else {}
                    if not values:
                        return {}
                    if len(values) == 1:
                        return values[0]
                    merged: dict[str, object] = {}
                    for value in values:
                        if not isinstance(value, dict):
                            continue
                        for key, item in value.items():
                            if isinstance(item, list):
                                merged.setdefault(key, [])
                                assert isinstance(merged[key], list)
                                merged[key].extend(item)
                            else:
                                merged.setdefault(key, item)
                    return merged
        else:
            last = completed.stderr.strip()
        if attempt + 1 < tries:
            time.sleep(2 * (attempt + 1))
    raise ResolutionError(f"ci_candidate_source.py: gh api {path} failed: {last[:400]}")


def _items(payload: object, key: str) -> list[dict]:
    if isinstance(payload, dict):
        value = payload.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    return []


def candidate_runs(repository: str, commit: str) -> list[dict]:
    """Every CI run for the commit, newest first, with its own attempt count."""
    payload = gh_api(f"repos/{repository}/actions/workflows/{CANDIDATE_WORKFLOW}"
                     f"/runs?head_sha={commit}&per_page=100")
    runs = []
    for run in _items(payload, "workflow_runs"):
        if run.get("name") != CANDIDATE_WORKFLOW_NAME:
            continue
        runs.append({"id": run.get("id"), "attempt": int(run.get("run_attempt") or 1),
                     "status": run.get("status"), "conclusion": run.get("conclusion")})
    return runs


def live_markers(repository: str, run_id: int, run_attempt: int) -> list[dict]:
    """The live readiness-marker artifacts published by one run attempt.

    The artifact list is queried by exact name so a run that never published a
    marker costs one empty response instead of a full artifact listing.
    """
    payload = gh_api(f"repos/{repository}/actions/artifacts"
                     f"?name={marker_name(run_id, run_attempt)}")
    markers = []
    for artifact in _items(payload, "artifacts"):
        if artifact.get("expired"):
            continue
        owner = artifact.get("workflow_run") or {}
        if owner.get("id") != run_id:
            continue
        markers.append({"id": artifact.get("id"), "name": artifact.get("name"),
                        "size": artifact.get("size_in_bytes")})
    return markers


def attempt_status(repository: str, run_id: int, run_attempt: int) -> dict:
    """One attempt's own head/status/conclusion.

    The run-level API reports the *latest* attempt's conclusion, so a run that
    only succeeded on attempt 2 would otherwise make attempt 1 look successful.
    """
    args = ["gh", "run", "view", str(run_id), "--attempt", str(run_attempt),
            "--repo", repository,
            "--json", "headSha,status,conclusion,workflowName"]
    last = ""
    for attempt in range(STATUS_READ_TRIES):
        completed = subprocess.run(args, capture_output=True, text=True)
        if completed.returncode == 0 and completed.stdout.strip():
            try:
                return json.loads(completed.stdout)
            except ValueError as error:
                last = f"invalid JSON: {error}"
        elif completed.returncode == 0:
            # Same transient EOF as `gh_api`: an empty body must not be read as a
            # definitive "this attempt is unusable" answer.
            last = "empty response body"
        else:
            last = completed.stderr.strip()[:300]
        if attempt + 1 < STATUS_READ_TRIES:
            time.sleep(2 * (attempt + 1))
    raise ResolutionError(f"ci_candidate_source.py: cannot read run {run_id} "
                          f"attempt {run_attempt}: {last}")


# ------------------------------------------------------------------ resolve

def inspect_candidates(repository: str, commit: str, *, require_success: bool = False) -> dict:
    """Find every ready candidate for the commit.

    Readiness and success are deliberately different questions:

    * **Readiness** (adoption, `require_success=False`) is what the marker proves:
      the Linux candidate passed and its bytes are downloadable. The rest of the
      CI matrix may still be running — that is the whole point of CI-05.1, which
      exists so Pages need not wait for Windows and macOS.
    * **Success** (publication, `require_success=True`) additionally requires the
      run's own attempt to have finished successfully, so a later matrix failure
      still blocks deployment.

    Both require the marker, a live candidate artifact, and an attempt that
    belongs to this commit and to the `CI` workflow.
    """
    ready: list[dict] = []
    failed: list[dict] = []
    unmarked = 0
    pending = False
    for run in candidate_runs(repository, commit):
        run_id = run["id"]
        if not isinstance(run_id, int):
            continue
        markers = live_markers(repository, run_id, run["attempt"])
        if not markers:
            if run["status"] != "completed":
                pending = True
            elif run["conclusion"] not in {"success"}:
                failed.append({"id": run_id, "attempt": run["attempt"],
                               "reason": f"CI reported {run['conclusion']}"})
            else:
                # Successful but silent: either a revision that predates markers or
                # a job that never reached the marker step. Distinguish it from "no
                # run at all" so the fallback reason is truthful.
                unmarked += 1
            continue
        for marker in markers:
            try:
                status = attempt_status(repository, run_id, run["attempt"])
            except ResolutionError as error:
                # A transient CLI/API failure while reading a candidate must not
                # abort resolution: the contract is to fall back to a local build,
                # and a later poll may still read it. The publication gate stays
                # fail-closed because `require_ready` calls this same code and
                # raises when nothing is ready.
                failed.append({"id": run_id, "attempt": run["attempt"],
                               "reason": f"unreadable attempt: {error}"})
                continue
            problems = attempt_problems(status, commit, require_success=require_success)
            if problems:
                # An adoption-time rejection because the attempt is still running is
                # "not ready yet", not "failed": during the early-start window the
                # marker exists precisely while the matrix is unfinished, so it must
                # keep the caller waiting instead of ending the wait with a fallback.
                if not require_success and _still_running(status):
                    pending = True
                else:
                    failed.append({"id": run_id, "attempt": run["attempt"],
                                   "reason": problems[0]})
                continue
            artifact = f"{CANDIDATE_ARTIFACT_PREFIX}-{run_id}-{run['attempt']}"
            if not live_candidate_artifact(repository, artifact, run_id):
                failed.append({"id": run_id, "attempt": run["attempt"],
                               "reason": "missing candidate artifact"})
                continue
            ready.append({"runId": run_id, "runAttempt": run["attempt"],
                          "artifactName": artifact, "markerName": marker["name"],
                          "runConclusion": status.get("conclusion")})
    ready.sort(key=lambda item: (item["runId"], item["runAttempt"]))
    return {"ready": ready, "failed": failed, "pending": pending, "unmarked": unmarked}


def live_candidate_artifact(repository: str, name: str, run_id: int) -> bool:
    """Whether the given run still owns a live artifact with this exact name.

    The artifact list is queried by name repository-wide, so another run that
    happens to have an unexpired artifact of the same encoded name must not count:
    the Pages download is restricted to the selected run, and committing to reuse
    on a foreign artifact would fail the reuse job with no local fallback left.
    """
    payload = gh_api(f"repos/{repository}/actions/artifacts?name={name}")
    for artifact in _items(payload, "artifacts"):
        if artifact.get("expired"):
            continue
        owner = artifact.get("workflow_run") or {}
        if owner.get("id") == run_id:
            return True
    return False


def resolve(repository: str, commit: str, event: str, explicit_run_id: str,
            explicit_run_attempt: str, deadline_seconds: int, poll_seconds: int,
            log=print) -> dict:
    """Choose the candidate source. Never guesses when the state is ambiguous."""
    if event == "pull_request":
        return {"reuse": False, "reason": "pull requests never reuse a cross-run artifact",
                "candidateSource": "local-build"}
    if event == "workflow_dispatch" and not explicit_run_id:
        return {"reuse": False, "reason": "workflow_dispatch without candidate_run_id builds locally",
                "candidateSource": "local-build"}
    if explicit_run_id:
        try:
            attempt = int(explicit_run_attempt or 1)
        except ValueError:
            return {"reuse": False, "candidateSource": "local-build",
                    "reason": f"candidate_run_attempt is not numeric: {explicit_run_attempt!r}"}
        return _explicit_candidate(repository, commit, explicit_run_id, attempt)
    deadline = time.time() + max(0, deadline_seconds)
    while True:
        state = inspect_candidates(repository, commit)
        choices = state["ready"]
        if len(choices) == 1:
            chosen = choices[0]
            log(f"candidateSource=ci-artifact run={chosen['runId']} "
                f"attempt={chosen['runAttempt']} artifact={chosen['artifactName']}")
            return {"reuse": True, "candidateSource": "ci-artifact", **chosen}
        if len(choices) > 1:
            return {"reuse": False, "candidateSource": "local-build",
                    "reason": f"expected exactly one ready CI candidate, found {len(choices)}"}
        # "No run registered yet" is not proof that CI will not run: Pages and CI are
        # started independently by the same push, so the first query can legitimately
        # see nothing. Only a terminal, conclusive state may end the wait early;
        # otherwise honour the deadline so scheduling order cannot duplicate the
        # Linux build. A run that already concluded without success is terminal, and
        # a successful-but-silent one predates the marker step, so both fall through.
        if not state["pending"] and (state["failed"] or state.get("unmarked")):
            if state.get("unmarked"):
                reason = (f"{state['unmarked']} successful CI run(s) published no readiness "
                          "marker (revision predates markers?)")
            elif state["failed"]:
                reason = state["failed"][0]["reason"]
            else:
                reason = "no CI run for this commit"
            return {"reuse": False, "candidateSource": "local-build",
                    "reason": f"no ready CI candidate ({reason})"}
        if time.time() >= deadline:
            return {"reuse": False, "candidateSource": "local-build",
                    "reason": f"no ready CI candidate within {deadline_seconds}s"}
        log("waiting for this commit's Linux candidate readiness marker...")
        time.sleep(max(1, poll_seconds))


def _still_running(status: dict) -> bool:
    """Whether this attempt has not reached a terminal state yet."""
    return status.get("status") != "completed"


def attempt_problems(status: dict, commit: str, *, require_success: bool = True) -> list[str]:
    """Why this attempt may not be adopted, if anything.

    The workflow name is checked too: `gh run view` accepts any run id, so an id
    that names some other workflow (or a run from another repository's number
    space) must be refused instead of being trusted for the artifact name.

    `require_success=False` is the adoption check: the attempt must exist for this
    commit but may still be running. `require_success=True` is the publication
    check, which additionally demands a successful, completed attempt.
    """
    problems: list[str] = []
    name = status.get("workflowName")
    if name not in {None, "", CANDIDATE_WORKFLOW_NAME}:
        problems.append(f"run {name!r} is not a CI workflow run")
    if status.get("headSha") not in {None, "", commit}:
        problems.append(f"run is for another commit: {status.get('headSha')}")
    if status.get("status") == "completed" and status.get("conclusion") not in {None, "success"}:
        problems.append(f"CI attempt concluded {status.get('conclusion')}")
    if require_success and (status.get("status") != "completed"
                            or status.get("conclusion") != "success"):
        problems.append(f"run attempt is {status.get('status')}/{status.get('conclusion')}, "
                        "not a successful completed CI attempt")
    return problems


def _explicit_candidate(repository: str, commit: str, run_id: str, attempt: int,
                        *, require_success: bool = True) -> dict:
    try:
        numeric = int(run_id)
    except ValueError:
        return {"reuse": False, "candidateSource": "local-build",
                "reason": f"candidate_run_id is not numeric: {run_id!r}"}
    status = attempt_status(repository, numeric, attempt)
    problems = attempt_problems(status, commit, require_success=require_success)
    if problems:
        return {"reuse": False, "candidateSource": "local-build",
                "reason": f"run {run_id} attempt {attempt}: {problems[0]}"}
    markers = live_markers(repository, numeric, attempt)
    if not markers:
        return {"reuse": False, "candidateSource": "local-build",
                "reason": f"run {run_id} attempt {attempt} published no readiness marker"}
    artifact = f"{CANDIDATE_ARTIFACT_PREFIX}-{numeric}-{attempt}"
    if not live_candidate_artifact(repository, artifact, numeric):
        return {"reuse": False, "candidateSource": "local-build",
                "reason": f"run {run_id} attempt {attempt} has no live {artifact}"}
    return {"reuse": True, "candidateSource": "ci-artifact", "runId": numeric,
            "runAttempt": attempt, "artifactName": artifact,
            "markerName": markers[0]["name"], "runConclusion": status.get("conclusion")}


def write_outputs(path: Path, document: dict) -> None:
    lines = [f"reuse={'true' if document['reuse'] else 'false'}",
             f"candidate_source={document['candidateSource']}",
             f"artifact_name={document.get('artifactName', '')}",
             f"marker_name={document.get('markerName', '')}",
             f"run_id={document.get('runId', '')}",
             f"run_attempt={document.get('runAttempt', 1)}",
             f"reason={document.get('reason', '')}"]
    with Path(path).open("a", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines) + "\n")


# --------------------------------------------------------------------- mark

def mark(repository: str, run_id: int, run_attempt: int, commit: str, tree: str,
         artifact_name: str, candidate_tar: Path, output_dir: Path) -> Path:
    """Publish the readiness marker for a successful Linux candidate.

    This runs only on the candidate job's success path, so the marker existing is
    the readiness claim. The payload repeats the identity so a consumer can bind
    the marker to the candidate bytes and the producing attempt.
    """
    if not Path(candidate_tar).is_file():
        raise ResolutionError(f"ci_candidate_source.py: candidate tar is missing: {candidate_tar}")
    for name, value in (("commit", commit), ("tree", tree)):
        if not is_object_id(value):
            raise ResolutionError(f"ci_candidate_source.py: {name} is not a full commit/tree sha: "
                                  f"{value!r}")
    document = {
        "schemaVersion": MARKER_SCHEMA,
        "repository": repository,
        "runId": run_id,
        "runAttempt": run_attempt,
        "commit": commit,
        "tree": tree,
        "artifactName": artifact_name,
        "candidateTarSha256": sha256_file(candidate_tar),
        "candidateTarSize": Path(candidate_tar).stat().st_size,
        "name": marker_name(run_id, run_attempt),
    }
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / f"{marker_name(run_id, run_attempt)}.json"
    destination.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8", newline="\n")
    return destination


# ------------------------------------------------------------------- verify

def verify_marker(repository: str, run_id: int, run_attempt: int, marker_dir: Path,
                  candidate_tar: Path, expected_artifact: str, commit: str) -> dict:
    """Bind a downloaded marker to the candidate bytes and the producing attempt."""
    expected_name = marker_name(run_id, run_attempt)
    path = Path(marker_dir) / f"{expected_name}.json"
    if not path.is_file():
        raise ResolutionError(f"ci_candidate_source.py: readiness marker is missing: {path}")
    document = json.loads(path.read_text(encoding="utf-8"))
    problems: list[str] = []
    if document.get("schemaVersion") != MARKER_SCHEMA:
        problems.append(f"schemaVersion {document.get('schemaVersion')!r} is not {MARKER_SCHEMA}")
    if document.get("name") != expected_name:
        problems.append(f"marker name {document.get('name')!r} is not {expected_name}")
    if document.get("repository") != repository:
        problems.append(f"marker repository {document.get('repository')!r} is not {repository}")
    if document.get("runId") != run_id or document.get("runAttempt") != run_attempt:
        problems.append("marker was published by another run or attempt")
    if document.get("commit") != commit:
        problems.append(f"marker commit {document.get('commit')!r} is not {commit}")
    if not is_object_id(document.get("tree")):
        problems.append("marker does not carry a full tree sha")
    if expected_artifact and document.get("artifactName") != expected_artifact:
        problems.append(f"marker artifact {document.get('artifactName')!r} is not {expected_artifact}")
    if not Path(candidate_tar).is_file():
        problems.append(f"candidate tar is missing: {candidate_tar}")
    else:
        actual = sha256_file(candidate_tar)
        if document.get("candidateTarSha256") != actual:
            problems.append(f"candidate tar digest {document.get('candidateTarSha256')!r} "
                            f"is not {actual}")
        if document.get("candidateTarSize") != Path(candidate_tar).stat().st_size:
            problems.append("candidate tar size does not match the marker")
    live = live_markers(repository, run_id, run_attempt)
    if not any(marker["name"] == expected_name for marker in live):
        problems.append(f"no live readiness marker artifact {expected_name} for run {run_id}")
    if problems:
        for problem in problems:
            print(f"readiness marker mismatch: {problem}", file=sys.stderr)
        raise ResolutionError("ci_candidate_source.py: readiness marker did not verify")
    print(f"readiness marker verified: {expected_name} -> {Path(candidate_tar).name} "
          f"({document['candidateTarSha256'][:12]})")
    return document


# -------------------------------------------------------------- require-ready

def require_ready(repository: str, commit: str, explicit_run_id: str,
                  explicit_run_attempt: str, event: str,
                  deadline_seconds: int = DEFAULT_GATE_SECONDS,
                  poll_seconds: int = DEFAULT_POLL_SECONDS, log=print) -> dict:
    """Prove the consumed branch really passed before a site may be published.

    The fast path may start Pages early, but publication must still see a CI run
    that finished successfully for this commit and whose Linux candidate was the
    one consumed.

    The consumed attempt's status is a point-in-time reading, so this waits (bounded)
    for it to become terminal instead of failing on the first look: Pages can
    legitimately reach this gate while the consumed CI workflow is still finishing,
    and failing here would throw away an otherwise successful deployment. It still
    fails closed if the attempt ultimately does not succeed.
    """
    if explicit_run_id:
        try:
            attempt = int(explicit_run_attempt or 1)
        except ValueError:
            raise ResolutionError(
                f"ci_candidate_source.py: candidate_run_attempt is not numeric: "
                f"{explicit_run_attempt!r}")
        deadline = time.time() + max(0, deadline_seconds)
        while True:
            status = attempt_status(repository, int(explicit_run_id), attempt)
            problems = attempt_problems(status, commit, require_success=True)
            if not problems:
                resolved = _explicit_candidate(repository, commit, explicit_run_id, attempt,
                                               require_success=True)
                if resolved["reuse"]:
                    return resolved
                problems = [resolved["reason"]]
            if not _still_running(status) or time.time() >= deadline:
                raise ResolutionError("ci_candidate_source.py: explicitly requested candidate "
                                      f"{explicit_run_id}/{attempt} is not usable: {problems[0]}")
            log(f"waiting for run {explicit_run_id} attempt {attempt} to finish...")
            time.sleep(max(1, poll_seconds))
    deadline = time.time() + max(0, deadline_seconds)
    while True:
        state = inspect_candidates(repository, commit, require_success=True)
        if len(state["ready"]) == 1:
            return state["ready"][0]
        if not state["pending"] or time.time() >= deadline:
            raise ResolutionError(
                f"ci_candidate_source.py: expected exactly one ready CI candidate for {commit}, "
                f"found {len(state['ready'])} (pending={state['pending']}, "
                f"failed={state['failed'][:3]})")
        log("waiting for the consumed CI run to finish successfully...")
        time.sleep(max(1, poll_seconds))


# ---------------------------------------------------------------------- CLI

def _default(name: str, fallback: str = "") -> str:
    return os.environ.get(name, fallback)


def _common(parser: argparse.ArgumentParser) -> None:
    """Options every subcommand accepts, so the flag may follow the verb.

    Callers spell `ci_candidate_source.py resolve --repository ...`, so a single
    top-level definition would be rejected by argparse.
    """
    parser.add_argument("--repository", default=_default("GITHUB_REPOSITORY"))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    resolve_parser = commands.add_parser("resolve", help="choose the candidate source")
    _common(resolve_parser)
    resolve_parser.add_argument("--commit", default=_default("GITHUB_SHA"))
    resolve_parser.add_argument("--event", default=_default("GITHUB_EVENT_NAME"))
    resolve_parser.add_argument("--explicit-run-id", default="")
    resolve_parser.add_argument("--explicit-run-attempt", default="")
    resolve_parser.add_argument("--deadline-seconds", type=int, default=DEFAULT_DEADLINE_SECONDS)
    resolve_parser.add_argument("--poll-seconds", type=int, default=DEFAULT_POLL_SECONDS)
    resolve_parser.add_argument("--out", type=Path)

    mark_parser = commands.add_parser("mark", help="publish this run's readiness marker")
    _common(mark_parser)
    mark_parser.add_argument("--run-id", type=int, required=True)
    mark_parser.add_argument("--run-attempt", type=int, required=True)
    mark_parser.add_argument("--commit", required=True)
    mark_parser.add_argument("--tree", required=True)
    mark_parser.add_argument("--artifact-name", required=True)
    mark_parser.add_argument("--candidate-tar", type=Path, required=True)
    mark_parser.add_argument("--out-dir", type=Path, required=True)

    verify_parser = commands.add_parser("verify", help="bind a marker to its candidate bytes")
    _common(verify_parser)
    verify_parser.add_argument("--run-id", type=int, required=True)
    verify_parser.add_argument("--run-attempt", type=int, required=True)
    verify_parser.add_argument("--marker-dir", type=Path, required=True)
    verify_parser.add_argument("--candidate-tar", type=Path, required=True)
    verify_parser.add_argument("--artifact-name", required=True)
    verify_parser.add_argument("--commit", default=_default("GITHUB_SHA"))
    verify_parser.add_argument("--out", type=Path)

    ready_parser = commands.add_parser("require-ready",
                                       help="fail unless the consumed branch passed")
    _common(ready_parser)
    ready_parser.add_argument("--commit", default=_default("GITHUB_SHA"))
    ready_parser.add_argument("--event", default=_default("GITHUB_EVENT_NAME"))
    ready_parser.add_argument("--explicit-run-id", default="")
    ready_parser.add_argument("--explicit-run-attempt", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.repository:
        raise SystemExit("ci_candidate_source.py: a repository is required "
                         "(set GITHUB_REPOSITORY or pass --repository)")
    if args.command == "resolve":
        document = resolve(args.repository, args.commit, args.event, args.explicit_run_id,
                           args.explicit_run_attempt, args.deadline_seconds, args.poll_seconds)
        if args.out:
            write_outputs(args.out, document)
        print(json.dumps(document, ensure_ascii=False, sort_keys=True))
        return 0
    if args.command == "mark":
        path = mark(args.repository, args.run_id, args.run_attempt, args.commit, args.tree,
                    args.artifact_name, args.candidate_tar, args.out_dir)
        print(f"readiness marker written: {path}")
        return 0
    if args.command == "verify":
        document = verify_marker(args.repository, args.run_id, args.run_attempt, args.marker_dir,
                                 args.candidate_tar, args.artifact_name, args.commit)
        if args.out:
            Path(args.out).write_text(
                json.dumps(document, ensure_ascii=False, sort_keys=True) + "\n",
                encoding="utf-8", newline="\n")
        return 0
    document = require_ready(args.repository, args.commit, args.explicit_run_id,
                            args.explicit_run_attempt, args.event)
    print("consumed Linux candidate is ready: " + json.dumps(document, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
