"""Deterministic browser sharding: plan, per-shard run, strict merge.

The final-site browser acceptance is split by *homepage group*, never by case
within a group. The first case of a group captures the shared homepage
screenshots and activation counts that later cases in the group reuse, so
splitting a group would change what a shard observes. Groups therefore stay
atomic and are assigned to one shard each.

`merge` re-derives every identity from the real site and manifest and then calls
the unmodified `validate_evidence()` gate on the reassembled evidence, so a
sharded run is held to exactly the same bar as the single-process run.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .contract import validate_manifest
from .scenarios import SCENARIOS
from .site import ContractError, Site, canonical_json, load_json, relative_path

PLAN_SCHEMA = "cjdoc.showcase-browser-plan/1"
SHARD_SCHEMA = "cjdoc.showcase-browser-shard/1"
MERGE_SCHEMA = "cjdoc.showcase-browser-merge/1"
TIMING_SCHEMA = "cjdoc.browser-timing/1"
SHARD_COUNT = 2
CASE_FIELDS = ("featureId", "targetId", "scenarioId", "mode", "locale", "version")


def _case_key(target: dict, key: tuple) -> list[str]:
    return [key[0], key[1], key[2], key[3], key[4], key[5]]


def _home_key(target: dict, key: tuple) -> tuple:
    return (key[4], SCENARIOS[key[2]][2], SCENARIOS[key[2]][3], key[3], SCENARIOS[key[2]][-1])


def home_identity(home: tuple) -> tuple:
    """Canonical ordering identity for a homepage group."""
    return (home[0], home[3], home[4], home[1], home[2])


def home_record(home: tuple) -> dict:
    return dict(zip(("locale", "width", "height", "mode", "prefix"), home))


def _validate_shard_count(shards: int) -> None:
    if shards != SHARD_COUNT:
        raise ContractError(f"browser sharding supports exactly {SHARD_COUNT} shards, got {shards}")


def history_costs(history: Path | None) -> dict[tuple, float]:
    """Per-case elapsedMs history keyed by case key."""
    if history is None:
        return {}
    document = load_json(Path(history))
    if document.get("schemaVersion") != TIMING_SCHEMA:
        raise ContractError("browser timing history has an unexpected schema")
    timings = document.get("timings")
    if not isinstance(timings, list):
        raise ContractError("browser timing history is missing its timings list")
    costs: dict[tuple, float] = {}
    for entry in timings:
        if not isinstance(entry, dict) or not isinstance(entry.get("key"), list):
            raise ContractError("browser timing history has a malformed entry")
        elapsed = entry.get("elapsedMs")
        if not isinstance(elapsed, (int, float)) or isinstance(elapsed, bool) or elapsed < 0:
            raise ContractError("browser timing history has an invalid elapsedMs")
        costs[tuple(entry["key"])] = float(elapsed)
    return costs


def assign_home_groups(groups: dict[tuple, list], costs: dict[tuple, float]) -> tuple[dict[tuple, int], str]:
    """Assign whole homepage groups to shards.

    Without history the 18 groups alternate over sorted canonical order, giving
    9 groups per shard. With history each group costs the sum of its cases'
    observed elapsed time and groups are placed by longest-processing-time onto
    the currently lighter shard, with ties going to the lower shard index.
    """
    ordered = sorted(groups, key=home_identity)
    assignment: dict[tuple, int] = {}
    if not costs:
        for index, home in enumerate(ordered):
            assignment[home] = index % SHARD_COUNT
        return assignment, "equal-home-groups"
    loads = [0.0] * SHARD_COUNT
    for home in ordered:
        cost = sum(costs.get(key, 0.0) for key in groups[home])
        target = min(range(SHARD_COUNT), key=lambda shard: (loads[shard], shard))
        assignment[home] = target
        loads[target] += cost
    return assignment, "history-weighted"


def group_costs(groups: dict[tuple, list], costs: dict[tuple, float]) -> dict[str, float | None]:
    if not costs:
        return {str(home_identity(home)): None for home in sorted(groups, key=home_identity)}
    return {str(home_identity(home)): sum(costs.get(key, 0.0) for key in groups[home])
            for home in sorted(groups, key=home_identity)}


def build_plan(site_path: Path, run_id: str, shards: int = SHARD_COUNT,
               history: Path | None = None) -> dict:
    from .browser import registered_cases

    _validate_shard_count(shards)
    site = Site(site_path)
    manifest = load_json(site.file("showcase-features.json"))
    validate_manifest(manifest)
    cases = registered_cases(manifest)
    build_manifest = load_json(site.file("build.json"))
    order = {key: index for index, key in enumerate(cases)}
    groups: dict[tuple, list] = {}
    entries: list[dict] = []
    for key, target in cases.items():
        home = _home_key(target, key)
        groups.setdefault(home, []).append(key)
        entries.append({"key": _case_key(target, key), "homeKey": list(home)})
    if not groups:
        raise ContractError("no homepage groups to shard; refusing a vacuous plan")
    costs = history_costs(history)
    assignment, mode = assign_home_groups(groups, costs)
    home_entries = []
    for home in sorted(groups, key=home_identity):
        owner = min(groups[home], key=lambda item: order[item])
        home_entries.append({**home_record(home), "ownerShard": assignment[home],
                             "ownerCase": _case_key(cases[owner], owner)})
    for entry in entries:
        entry["shard"] = assignment[tuple(entry["homeKey"])]
    document = {
        "schemaVersion": PLAN_SCHEMA,
        "runId": run_id,
        "shardCount": shards,
        "revision": manifest["revision"],
        "siteSha256": site.digest(),
        "manifestSha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
        "binarySha256": build_manifest["tools"]["cjdocSha256"],
        "sourceArchiveSha256": build_manifest["sourceDownload"]["sha256"],
        # A null runner means "verified at run time" instead of pinned at plan time.
        "runner": {"playwright": None, "chromium": None},
        "cases": entries,
        "homeKeys": home_entries,
        "assignment": {"mode": mode,
                       "historySource": str(history) if history else None,
                       "groupCosts": group_costs(groups, costs)},
    }
    document["planSha256"] = hashlib.sha256(canonical_json(document)).hexdigest()
    return document


def load_plan(path: Path) -> dict:
    plan = load_json(Path(path))
    if plan.get("schemaVersion") != PLAN_SCHEMA:
        raise ContractError("browser shard plan has an unexpected schema")
    recorded = plan.get("planSha256")
    body = {name: value for name, value in plan.items() if name != "planSha256"}
    if recorded != hashlib.sha256(canonical_json(body)).hexdigest():
        raise ContractError("browser shard plan digest does not match its contents")
    if plan.get("shardCount") != SHARD_COUNT:
        raise ContractError("browser shard plan does not declare the supported shard count")
    return plan


def shard_cases(plan: dict, shard_index: int) -> list[dict]:
    if not 0 <= shard_index < plan["shardCount"]:
        raise ContractError(f"shard index out of range: {shard_index}")
    return [entry for entry in plan["cases"] if entry["shard"] == shard_index]


def verify_plan_against(plan: dict, site_path: Path) -> None:
    """Re-derive every identity from the real tree before trusting a shard."""
    site = Site(site_path)
    manifest = load_json(site.file("showcase-features.json"))
    build_manifest = load_json(site.file("build.json"))
    checks = {
        "siteSha256": site.digest(),
        "manifestSha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
        "revision": manifest["revision"],
        "binarySha256": build_manifest["tools"]["cjdocSha256"],
        "sourceArchiveSha256": build_manifest["sourceDownload"]["sha256"],
    }
    for name, actual in checks.items():
        if plan.get(name) != actual:
            raise ContractError(f"browser shard plan is stale: {name} {plan.get(name)} != {actual}")


def timing_document(shard: dict) -> dict:
    return {"schemaVersion": TIMING_SCHEMA,
            "timings": [{"key": case["key"], "elapsedMs": case["elapsedMs"]}
                        for case in shard["results"]]}


def verify_attachment(root: Path, attachment: dict) -> str:
    relative = relative_path(attachment.get("relativePath"))
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"shard attachment is missing: {relative}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != attachment.get("sha256"):
        raise ContractError(f"shard attachment changed: {relative}")
    if path.suffix == ".png" and path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        raise ContractError(f"shard attachment is not a PNG: {relative}")
    return relative


def _validate_shard(plan: dict, index: int, shard: dict) -> None:
    if shard.get("schemaVersion") != SHARD_SCHEMA:
        raise ContractError(f"shard {index} has an unexpected schema")
    if shard.get("shardIndex") != index or shard.get("shardCount") != plan["shardCount"]:
        raise ContractError(f"shard {index} reports a different shard position")
    if shard.get("planSha256") != plan["planSha256"]:
        raise ContractError(f"shard {index} was produced from a different plan")
    if shard.get("status") != "passed":
        raise ContractError(f"shard {index} did not pass: {shard.get('status')}")
    if shard.get("runId") != plan.get("runId"):
        raise ContractError(f"shard {index} was produced by a different run")
    for name in ("revision", "siteSha256", "manifestSha256", "binarySha256", "sourceArchiveSha256"):
        if shard.get(name) != plan.get(name):
            raise ContractError(f"shard {index} identity mismatch: {name}")
    for name in ("budgets", "siteMetrics", "runner"):
        if name not in shard:
            raise ContractError(f"shard {index} omits {name}")
    expected = [entry["key"] for entry in shard_cases(plan, index)]
    if shard.get("expectedCases") != expected:
        raise ContractError(f"shard {index} did not plan the expected cases")


def _namespaced(pictures: list, prefix: str) -> list:
    """Return picture records whose paths live under the shard namespace."""
    return [{**picture, "path": f"{prefix}/{relative_path(picture['path'])}"} for picture in pictures]


def _stage_attachments(shard_root: Path, merged_root: Path, prefix: str, shard: dict) -> list[str]:
    """Copy one shard's attachments into `merged_root/<prefix>/`, verifying digests."""
    staged: list[str] = []
    for attachment in shard.get("attachments", []):
        relative = verify_attachment(shard_root, attachment)
        source = shard_root / relative
        destination = merged_root / prefix / relative
        if destination.exists():
            raise ContractError(f"shard attachment path collision: {prefix}/{relative}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
        if hashlib.sha256(destination.read_bytes()).hexdigest() != attachment["sha256"]:
            raise ContractError(f"staged shard attachment changed: {prefix}/{relative}")
        staged.append(f"{prefix}/{relative}")
    if len({name.lower() for name in staged}) != len(staged):
        raise ContractError(f"shard attachment case collision under {prefix}")
    return staged


def merge(plan_path: Path, shard_files: dict[int, Path], site_path: Path, evidence_root: Path,
          receipt_path: Path) -> dict:
    """Strictly reassemble shard evidence and hold it to the unmodified full gate.

    Shard screenshots keep their `screenshot_name()` filenames but are staged
    under a `shard-<N>/` namespace, so two shards can never overwrite each
    other's attachments and a stale file cannot be adopted from a previous run.
    """
    from .browser import registered_cases
    from .evidence import validate_evidence

    plan = load_plan(plan_path)
    if sorted(shard_files) != list(range(plan["shardCount"])):
        raise ContractError(f"merge needs exactly shards {list(range(plan['shardCount']))}, "
                            f"got {sorted(shard_files)}")
    verify_plan_against(plan, site_path)
    site = Site(site_path)
    manifest = load_json(site.file("showcase-features.json"))
    expected_keys = [tuple(entry["key"]) for entry in plan["cases"]]
    shard_of = {tuple(entry["key"]): entry["shard"] for entry in plan["cases"]}
    home_owners = {(home["locale"], home["width"], home["height"], home["mode"], home["prefix"]):
                   home["ownerShard"] for home in plan["homeKeys"]}

    root = Path(evidence_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    results: list[dict] = []
    homepages: list[dict] = []
    runner = budgets = site_metrics = None
    seen: set[tuple] = set()
    staged_paths: set[str] = set()
    shard_records: list[dict] = []
    for index in sorted(shard_files):
        path = Path(shard_files[index])
        if path.is_symlink() or not path.is_file():
            raise ContractError(f"shard {index} result is missing or a symlink: {path}")
        shard_root = path.resolve().parent
        shard = load_json(path)
        _validate_shard(plan, index, shard)
        if not any(entry["shard"] == index for entry in plan["cases"]):
            raise ContractError(f"shard {index} owns no planned cases")
        if budgets is None:
            budgets, site_metrics, runner = shard["budgets"], shard["siteMetrics"], shard["runner"]
        elif (shard["budgets"], shard["siteMetrics"], shard["runner"]) != (budgets, site_metrics, runner):
            raise ContractError(f"shard {index} reports different budgets or runner identity")
        prefix = f"shard-{index}"
        for name in _stage_attachments(shard_root, root, prefix, shard):
            if name.lower() in {existing.lower() for existing in staged_paths}:
                raise ContractError(f"shard attachment case collision: {name}")
            staged_paths.add(name)
        for case in shard.get("results", []):
            key = tuple(case.get(field) for field in CASE_FIELDS)
            if key not in shard_of:
                raise ContractError(f"shard {index} reported an unknown case: {key}")
            if shard_of[key] != index:
                raise ContractError(f"shard {index} reported a case owned by another shard: {key}")
            if key in seen:
                raise ContractError(f"duplicate case across shards: {key}")
            if case.get("status") != "passed":
                raise ContractError(f"shard case did not pass: {key}")
            seen.add(key)
            results.append({**case,
                            "screenshot": _namespaced([case["screenshot"]], prefix)[0],
                            "screenshots": _namespaced(case["screenshots"], prefix)})
        for home in shard.get("homepages", []):
            viewport = home.get("viewport") or {}
            identity = (home.get("locale"), viewport.get("width"), viewport.get("height"),
                        home.get("mode"), home.get("prefix"))
            if identity not in home_owners:
                raise ContractError(f"shard {index} reported an unknown homepage group: {identity}")
            if home_owners[identity] != index:
                raise ContractError(f"shard {index} reported a homepage group it does not own: {identity}")
            homepages.append({**home, "screenshots": _namespaced(home["screenshots"], prefix)})
        shard_records.append({"shardIndex": index, "file": path.name,
                              "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                              "runId": shard.get("runId"), "runAttempt": shard.get("runAttempt")})
    missing = [key for key in expected_keys if key not in seen]
    if missing:
        raise ContractError(f"missing browser scenarios after merge: {missing[:3]}")
    if len(homepages) != len(home_owners):
        raise ContractError("merged homepage coverage is incomplete")
    if len({(home["locale"], home["viewport"]["width"], home["viewport"]["height"],
             home["mode"], home["prefix"]) for home in homepages}) != len(homepages):
        raise ContractError("merged homepage observations contain duplicates")
    reassembled = {
        "schemaVersion": "cjdoc.showcase-evidence/2",
        "revision": manifest["revision"],
        "manifestSha256": plan["manifestSha256"],
        "siteSha256": plan["siteSha256"],
        "budgets": budgets,
        "siteMetrics": site_metrics,
        "homepages": sorted(homepages, key=lambda home: (
            home["locale"], home["viewport"]["width"], home["viewport"]["height"],
            home["mode"], home["prefix"])),
        "runner": runner,
        "results": sorted(results, key=lambda case: expected_keys.index(
            tuple(case[field] for field in CASE_FIELDS))),
    }
    validate_evidence(manifest, reassembled, site, root)
    results_path = root / "results.json"
    results_path.write_text(json.dumps(reassembled, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8", newline="\n")
    receipt = {
        "schemaVersion": MERGE_SCHEMA,
        "planSha256": plan["planSha256"],
        "resultsSha256": hashlib.sha256(results_path.read_bytes()).hexdigest(),
        "siteSha256": plan["siteSha256"],
        "revision": plan["revision"],
        "shards": shard_records,
    }
    Path(receipt_path).write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8", newline="\n")
    assert registered_cases  # keeps the browser scenario registration import live
    return receipt
