#!/usr/bin/env python3
"""Publish a PR-scoped, head-bound completion status for managed Codex reviews.

The workflow executing this file MUST use trusted default-branch code, never
checkout the untrusted PR head with a write-capable GITHUB_TOKEN.
"""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

if __package__:
    from .codex_review_evidence import (
        CODEX_BOT_ID as CODEX_BOT_ID, CODEX_BOT_LOGIN as CODEX_BOT_LOGIN,
        SUMMARY_PREFIX as SUMMARY_PREFIX, SHA_PATTERN, GateDecision,
        affected_shared_heads, classify_codex_review, deleted_codex_summary,
        deletion_is_stale, pr_number_from_event,
    )
    from .codex_review_github import GitHubAPI, STATUS_CONTEXT
else:
    from codex_review_evidence import (
        CODEX_BOT_ID as CODEX_BOT_ID, CODEX_BOT_LOGIN as CODEX_BOT_LOGIN,
        SUMMARY_PREFIX as SUMMARY_PREFIX, SHA_PATTERN, GateDecision,
        affected_shared_heads, classify_codex_review, deleted_codex_summary,
        deletion_is_stale, pr_number_from_event,
    )
    from codex_review_github import GitHubAPI, STATUS_CONTEXT


def _merge_scope_is_unique(
    number: int, head_sha: str, base_sha: str, merge_sha: str, open_prs: list[dict]
) -> bool:
    """A PR-independent status is safe only on a PR-distinguishing merge SHA.

    Conservatively refuse when another open PR has the same head+base, even
    if GitHub temporarily reports a different or absent merge SHA for it.
    If the repository's open-PR listing is incomplete, do not grant success.
    """
    found_current = False
    for other in open_prs:
        if not isinstance(other, dict) or not isinstance(other.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if other["number"] == number:
            found_current = True
            continue
        other_head = (other.get("head") or {}).get("sha")
        other_base = (other.get("base") or {}).get("sha")
        if (
            other.get("merge_commit_sha") == merge_sha
            or (other_head == head_sha and other_base == base_sha)
        ):
            return False
    if not found_current:
        raise RuntimeError("current PR is missing from open-PR response")
    return True


def revoke_head_decision(api: GitHubAPI, number: int, head_sha: str,
                         pr_url: str) -> GateDecision:
    """Revoke the HEAD and return the "awaiting test merge" decision."""
    decision = GateDecision("pending", "Awaiting current PR test merge", pr_url)
    revoke_head_status(api, head_sha, decision)
    return decision


def revoke_head_status(api: GitHubAPI, head_sha: str, decision: GateDecision) -> None:
    """Withdraw a possible earlier `success` from the HEAD.

    A previous run -- possibly for a different PR that reused this commit -- may
    have left `success` here, and the ruleset reads the HEAD, so a stale success
    would authorize a merge this run has not verified.

    Only a non-success decision may be published by this function, and it is
    published unconditionally: denial is always safe. Even if another open PR
    currently shares this HEAD, no legitimate `success` can exist there (that PR
    would have had to refuse one too), so withdrawing it cannot destroy a valid
    conclusion. Leaving a stale `success` would be the dangerous outcome.
    """
    if decision.state == "success":
        raise ValueError("revoke_head_status must not publish a success")
    api.create_commit_status(head_sha, decision)


def _head_scope_is_unique(number: int, head_sha: str, open_prs: list[dict]) -> bool:
    """A status on the raw HEAD is safe only when one open PR owns that HEAD.

    The ruleset's required check is evaluated against the PR HEAD, but a status
    belongs to a SHA+context and not to a PR. Publishing on the HEAD is therefore
    allowed only when every open PR carrying that same HEAD is the current one --
    otherwise two PRs with different bases would share one review conclusion,
    which is exactly what the test-merge-only design was protecting against.
    """
    found_current = False
    for other in open_prs:
        if not isinstance(other, dict) or not isinstance(other.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if (other.get("head") or {}).get("sha") != head_sha:
            continue
        if other["number"] == number:
            found_current = True
        else:
            return False
    if not found_current:
        raise RuntimeError("current PR is missing from open-PR response")
    return True


class PublishedStatuses:
    """Every status this run has written, so a retry can withdraw all of them.

    A status belongs to a SHA, not to a PR. This run may publish on a HEAD, on a
    test-merge commit, and -- when the snapshot moves underneath it -- on several
    successive pairs. A later pass reads only the CURRENT snapshot and would
    therefore forget the earlier writes, leaving `success` behind on commits the
    PR has left; a later PR reusing such a commit would inherit that evidence.
    Carrying one ledger across the retries makes cleanup total instead of
    per-pass.

    Only `success` entries matter for authorization, but every written target is
    recorded so a withdrawal can also confirm that a prior success is gone.
    """

    def __init__(self) -> None:
        self._targets: dict[str, str] = {}

    def record(self, sha: str, decision: "GateDecision") -> None:
        self._targets[sha] = decision.state

    def successes(self) -> list[str]:
        return [sha for sha, state in self._targets.items() if state == "success"]

    def targets(self) -> list[str]:
        return list(self._targets)

    def __bool__(self) -> bool:
        return bool(self._targets)


class PrChangedDuringEvaluation(Exception):
    """The PR's head/base/test-merge moved while this run was working."""


class ReportingFailed(RuntimeError):
    """The pass confirmed its statuses but could not write its report.

    Distinct from an unconfirmed exit: the publication was already revalidated,
    so the retry loop must NOT withdraw it -- only fail the run so the problem is
    visible.
    """


class SupersededStatusNotWithdrawn(RuntimeError):
    """A status written for a superseded commit could not be withdrawn.

    A RuntimeError so the entry point reports it as a failure.
    """


def _publish(api: GitHubAPI, target: str, decision: GateDecision,
             published: "PublishedStatuses | None") -> None:
    """Write a status and remember it, so a later retry can withdraw it."""
    api.create_commit_status(target, decision)
    if published is not None:
        published.record(target, decision)


def _reconcile(api: GitHubAPI, published: "PublishedStatuses") -> None:
    """Withdraw every success this run published but did not confirm.

    Called on every exit that is NOT a confirmed success (snapshot change,
    exception, retry exhaustion, or the PR closing mid-flight). A status belongs
    to a SHA and this run cannot confirm what it wrote, so it withdraws all of
    its own writes rather than leaving any of them as apparent authorization.

    Keeping the ones that happen to sit on the current HEAD/test-merge is wrong:
    an unconfirmed write is exactly the case where the evidence has changed, so
    "still on the current SHA" is not evidence that the conclusion still holds.
    The next pass republishes whatever the CURRENT data supports, so a temporary
    `pending` here is bounded by that pass.

    Only this run's own targets are affected (the ledger is per-run), and denial
    is always safe. Two PRs sharing a commit can still not distinguish their
    conclusions on it, which the module documentation records as a limit of
    SHA-scoped statuses.
    """
    pending = GateDecision("pending", "Superseded by a newer snapshot", "")
    errors: list[str] = []
    for target in published.successes():
        try:
            _publish(api, target, pending, published)
        except Exception as error:  # noqa: BLE001 - any transport failure
            errors.append(f"{target[:10]}: {error}")
    if errors:
        raise SupersededStatusNotWithdrawn(
            "could not withdraw every superseded status: " + "; ".join(errors))


def evaluate_pr(api: GitHubAPI, number: int, *, deleted_summary: bool = False,
                deleted_comment: dict | None = None) -> GateDecision | None:
    """Evaluate a PR, retrying when another run changes it underneath us.

    Every gate run has its own concurrency group, so a newer run can complete
    while an older one is mid-flight. Re-evaluating the CURRENT snapshot (bounded)
    is what keeps a stale run from either revoking a newer valid status or
    publishing one that no longer describes the PR.

    One ledger spans the whole attempt: when a retry supersedes earlier writes,
    the earlier targets are withdrawn, otherwise a later pass could return early
    and leave their `success` behind for another PR to inherit.
    """
    published = PublishedStatuses()
    for _ in range(3):
        try:
            result = _evaluate_once(api, number, deleted_summary=deleted_summary,
                                    deleted_comment=deleted_comment, published=published)
        except PrChangedDuringEvaluation as changed:
            print(f"PR #{number}: {changed}; re-evaluating the current snapshot")
            _reconcile(api, published)
            continue
        except (SupersededStatusNotWithdrawn, ReportingFailed):
            # The publication is either already withdrawn or confirmed; neither
            # case should be reconciled again.
            raise
        except Exception as error:  # noqa: BLE001 - any failure mid-pass
            # A pass that ends in an error may have published without confirming
            # it. Reconcile first, then report the original failure.
            try:
                _reconcile(api, published)
            except SupersededStatusNotWithdrawn:
                pass  # the unwithdrawn target is the more serious fact
            raise error
        if result is None:
            # The PR is not open (e.g. it closed between passes). Nothing this run
            # published can authorize a closed PR, so clean up before returning.
            _reconcile(api, published)
            return None
        return result
    # The bound was reached with the snapshot still moving, so this run holds no
    # confirmed conclusion. Reconcile through the same rule used everywhere else:
    # nothing this run published may remain unless it still authorizes a live PR.
    print(f"PR #{number}: the PR kept changing; leaving the decision to a later event")
    _reconcile(api, published)
    return GateDecision("pending", "The PR changed repeatedly during evaluation", "")


@dataclass(frozen=True)
class _ReviewTarget:
    number: int
    head_sha: str
    base_sha: str
    merge_sha: str
    pr_url: str

    def matches(self, pr: dict) -> bool:
        return (
            (pr.get("head") or {}).get("sha") == self.head_sha
            and (pr.get("base") or {}).get("sha") == self.base_sha
            and pr.get("merge_commit_sha") == self.merge_sha
        )


def _withdraw_publication(api: GitHubAPI, target: _ReviewTarget,
                          published: PublishedStatuses | None) -> None:
    """Withdraw BOTH targets, each attempted independently.

    A status belongs to a SHA, not to a PR, so the test-merge commit and the
    HEAD can each carry a conclusion this run cannot confirm. Isolating the
    attempts means one failing endpoint cannot prevent the other withdrawal;
    if any attempt fails the run fails, because a success that cannot be
    withdrawn must never be left standing.
    """
    withdrawn = GateDecision("pending", "Publication could not be confirmed", target.pr_url)
    errors: list[str] = []
    for sha in (target.merge_sha, target.head_sha):
        try:
            _publish(api, sha, withdrawn, published)
        except Exception as error:  # noqa: BLE001 - any transport failure
            errors.append(f"{sha[:10]}: {error}")
    if errors:
        raise RuntimeError("could not withdraw every published status: "
                           + "; ".join(errors))


def _converge_decision(api: GitHubAPI, target: _ReviewTarget, fresh_decision: GateDecision,
                       published: PublishedStatuses | None) -> None:
    number, head_sha, merge_sha, pr_url = (
        target.number, target.head_sha, target.merge_sha, target.pr_url,
    )
    # The world moved while this run was publishing, so this run's
    # decision is superseded. Publishing `pending` here would be a
    # regression that can outlive the newer run (each run has its own
    # concurrency group, so an older one can finish last) and would
    # strand a valid result with no guaranteed repair. Instead converge
    # on the decision the CURRENT data supports -- computed by the same
    # `decide`, so this is not an upgrade from stale reasoning.
    _publish(api, merge_sha, fresh_decision, published)
    head_still_unique = _head_scope_is_unique(
        number, head_sha, api.list_open_pull_requests())
    if head_still_unique:
        _publish(api, head_sha, fresh_decision, published)
    else:
        # The HEAD is now shared, so a conclusion there cannot describe a
        # single PR. Withdraw the success just written rather than leaving
        # it for the other PR to inherit; a transient failure before the
        # next pass would otherwise leave exactly that.
        revoke_head_status(
            api, head_sha,
            GateDecision("pending", "HEAD shared with another open PR; withheld", pr_url),
        )
    # Re-enter the evaluation loop: the convergence writes above were not
    # themselves revalidated, and a concurrent deletion run could have
    # revoked between them. Looping checks the evidence again instead of
    # trusting this run's own last write.
    raise PrChangedDuringEvaluation(
        f"converged on {fresh_decision.state}; revalidating that decision")


def _confirm_scope(api: GitHubAPI, target: _ReviewTarget, publish_head: bool,
                   published: PublishedStatuses | None) -> str:
    number, head_sha, base_sha, merge_sha, pr_url = (
        target.number, target.head_sha, target.base_sha, target.merge_sha, target.pr_url,
    )
    # The post-publication `decide` revalidation reruns `_merge_scope_is_unique`,
    # but a twin PR (same head+base) can still appear between that call and this
    # scan. Recheck BOTH scopes here: the merge status must be withdrawn too, or a
    # twin would inherit a conclusion that was never scoped against it.
    final_open_prs = api.list_open_pull_requests()
    head_ok = _head_scope_is_unique(number, head_sha, final_open_prs)
    merge_ok = _merge_scope_is_unique(number, head_sha, base_sha, merge_sha, final_open_prs)
    # Merge-scope ambiguity is handled INDEPENDENTLY of `publish_head`: the
    # test-merge status may have been published even when the HEAD was withheld
    # (a different-base PR already shared the HEAD), and a distinct-HEAD PR can
    # still begin sharing the merge SHA. Either way the merge status no longer
    # describes one PR and must be withdrawn, along with the HEAD if this run
    # published one.
    if not merge_ok:
        reason = "the merge scope became ambiguous"
        _publish(api, merge_sha,
                 GateDecision("pending", f"Withheld: {reason}", pr_url), published)
        if publish_head:
            revoke_head_status(
                api, head_sha,
                GateDecision("pending", f"Withheld: {reason}", pr_url),
            )
        # The ambiguity may itself be transient: the twin could close while these
        # withdrawals run, in which case its own `closed` handler re-evaluates the
        # survivor and this stale `pending` would overwrite that valid success with
        # no later event to repair it. Hand the decision back to the retry loop so
        # the CURRENT scope is re-evaluated instead of treating this snapshot as
        # final.
        raise PrChangedDuringEvaluation("the merge scope became ambiguous")
    if publish_head and not head_ok:
        revoke_head_status(
            api, head_sha,
            GateDecision("pending", "HEAD shared with another open PR; withheld", pr_url),
        )
        return "revoked (HEAD became shared)"
    return ("published" if publish_head
            else "withheld (HEAD is shared with another open PR)")


def _publish_and_confirm(api: GitHubAPI, target: _ReviewTarget, decision: GateDecision,
                         decide: Callable[[], GateDecision],
                         published: PublishedStatuses | None) -> str:
    number, head_sha, merge_sha = target.number, target.head_sha, target.merge_sha

    # Every write lives inside one guard: any failure after a publication must
    # withdraw BOTH targets and propagate. Reporting success while a target sits
    # at `pending`, or worse at a stale success, would leave the PR either
    # unmergeable or wrongly authorized with no guaranteed event to repair it.
    try:
        current = api.get_pull_request(number)
        if not target.matches(current):
            # Nothing was published, so simply re-evaluate the current snapshot.
            raise PrChangedDuringEvaluation("the PR changed before anything was published")

        scope_now = api.list_open_pull_requests()
        publish_head = _head_scope_is_unique(number, head_sha, scope_now)
        _publish(api, merge_sha, decision, published)
        if publish_head:
            _publish(api, head_sha, decision, published)

        after = api.get_pull_request(number)
        after_head = (after.get("head") or {}).get("sha")
        after_base = (after.get("base") or {}).get("sha")
        after_merge = after.get("merge_commit_sha")
        if after.get("state") != "open":
            # The PR closed while this pass was publishing. A closed PR has no
            # authorization targets, so this pass must not return a success: the
            # retry loop reconciles through the ledger.
            raise PrChangedDuringEvaluation("the PR closed while publishing")
        if (after_head, after_base, after_merge) != (head_sha, target.base_sha, merge_sha):
            # The snapshot moved past what this pass published. Raising hands the
            # cleanup to the retry loop, which withdraws every success recorded in
            # the ledger -- including targets written by earlier passes, which a
            # fresh pass could not otherwise know about. One mechanism, one place.
            raise PrChangedDuringEvaluation("the PR changed while publishing")
        fresh_decision = decide()
        if fresh_decision != decision:
            _converge_decision(api, target, fresh_decision, published)
        # Final snapshot check: between the revalidation above and this return the
        # PR can close, or its base/test-merge can move. Returning `success` then
        # would leave the OLD test-merge commit authorized, and the run that
        # changed it only knows the NEW one, so nothing would revoke the old.
        # Compare every field, not just openness; raising hands cleanup to the
        # retry loop.
        final = api.get_pull_request(number)
        if final.get("state") != "open" or not target.matches(final):
            raise PrChangedDuringEvaluation("the PR changed before the conclusion was returned")
        return _confirm_scope(api, target, publish_head, published)
    except PrChangedDuringEvaluation:
        # Control flow, not a transport failure: propagate so the caller can
        # re-evaluate the current snapshot. Nothing needs withdrawing here --
        # either nothing was published, or the caller's next pass recomputes and
        # republishes under its own guard.
        raise
    except SupersededStatusNotWithdrawn:
        # Already reported with precise targets; re-wrapping would hide them and a
        # second withdrawal attempt here would just duplicate the failure.
        raise
    except Exception as error:  # noqa: BLE001 - any transport or protocol failure
        _withdraw_publication(api, target, published)
        if isinstance(error, (ValueError, RuntimeError)):
            raise
        raise RuntimeError(f"PR #{number} publication failed: {error}") from error


def _report_decision(target: _ReviewTarget, decision: GateDecision, head_status: str) -> None:
    number, head_sha, merge_sha = target.number, target.head_sha, target.merge_sha
    # Reporting sits outside the guard on purpose: both targets were published and
    # revalidated, so a logging failure is NOT a publication failure, and
    # withdrawing confirmed statuses would strand a valid review. It still fails
    # the run, so nothing is silent.
    try:
        print(f"PR #{number} HEAD {head_sha} test merge {merge_sha}: "
              f"{STATUS_CONTEXT} = {decision.state}")
        print(f"PR #{number} HEAD {head_sha}: {STATUS_CONTEXT} {head_status}")
        print(decision.description)
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as file:
                file.write(
                    f"### Codex review gate\n\n- PR: #{number}\n- HEAD: `{head_sha}`"
                    f"\n- Test merge: `{merge_sha}`\n- Status: **{decision.state}**"
                    f"\n- Result: {decision.description}"
                    "\n\nThis check verifies review completion, not that findings are resolved.\n"
                )
    except OSError as error:
        raise ReportingFailed(
            f"PR #{number}: reporting failed after the gate confirmed its statuses: {error}"
        ) from error


def _evaluate_once(api: GitHubAPI, number: int, *, deleted_summary: bool = False,
                   deleted_comment: dict | None = None,
                   published: "PublishedStatuses | None" = None) -> GateDecision | None:
    pr = api.get_pull_request(number)
    if pr.get("state") != "open":
        print(f"PR #{number} is not open; no commit status to publish")
        return None
    head_sha = (pr.get("head") or {}).get("sha")
    base_sha = (pr.get("base") or {}).get("sha")
    merge_sha = pr.get("merge_commit_sha")
    pr_url = pr["html_url"]
    if not isinstance(head_sha, str) or not SHA_PATTERN.fullmatch(head_sha):
        raise ValueError("GitHub PR response lacks a full HEAD SHA")

    # A HEAD can retain `success` from an earlier run, and this PR may be a new
    # one reusing the same commit. Revoke the HEAD FIRST, before any branch that
    # returns early, so a missing/invalid test merge cannot leave an old success
    # standing as an authorization for the check the ruleset reads.
    revoke_head_status(
        api, head_sha,
        GateDecision("pending", "Verifying PR-specific Codex review evidence", pr_url),
    )

    # A passing status is published on the test-merge SHA, never blindly on the
    # raw head: two distinct PRs may share that SHA with different base-dependent
    # diffs and reviews. The HEAD is written only under `_head_scope_is_unique`.
    if (
        not isinstance(base_sha, str)
        or not SHA_PATTERN.fullmatch(base_sha)
        or not isinstance(merge_sha, str)
        or not SHA_PATTERN.fullmatch(merge_sha)
        or merge_sha == head_sha
    ):
        print(f"PR #{number}: no candidate test-merge SHA; keep gate unreported")
        # The HEAD was already revoked above, so no second status is needed.
        return GateDecision("pending", "Awaiting current PR test merge", pr_url)

    # Revoke any previous success BEFORE further network calls. If the API
    # fails while we revalidate summary/merge, the gate stays pending.
    _publish(api, merge_sha,
             GateDecision("pending", "Verifying PR-specific Codex review evidence", pr_url),
             published)
    revoke_head_status(
        api, head_sha,
        GateDecision("pending", "Verifying PR-specific Codex review evidence", pr_url),
    )

    target = _ReviewTarget(number, head_sha, base_sha, merge_sha, pr_url)

    # Re-read the PR immediately before deciding. Another run (a base push, or
    # the base advancing while this run was in flight) may have changed the base
    # or HEAD since the first read, and publishing against the stale snapshot
    # would re-authorize a test merge that no longer describes this PR.
    fresh = api.get_pull_request(number)
    if not target.matches(fresh):
        # Re-evaluate rather than revoke: a newer base-push run may already have
        # published a valid success for this very HEAD, and this stale run would
        # otherwise overwrite it with `pending`, with no later event guaranteed.
        raise PrChangedDuringEvaluation("the PR changed during evaluation")

    merge = api.get_commit(merge_sha)
    parents = merge.get("parents") or []
    if not (
        len(parents) == 2
        and parents[0].get("sha") == base_sha
        and parents[1].get("sha") == head_sha
    ):
        print(f"PR #{number}: candidate test merge does not match current base/head")
        return GateDecision("pending", "Unverified test merge for current PR", pr_url)

    def decide() -> GateDecision:
        # Use the same current-evidence query both before and after publication.
        open_prs = api.list_open_pull_requests()
        comments = api.list_issue_comments(number)
        if not _merge_scope_is_unique(number, head_sha, base_sha, merge_sha, open_prs):
            return GateDecision(
                "pending", "Shared merge/head+base across PRs; review scope ambiguous", pr_url
            )
        if deleted_summary:
            if deletion_is_stale(deleted_comment, comments):
                print(f"PR #{number}: the deletion event is stale; a newer summary governs")
                return classify_codex_review(head_sha, comments, pr_url)
            return GateDecision("pending", "Codex review summary deleted; re-review required", pr_url)
        return classify_codex_review(head_sha, comments, pr_url)

    decision = decide()
    head_status = _publish_and_confirm(api, target, decision, decide, published)
    _report_decision(target, decision, head_status)
    return decision


def reevaluate_head_owners(api: GitHubAPI, head_sha: str, skip: set[int]) -> None:
    """Re-evaluate every open PR that owns `head_sha`, except `skip`.

    When no open PR owns the HEAD any more, no re-evaluation can withdraw the
    status it still carries, and a later PR reusing that commit would inherit
    valid-looking review evidence. So the HEAD is revoked first and
    unconditionally: denial is always safe, and this is the last moment any
    event is guaranteed to look at it.
    """
    failures: list[str] = []
    try:
        revoke_head_status(
            api, head_sha,
            GateDecision("pending", "Rechecking HEAD ownership after a PR left", ""),
        )
    except Exception as error:  # noqa: BLE001 - any transport failure
        # Aggregated rather than raised: abandoning the fanout here would leave
        # every surviving owner unevaluated, and the callers already treat a
        # raised aggregate as a failure.
        failures.append(f"HEAD {head_sha[:10]} revocation: {error}")
    for pull_request in api.list_open_pull_requests():
        if not isinstance(pull_request, dict) or not isinstance(pull_request.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if pull_request["number"] in skip:
            continue
        if (pull_request.get("head") or {}).get("sha") != head_sha:
            continue
        # Isolate each owner: a transient failure evaluating one must not stop
        # the others, or their HEADs stay in whatever state this left.
        try:
            evaluate_pr(api, pull_request["number"])
        except Exception as error:  # noqa: BLE001 - any transport failure
            failures.append(f"PR #{pull_request['number']}: {error}")
    if failures:
        raise RuntimeError("HEAD owner re-evaluation failed: " + "; ".join(failures))


def open_prs_targeting_branch(api: GitHubAPI, branch: str) -> tuple[list[int], dict[int, str]]:
    """Open PR numbers whose base is `branch`, plus each one's HEAD.

    A rewritten base branch does not change a PR's HEAD, so a `success` left on
    that immutable SHA would keep authorizing a review validated against an
    earlier base. GitHub sends no per-PR event for that, so the base push itself
    must re-evaluate every PR that targets it.

    The HEADs are returned with the numbers so the revocation phase does not need
    a second listing: a redundant scan could fail transiently before anything is
    revoked, leaving every affected HEAD authorized with no event to repair it.
    """
    numbers: list[int] = []
    heads: dict[int, str] = {}
    for pull_request in api.list_open_pull_requests():
        if not isinstance(pull_request, dict) or not isinstance(pull_request.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if (pull_request.get("base") or {}).get("ref") != branch:
            continue
        numbers.append(pull_request["number"])
        sha = (pull_request.get("head") or {}).get("sha")
        if isinstance(sha, str) and SHA_PATTERN.fullmatch(sha):
            heads[pull_request["number"]] = sha
    return numbers, heads


def reopened_head_owner(api: GitHubAPI, number: int) -> bool:
    """Is the PR of a `closed` event actually open again?

    A delayed `closed` delivery can arrive after the PR was reopened. Skipping
    that PR in the owner re-evaluation would leave its HEAD revoked forever, with
    no later event guaranteed, so the skip set must follow the current state.
    """
    return api.get_pull_request(number).get("state") == "open"


def reopen_aware_skip_set(api: GitHubAPI, event_name: str, event: dict,
                           number: int) -> set[int]:
    """PRs to exclude from HEAD-owner cleanup, honouring a delayed `closed`.

    A `closed` delivery can arrive after the PR was reopened. Skipping it would
    revoke its HEAD and then never restore it, and no later event is guaranteed,
    so the skip set follows the CURRENT state. When that state cannot be read the
    PR is INCLUDED (re-evaluated) rather than skipped: re-evaluation is always
    safe, while skipping may strand a live owner.
    """
    skip = {number}
    if event_name != "pull_request_target" or event.get("action") not in ("closed", "synchronize"):
        return skip
    try:
        current = api.get_pull_request(number)
    except Exception as error:  # noqa: BLE001 - any transport failure
        print(f"PR #{number}: could not re-read its state ({error}); "
              f"re-evaluating it anyway", file=sys.stderr)
        return set()
    # The triggering PR is excluded only while it does NOT own an affected HEAD.
    # A delayed delivery can arrive after the PR moved back onto that commit
    # (A -> B -> A reported as A -> B), and skipping it then would revoke the
    # CURRENT head and never restore it. Re-evaluating it is always safe: a
    # closed PR publishes nothing.
    if current.get("state") == "open":
        affected = set(affected_shared_heads(event_name, event))
        if (current.get("head") or {}).get("sha") in affected:
            print(f"PR #{number} owns the affected HEAD; it is re-evaluated as an owner")
            return set()
    return skip


def _reevaluate_base_push(api: GitHubAPI, branch: str) -> None:
    candidates, listed = open_prs_targeting_branch(api, branch)
    # Revoke all listed HEADs before evaluating any candidate: even a job timeout
    # must not leave the rest authorized against the old base. Use the existing
    # listing and a bounded pool so another API read or a serial sweep cannot
    # consume the revocation window.
    failures: list[str] = []

    def revoke_candidate(candidate: int) -> str | None:
        try:
            head = listed.get(candidate)
            if head is None:
                head = (api.get_pull_request(candidate).get("head") or {}).get("sha")
            if isinstance(head, str) and SHA_PATTERN.fullmatch(head):
                revoke_head_status(
                    api, head,
                    GateDecision("pending", "Base branch advanced; revalidating", ""),
                )
            return None
        except Exception as error:  # noqa: BLE001 - any transport failure
            return f"PR #{candidate} revocation: {error}"

    with ThreadPoolExecutor(max_workers=4) as pool:
        for outcome in pool.map(revoke_candidate, candidates):
            if outcome is not None:
                failures.append(outcome)

    # Re-evaluate only after all withdrawals have been attempted. Bound this
    # sweep too; no later event guarantees recovery for PRs left pending.
    def evaluate_candidate(candidate: int) -> str | None:
        try:
            evaluate_pr(api, candidate)
            print(f"re-evaluated PR #{candidate} after a push to {branch}")
            return None
        except Exception as error:  # noqa: BLE001 - any transport failure
            return f"PR #{candidate}: {error}"

    with ThreadPoolExecutor(max_workers=4) as pool:
        for outcome in pool.map(evaluate_candidate, candidates):
            if outcome is not None:
                failures.append(outcome)
    if failures:
        raise RuntimeError("base push re-evaluation failed: " + "; ".join(failures))


def run_gate(event_name: str, event: dict, api: GitHubAPI) -> int:
    """Evaluate the event's PR, then anyone else affected by the same HEAD.

    Kept separate from `main` so the orchestration itself is testable: dropping
    the re-evaluation, or re-evaluating the triggering PR twice, must fail a test
    rather than pass unnoticed.
    """
    if event_name == "push":
        # A base branch advanced; every open PR targeting it must be re-evaluated
        # so its HEAD status cannot keep authorizing a stale validation.
        branch = (event.get("ref") or "").removeprefix("refs/heads/")
        if not branch:
            print("push event without a branch; skip")
            return 0
        _reevaluate_base_push(api, branch)
        return 0
    number = pr_number_from_event(event_name, event)
    if number is None:
        print("Issue comment does not belong to a PR; skip")
        return 0
    # A HEAD shared by several PRs stays pending for all of them, so a PR that
    # closes or moves away must not leave the remaining owner stuck: re-evaluate
    # whoever still owns the HEAD this event changed, never the triggering PR.
    #
    # This runs even when the triggering PR's own evaluation raises: a transient
    # API or status-publication error there must not strand the surviving owner
    # with a `pending` check that no later event is guaranteed to clear. The
    # original error is re-raised after the survivors have had their chance.
    # The deleted comment is needed to decide whether a deletion delivery is
    # stale (a replacement summary may already have been reviewed).
    deleted_comment = (event.get("comment") or {}) if event_name == "issue_comment" else None
    try:
        evaluate_pr(api, number, deleted_summary=deleted_codex_summary(event_name, event),
                    deleted_comment=deleted_comment)
    except BaseException:
        # The triggering PR failed; re-evaluate the survivors best effort so this
        # error does not also strand them, then propagate the original failure.
        # The skip set is computed exactly as on the normal path, so a delayed
        # `closed` after a reopen is not stranded by this route either.
        try:
            recovery_skip = reopen_aware_skip_set(api, event_name, event, number)
        except Exception:  # noqa: BLE001 - never mask the original failure
            recovery_skip = {number}
        for head_sha in affected_shared_heads(event_name, event):
            try:
                reevaluate_head_owners(api, head_sha, recovery_skip)
            except Exception as error:  # noqa: BLE001 - any transport failure
                print(f"could not re-evaluate the remaining owners of {head_sha}: {error}",
                      file=sys.stderr)
        raise
    # Nothing else failed, so a survivor that cannot be re-evaluated is this
    # run's only problem: report it instead of exiting 0, because no later event
    # is guaranteed to retry it and its required check would stay pending.
    # A `closed` event that arrives after a reopen must not skip that PR, or its
    # HEAD would stay revoked with nothing left to restore it.
    skip = reopen_aware_skip_set(api, event_name, event, number)
    for head_sha in affected_shared_heads(event_name, event):
        reevaluate_head_owners(api, head_sha, skip)
        print(f"re-evaluated the remaining owners of {head_sha}")
    return 0


def main() -> int:
    environment_name = os.environ["GITHUB_EVENT_NAME"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    api = GitHubAPI(
        os.environ["GITHUB_REPOSITORY"],
        os.environ["GITHUB_TOKEN"],
        os.environ.get("GITHUB_API_URL", "https://api.github.com"),
    )
    return run_gate(environment_name, event, api)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, ValueError, RuntimeError) as error:
        print(f"Codex review gate: {error}", file=sys.stderr)
        sys.exit(1)
