"""Check browser evidence identity and coverage without pretending to run tests."""

from __future__ import annotations

import hashlib
from pathlib import Path

from .contract import array, fields, text, validate_manifest
from .site import ContractError, Site, canonical_json, relative_path

EVIDENCE_SCHEMA = "cjdoc.showcase-evidence/1"


def _case_key(case: dict) -> tuple[str, ...]:
    return tuple(case[field] for field in
                 ("featureId", "targetId", "scenarioId", "mode", "locale", "version"))


def _expected_cases(manifest: dict) -> dict[tuple[str, ...], dict]:
    expected = {}
    for feature in manifest["features"]:
        if feature["demonstration"] != "available":
            continue
        for target in feature["targets"]:
            if target.get("resolved") is None:
                raise ContractError(f"available target is unresolved: {target['id']}")
            for scenario in target["scenarios"]:
                key = (feature["id"], target["id"], scenario["id"], scenario["mode"],
                       target["locale"], target["version"])
                if key in expected:
                    raise ContractError(f"duplicate expected scenario: {key}")
                expected[key] = target
    return expected


def _validate_case(case: object, expected: dict, evidence_files: Site) -> tuple[str, ...]:
    required = {"featureId", "targetId", "scenarioId", "mode", "locale", "version",
                "status", "entry", "href", "activations", "documentNavigations",
                "assertions", "screenshot"}
    case = fields(case, required, set(), "browser case")
    for key in ("featureId", "targetId", "scenarioId", "mode", "locale", "version"):
        text(case[key], f"browser case.{key}")
    key = _case_key(case)
    if key not in expected:
        raise ContractError(f"unexpected browser scenario: {key}")
    if case["status"] != "passed":
        raise ContractError(f"promised scenario did not pass: {key} ({case['status']})")
    # This deliberately checks the entry path, not only a page.goto at the target.
    if case["entry"] != "index.html":
        raise ContractError(f"scenario must start at the final homepage: {key}")
    if case["href"] != expected[key]["resolved"]["href"]:
        raise ContractError(f"browser scenario reached the wrong target: {key}")
    for metric in ("activations", "documentNavigations"):
        if type(case[metric]) is not int or case[metric] < 0:
            raise ContractError(f"{metric} must be a nonnegative integer: {key}")
    if case["activations"] < 1:
        raise ContractError(f"scenario must activate a homepage entry: {key}")
    for assertion in array(case["assertions"], "browser assertions", nonempty=True):
        text(assertion, "browser assertion")
    screenshot = fields(case["screenshot"], {"path", "sha256"}, set(), "screenshot")
    image = evidence_files.file(relative_path(screenshot["path"]))
    if hashlib.sha256(image.read_bytes()).hexdigest() != screenshot["sha256"]:
        raise ContractError(f"screenshot is missing or changed: {key}")
    return key


def validate_evidence(manifest: dict, evidence: dict, site: Site, evidence_root: Path) -> None:
    """Require exact revision/tree/manifest identity and every promised scenario.

    Only a trusted runner may produce this input. This function cannot establish
    whether a screenshot or assertion was honestly produced by a browser; the
    scenario implementation and its CI execution remain separate required proof.
    Keep evidence outside the site to avoid a self-referential tree digest.
    """
    validate_manifest(manifest)
    fields(evidence, {"schemaVersion", "revision", "manifestSha256", "siteSha256",
                      "runner", "results"}, set(), "evidence")
    if evidence["schemaVersion"] != EVIDENCE_SCHEMA:
        raise ContractError("unsupported browser evidence schema")
    if evidence["revision"] != manifest["revision"]:
        raise ContractError("browser evidence is for a different source revision")
    manifest_digest = hashlib.sha256(canonical_json(manifest)).hexdigest()
    if evidence["manifestSha256"] != manifest_digest:
        raise ContractError("browser evidence is for a different feature manifest")
    if evidence["siteSha256"] != site.digest():
        raise ContractError("browser evidence is stale: final published tree changed")
    runner = fields(evidence["runner"], {"name", "version", "browser", "browserVersion"}, set(), "runner")
    for field, value in runner.items():
        text(value, f"runner.{field}")
    expected = _expected_cases(manifest)
    evidence_root = evidence_root.absolute()
    if evidence_root.resolve().is_relative_to(site.root) or site.root.is_relative_to(evidence_root.resolve()):
        raise ContractError("browser evidence and final site must be separate trees")
    evidence_files = Site(evidence_root)
    seen = set()
    for case in array(evidence["results"], "browser results"):
        key = _validate_case(case, expected, evidence_files)
        if key in seen:
            raise ContractError(f"duplicate browser evidence: {key}")
        seen.add(key)
    if missing := expected.keys() - seen:
        raise ContractError(f"missing browser scenarios: {sorted(missing)}")
