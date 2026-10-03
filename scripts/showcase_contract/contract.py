"""Author plan validation and deterministic resolution of final output targets."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

from .site import ContractError, Site, canonical_json, load_json, relative_path

PLAN_SCHEMA = "cjdoc.showcase-plan/1"
MANIFEST_SCHEMA = "cjdoc.showcase-features/1"
IMPLEMENTATIONS = {"complete", "partial", "not-implemented"}
DEMONSTRATIONS = {"available", "uncovered", "blocked"}
IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,95}\Z")
REVISION = re.compile(r"(?:[a-f0-9]{40}|[a-f0-9]{64})\Z")


def fields(value: object, required: set[str], optional: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    if missing := required - value.keys():
        raise ContractError(f"{label} missing fields: {sorted(missing)}")
    if extra := value.keys() - required - optional:
        raise ContractError(f"{label} unknown fields: {sorted(extra)}")
    return value


def text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{label} must be a nonempty string")
    return value


def identifier(value: object, label: str) -> str:
    value = text(value, label)
    if not IDENTIFIER.fullmatch(value):
        raise ContractError(f"{label} must be a short stable identifier")
    return value


def array(value: object, label: str, *, nonempty: bool = False) -> list:
    if not isinstance(value, list) or nonempty and not value:
        raise ContractError(f"{label} must be {'a nonempty' if nonempty else 'an'} array")
    return value


def validate_target(target: object) -> dict:
    common = {"id", "kind", "locale", "version", "instructions", "scenarios"}
    target = fields(target, common, {"index", "project", "match", "path", "jsonChecks", "docIr", "signature", "placement"}, "target")
    identifier(target["id"], "target.id")
    locale = text(target["locale"], "target.locale")
    if not re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", locale):
        raise ContractError("target.locale must be an explicit HTML language tag")
    text(target["version"], "target.version")
    text(target["instructions"], "target.instructions")
    scenarios = array(target["scenarios"], "target.scenarios", nonempty=True)
    seen = set()
    for scenario in scenarios:
        fields(scenario, {"id", "mode"}, set(), "scenario")
        identifier(scenario["id"], "scenario.id")
        if scenario["mode"] not in ("http", "file"):
            raise ContractError("scenario.mode must be http or file")
        key = (scenario["id"], scenario["mode"])
        if key in seen:
            raise ContractError(f"duplicate scenario: {key}")
        seen.add(key)
    if target["kind"] == "navigation":
        fields(target, common | {"index", "project", "match"}, {"docIr", "signature", "placement"}, "navigation target")
        relative_path(target["index"])
        project = fields(target["project"], {"name", "audience", "version"}, set(), "project")
        for key in project:
            text(project[key], f"project.{key}")
        if project["version"] != target["version"]:
            raise ContractError("target.version must match the navigation project's version")
        match = fields(target["match"], {"kind", "title"}, {"packageName", "moduleId"}, "match")
        for key, value in match.items():
            text(value, f"match.{key}")
        if match["kind"] not in ("project", "machine", "concept", "package", "symbol"):
            raise ContractError("match.kind is not in navigation-index/1")
        if match["kind"] == "symbol" and not (match.get("packageName") or match.get("moduleId")):
            raise ContractError("symbol selectors need packageName or moduleId scope")
        if "signature" in target:
            text(target["signature"], "target.signature")
        if target.get("placement", "page") not in ("page", "member"):
            raise ContractError("placement must be page or member")
        if "signature" in target or target.get("placement") == "member":
            if match["kind"] != "symbol" or "docIr" not in target:
                raise ContractError("signature/member selectors require scoped symbols and docIr")
        if "docIr" in target:
            relative_path(target["docIr"])
            if match["kind"] != "symbol":
                raise ContractError("docIr selectors apply only to symbols")
    elif target["kind"] == "artifact":
        fields(target, common | {"path"}, {"jsonChecks"}, "artifact target")
        relative_path(target["path"])
        if "jsonChecks" in target:
            checks = target["jsonChecks"]
            if not isinstance(checks, dict) or not checks:
                raise ContractError("jsonChecks must contain expected JSON pointers")
            if not isinstance(checks.get("/schemaVersion"), str):
                raise ContractError("JSON reports require an expected /schemaVersion")
            for pointer in checks:
                if not pointer.startswith("/") or re.search(r"~(?![01])", pointer):
                    raise ContractError(f"invalid JSON pointer: {pointer}")
    else:
        raise ContractError("target.kind must be navigation or artifact")
    return target


def validate_plan(plan: object) -> dict:
    plan = fields(plan, {"schemaVersion", "features"}, set(), "plan")
    if plan["schemaVersion"] != PLAN_SCHEMA:
        raise ContractError("unsupported showcase plan schema")
    features = array(plan["features"], "features", nonempty=True)
    seen = set()
    for feature in features:
        fields(feature, {"id", "title", "implementation", "demonstration", "reason",
                         "trackingIssues", "inputs", "targets"}, set(), "feature")
        fid = identifier(feature["id"], "feature.id")
        if fid in seen:
            raise ContractError(f"duplicate feature ID: {fid}")
        seen.add(fid)
        text(feature["title"], "feature.title")
        if not isinstance(feature["implementation"], str) or feature["implementation"] not in IMPLEMENTATIONS:
            raise ContractError(f"invalid implementation state: {fid}")
        if not isinstance(feature["demonstration"], str) or feature["demonstration"] not in DEMONSTRATIONS:
            raise ContractError(f"invalid demonstration state: {fid}")
        available = feature["demonstration"] == "available"
        if available and feature["implementation"] == "not-implemented":
            raise ContractError(f"unimplemented capability cannot be available: {fid}")
        if not isinstance(feature["reason"], str):
            raise ContractError("feature.reason must be a string")
        if feature["implementation"] != "complete" or not available:
            text(feature["reason"], "feature.reason")
        issues = array(feature["trackingIssues"], "trackingIssues")
        if any(type(issue) is not int or issue < 1 for issue in issues) or len(set(issues)) != len(issues):
            raise ContractError("trackingIssues must be unique positive issue numbers")
        if feature["demonstration"] == "blocked" and not issues:
            raise ContractError(f"blocked feature needs a tracking issue: {fid}")
        inputs = array(feature["inputs"], "inputs", nonempty=available)
        for path in inputs:
            relative_path(path)
        if len(set(inputs)) != len(inputs):
            raise ContractError(f"duplicate source input: {fid}")
        targets = array(feature["targets"], "targets", nonempty=available)
        target_ids = set()
        for target in targets:
            validate_target(target)
            if target["id"] in target_ids:
                raise ContractError(f"duplicate target ID in {fid}: {target['id']}")
            target_ids.add(target["id"])
    return plan


def json_pointer(value: object, pointer: str) -> object:
    for part in pointer.split("/")[1:]:
        key = part.replace("~1", "/").replace("~0", "~")
        if isinstance(value, dict) and key in value:
            value = value[key]
        elif isinstance(value, list) and re.fullmatch(r"0|[1-9][0-9]*", key) and int(key) < len(value):
            value = value[int(key)]
        else:
            raise ContractError(f"report is missing expected JSON pointer: {pointer}")
    return value


def source_digest(repo: Path, name: str) -> str:
    path = repo / relative_path(name)
    if any(parent.is_symlink() for parent in (path, *path.parents) if parent != repo.parent):
        raise ContractError(f"symlink in showcase source input: {name}")
    if not path.is_file() or not path.resolve().is_relative_to(repo):
        raise ContractError(f"missing or nonregular showcase source input: {name}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_plan(plan: dict, site: Site, repo: Path, revision: str) -> dict:
    """Resolve promised targets; do not silently demote unavailable/ambiguous ones.

    The resulting `available` state is a publication requirement, not evidence
    that a browser test ran. Publication MUST run validate_evidence afterwards.
    """
    validate_plan(plan)
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise ContractError("revision must be a full lowercase Git commit object ID")
    if repo.is_symlink() or not repo.is_dir():
        raise ContractError("source root must be a regular directory")
    repo = repo.resolve()
    features = []
    for feature in plan["features"]:
        resolved = {**feature, "inputs": [
            {"path": name, "sha256": source_digest(repo, name)}
            for name in sorted(feature["inputs"])
        ], "targets": []}
        for target in feature["targets"]:
            result = {**target, "resolved": None}
            if feature["demonstration"] == "available":
                if target["kind"] == "navigation":
                    result["resolved"] = site.navigation_target(target)
                else:
                    artifact = site.file(target["path"])
                    if "jsonChecks" in target:
                        report = load_json(artifact)
                        for pointer, expected in target["jsonChecks"].items():
                            if canonical_json(json_pointer(report, pointer)) != canonical_json(expected):
                                raise ContractError(f"report identity mismatch: {target['path']} {pointer}")
                    result["resolved"] = {"href": target["path"],
                                          "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest()}
            resolved["targets"].append(result)
        features.append(resolved)
    manifest = {"schemaVersion": MANIFEST_SCHEMA, "revision": revision,
            "planSha256": hashlib.sha256(canonical_json({**plan, "features": [
                {**f, "inputs": sorted(f["inputs"])} for f in plan["features"]
            ]})).hexdigest(), "features": features}
    return validate_manifest(manifest)


def check_regressions(previous: dict, current: dict) -> None:
    """A disappearing or downgraded available feature requires explicit review.

    There is deliberately no allow-regression flag: update the reviewed baseline
    in a separate change instead of deleting a card to get a green build.
    """
    validate_manifest(previous)
    validate_manifest(current)
    after = {feature["id"]: feature for feature in current["features"]}
    for before in previous["features"]:
        if before["demonstration"] != "available":
            continue
        now = after.get(before["id"])
        if not now or now["demonstration"] != "available":
            raise ContractError(f"showcase availability regressed: {before['id']}")
        expected = {(t["id"], t["locale"], t["version"], s["id"], s["mode"])
                    for t in before["targets"] for s in t["scenarios"]}
        actual = {(t["id"], t["locale"], t["version"], s["id"], s["mode"])
                  for t in now["targets"] for s in t["scenarios"]}
        if not expected <= actual:
            raise ContractError(f"showcase scenario coverage regressed: {before['id']}")


def validate_manifest(manifest: object) -> dict:
    """Validate a resolved manifest and its self-contained author-plan digest."""
    manifest = fields(manifest, {"schemaVersion", "revision", "planSha256", "features"}, set(), "manifest")
    if manifest["schemaVersion"] != MANIFEST_SCHEMA:
        raise ContractError("unsupported resolved manifest schema")
    if not isinstance(manifest["revision"], str) or not REVISION.fullmatch(manifest["revision"]):
        raise ContractError("manifest revision must be a full commit object ID")
    features = []
    resolved_targets = []
    for feature in array(manifest["features"], "manifest.features", nonempty=True):
        fields(feature, {"id", "title", "implementation", "demonstration", "reason",
                         "trackingIssues", "inputs", "targets"}, set(), "resolved feature")
        inputs = []
        for source in array(feature["inputs"], "resolved inputs"):
            fields(source, {"path", "sha256"}, set(), "resolved input")
            relative_path(source["path"])
            if not isinstance(source["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", source["sha256"]):
                raise ContractError("resolved source input requires a SHA-256 digest")
            inputs.append(source["path"])
        targets = []
        for target in array(feature["targets"], "resolved targets"):
            if not isinstance(target, dict) or "resolved" not in target:
                raise ContractError("manifest target needs explicit resolved state")
            author_target = {key: value for key, value in target.items() if key != "resolved"}
            targets.append(author_target)
            resolved_targets.append((feature["demonstration"], author_target, target["resolved"]))
        features.append({**feature, "inputs": inputs, "targets": targets})
    author_plan = validate_plan({"schemaVersion": PLAN_SCHEMA, "features": features})
    normalized = {**author_plan, "features": [{**f, "inputs": sorted(f["inputs"])} for f in features]}
    if manifest["planSha256"] != hashlib.sha256(canonical_json(normalized)).hexdigest():
        raise ContractError("resolved manifest does not match its author-plan digest")
    from urllib.parse import urlsplit
    for state, target, resolved in resolved_targets:
        if state != "available":
            if resolved is not None:
                raise ContractError("uncovered/blocked targets must not acquire implicit links")
            continue
        if target["kind"] == "navigation":
            member_fields = {"memberPageHref", "ownerSymbolId", "signature", "memberName"}
            required = {"href", "symbolId", "pageId", "semanticState"}
            if target.get("placement") == "member":
                required |= member_fields
            fields(resolved, required, set(), "resolved navigation")
            if target.get("placement") == "member":
                for name in member_fields:
                    text(resolved[name], f"resolved {name}")
                member_path = urlsplit(resolved["memberPageHref"])
                if member_path.scheme or member_path.netloc or member_path.query or member_path.fragment:
                    raise ContractError("member permalink must be a local page path")
                relative_path(member_path.path)
                if not urlsplit(resolved["href"]).fragment:
                    raise ContractError("inline member route must contain its native anchor")
            text(resolved["pageId"], "resolved pageId")
            for key in ("symbolId", "semanticState"):
                if resolved[key] is not None:
                    text(resolved[key], f"resolved {key}")
            if target["match"]["kind"] == "symbol":
                text(resolved["symbolId"], "resolved symbolId")
        else:
            fields(resolved, {"href", "sha256"}, set(), "resolved artifact")
            if not isinstance(resolved["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", resolved["sha256"]):
                raise ContractError("resolved artifact requires a SHA-256 digest")
        href = text(resolved["href"], "resolved href")
        try:
            parsed = urlsplit(href)
        except ValueError as error:
            raise ContractError("invalid resolved href") from error
        if parsed.scheme or parsed.netloc or parsed.query or any(ord(c) < 32 or ord(c) == 127 for c in href):
            raise ContractError("resolved href must be a local published path")
        relative_path(parsed.path)
    return manifest
