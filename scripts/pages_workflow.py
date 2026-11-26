#!/usr/bin/env python3
"""Bind Pages publication to terminal CI and select the actual shard producers."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from ci_candidate_source import gh_api, is_digest, is_object_id


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"pages workflow: {message}")


def positive(value: object) -> bool:
    return type(value) is int and value > 0


def require_ci_run(run: dict, repository: str, commit: str, run_id: int, attempt: int) -> None:
    require(positive(run_id) and positive(attempt) and is_object_id(commit), "invalid CI identity")
    require(run.get("id") == run_id and run.get("run_attempt") == attempt,
            "CI run or attempt does not match")
    require(run.get("name") == "CI" and run.get("path") == ".github/workflows/ci.yml"
            and run.get("event") == "push" and run.get("head_branch") == "main"
            and (run.get("head_repository") or {}).get("full_name") == repository
            and (run.get("repository") or {}).get("full_name") == repository,
            "expected a main push CI run from this repository")
    require(run.get("head_sha") == commit, "CI SHA does not match the Pages checkout")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "CI attempt has not completed successfully")


def ci_attempt(api, repository: str, commit: str, run_id: int, attempt: int) -> None:
    require(positive(run_id) and positive(attempt), "CI run and attempt must be positive integers")
    run = api(f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}", paginate=False)
    require_ci_run(run, repository, commit, run_id, attempt)


def upstream(api, event: dict, repository: str, commit: str) -> tuple[int, int]:
    run = event.get("workflow_run") or {}
    require(event.get("action") == "completed", "only CI completion can start automatic publication")
    run_id, attempt = run.get("id"), run.get("run_attempt")
    require_ci_run(run, repository, commit, run_id, attempt)
    ci_attempt(api, repository, commit, run_id, attempt)
    return run_id, attempt


def deployment_needed(api, repository: str, commit: str, run_id: int, attempt: int) -> bool:
    ci_attempt(api, repository, commit, run_id, attempt)
    root = f"repos/{repository}"
    main = api(f"{root}/git/ref/heads/main", paginate=False)
    if (main.get("object") or {}).get("sha") != commit:
        return False
    deployments = api(f"{root}/deployments?environment=github-pages&sha={commit}&per_page=100")
    require(isinstance(deployments, list), "could not read current Pages deployments")
    for deployment in deployments:
        require(deployment.get("sha") == commit and deployment.get("environment") == "github-pages"
                and positive(deployment.get("id")), "deployment identity mismatch")
        statuses = api(f"{root}/deployments/{deployment['id']}/statuses?per_page=100")
        require(isinstance(statuses, list), "could not read Pages deployment statuses")
        # The current environment job also creates a deployment record. Queued,
        # failed, and no-op jobs have no successful Pages URL and are not proof.
        if any(status.get("state") == "success" and status.get("environment_url")
               for status in statuses):
            return False
    return True


def artifacts_for_run(api, repository: str, run_id: int) -> list[dict]:
    response = api(f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100")
    artifacts = response.get("artifacts")
    require(isinstance(artifacts, list), "could not read run artifacts")
    return artifacts


def verified_artifact(artifacts: list[dict], name: str, repository_id: int, run_id: int, head: str) -> dict:
    selection = [item for item in artifacts if item.get("name") == name and item.get("expired") is False]
    require(len(selection) == 1, f"expected exactly one live producer artifact for {name}")
    artifact = selection[0]
    origin = artifact.get("workflow_run") or {}
    digest = artifact.get("digest")
    require(positive(artifact.get("id")) and isinstance(digest, str) and digest.startswith("sha256:")
            and is_digest(digest.removeprefix("sha256:")), f"missing archive digest for {name}")
    require(origin.get("id") == run_id and origin.get("repository_id") == repository_id
            and origin.get("head_sha") == head, f"wrong archive origin for {name}")
    return artifact


def verify_producers(api, repository: str, repository_id: int,
                     run_id: int, attempt: int, head: str, producers: list[str]) -> None:
    require(positive(run_id) and positive(attempt) and positive(repository_id) and is_object_id(head),
            "invalid Pages run identity")
    archives = artifacts_for_run(api, repository, run_id)
    expected = {"site", "source", "reading", "browser-shard-0", "browser-shard-1"}
    seen = set()
    for output in producers:
        fields = output.split(":", maxsplit=3)
        require(len(fields) == 4, "missing producer attempt, ID or digest")
        category, number, artifact_id, digest = fields
        require(category in expected and category not in seen and number.isascii() and number.isdecimal()
                and artifact_id.isascii() and artifact_id.isdecimal(), "invalid or duplicate producer")
        produced = int(number)
        require(1 <= produced <= attempt, "producer attempt is outside this run's dependency history")
        name = f"cjdoc-showcase-{category}-{run_id}-{produced}"
        artifact = verified_artifact(archives, name, repository_id, run_id, head)
        require(artifact["id"] == int(artifact_id)
                and artifact["digest"].removeprefix("sha256:") == digest.removeprefix("sha256:"),
                f"producer output does not match the immutable archive for {category}")
        seen.add(category)
    require(seen == expected, "missing a sealed-site or branch producer")


def verify_shard_binding(path: Path, *, shard: int, run_id: int, attempt: int,
                         revision: str, site_digest: str) -> None:
    receipt = json.loads(path.read_text(encoding="utf-8"))
    require(receipt.get("shardIndex") == shard and receipt.get("runId") == str(run_id)
            and receipt.get("runAttempt") == attempt and receipt.get("revision") == revision
            and receipt.get("siteSha256") == site_digest, f"shard {shard} evidence does not match its producer and site")


def write_outputs(path: Path, **values) -> None:
    with path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("upstream", "deployment", "verify-producers", "verify-shard"):
        command = commands.add_parser(name)
        if name != "verify-shard":
            command.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
        if name in {"upstream", "deployment"}:
            command.add_argument("--out", type=Path, required=True)
        if name != "verify-producers":
            command.add_argument("--commit", default=os.environ.get("GITHUB_SHA"))
        if name != "upstream":
            command.add_argument("--run-id", type=int, required=True)
            command.add_argument("--attempt", type=int, required=True)
        if name == "upstream":
            command.add_argument("--event", type=Path, required=True)
        elif name == "verify-producers":
            command.add_argument("--head", required=True)
            command.add_argument("--repository-id", type=int, required=True)
            command.add_argument("--producer", action="append", default=[])
        elif name == "verify-shard":
            command.add_argument("--file", type=Path, required=True)
            command.add_argument("--shard", type=int, required=True)
            command.add_argument("--site-digest", required=True)
    args = parser.parse_args(argv)
    if args.command == "upstream":
        run, attempt = upstream(gh_api, json.loads(args.event.read_text(encoding="utf-8")),
                                args.repository, args.commit)
        write_outputs(args.out, run_id=run, attempt=attempt)
    elif args.command == "deployment":
        needed = deployment_needed(gh_api, args.repository, args.commit, args.run_id, args.attempt)
        write_outputs(args.out, deploy=str(needed).lower())
        if not needed:
            print("Skipping deployment: main moved or this commit is already deployed")
    elif args.command == "verify-producers":
        verify_producers(gh_api, args.repository, args.repository_id,
                         args.run_id, args.attempt, args.head, args.producer)
    else:
        verify_shard_binding(args.file, shard=args.shard, run_id=args.run_id, attempt=args.attempt,
                             revision=args.commit, site_digest=args.site_digest)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(f"pages workflow: {error}", file=sys.stderr)
        raise SystemExit(1)
