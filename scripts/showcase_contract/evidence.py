"""Check browser evidence identity and coverage without pretending to run tests."""

from __future__ import annotations

import hashlib
from pathlib import Path

from .contract import array, fields, text, validate_manifest
from .site import ContractError, Site, canonical_json, relative_path
from .scenarios import BUDGETS, SCENARIOS
from .browser_metrics import validate_metrics
from .offline import ARCHIVE

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


def _validate_case(case: object, expected: dict, evidence_files: Site, measured: bool = False) -> tuple[str, ...]:
    required = {"featureId", "targetId", "scenarioId", "mode", "locale", "version",
                "status", "entry", "href", "activations", "documentNavigations",
                "assertions", "screenshot"}
    if measured:
        required |= {"metrics", "screenshots"}
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
    if measured:
        if key[2] not in SCENARIOS:
            raise ContractError("unregistered measured browser scenario")
        validate_metrics(case["metrics"], SCENARIOS[key[2]])
        validate_theme_images(case["screenshots"], evidence_files, SCENARIOS[key[2]][2])
        light = next(picture for picture in case["screenshots"] if picture["theme"] == "light")
        if case["screenshot"] != {field: light[field] for field in ("path", "sha256")}:
            raise ContractError("primary screenshot differs from the measured Light attachment")
    return key


def validate_theme_images(value: object, evidence_files: Site, width: int | None = None):
    images = array(value, "theme screenshots", nonempty=True)
    if len(images) != 2 or any(not isinstance(picture, dict) for picture in images):
        raise ContractError("both actively tested Light and Dark screenshots are required")
    if {picture.get("theme") for picture in images} != {"light", "dark"}:
        raise ContractError("both actively tested Light and Dark screenshots are required")
    if len({picture.get("path") for picture in images}) != 2:
        raise ContractError("theme screenshots must be distinct attachments")
    for picture in images:
        fields(picture, {"theme", "path", "sha256"}, set(), "theme screenshot")
        content = evidence_files.file(relative_path(picture["path"])).read_bytes()
        if not content.startswith(b"\x89PNG\r\n\x1a\n") or hashlib.sha256(content).hexdigest() != picture["sha256"]:
            raise ContractError("theme screenshot is missing, changed, or not a PNG")
        if width is not None and (len(content) < 24 or int.from_bytes(content[16:20], "big") != width):
            raise ContractError("theme screenshot width differs from the measured viewport")


def validate_evidence(manifest: dict, evidence: dict, site: Site, evidence_root: Path) -> None:
    """Require exact revision/tree/manifest identity and every promised scenario.

    Only a trusted runner may produce this input. This function cannot establish
    whether a screenshot or assertion was honestly produced by a browser; the
    scenario implementation and its CI execution remain separate required proof.
    Keep evidence outside the site to avoid a self-referential tree digest.
    """
    validate_manifest(manifest)
    measured = evidence.get("schemaVersion") == "cjdoc.showcase-evidence/2"
    required = {"schemaVersion", "revision", "manifestSha256", "siteSha256", "runner", "results"}
    if measured:
        required |= {"budgets", "siteMetrics", "homepages"}
    fields(evidence, required, set(), "evidence")
    if evidence["schemaVersion"] not in {EVIDENCE_SCHEMA, "cjdoc.showcase-evidence/2"}:
        raise ContractError("unsupported browser evidence schema")
    if measured:
        if evidence["budgets"] != BUDGETS:
            raise ContractError("browser evidence changed the reviewed regression budgets")
        sizes = {"siteBytes": sum(path.stat().st_size for path in site.root.rglob("*") if path.is_file()),
                 "offlineBytes": site.file(ARCHIVE).stat().st_size}
        if evidence["siteMetrics"] != sizes:
            raise ContractError("browser site sizes do not match the final tree")
        if any(value > BUDGETS[name] for name, value in sizes.items()):
            raise ContractError("final site exceeds reviewed size budgets")
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
    if not measured and any(key[2].count("-") >= 2 and key[2].rsplit("-", 1)[-1] in
                            {"desktop", "narrow", "mobile"} for key in expected):
        raise ContractError("final showcase journeys require measured browser evidence v2")
    if measured and any(key[2] not in SCENARIOS for key in expected):
        raise ContractError("unregistered measured browser scenario")
    evidence_root = evidence_root.absolute()
    if evidence_root.resolve().is_relative_to(site.root) or site.root.is_relative_to(evidence_root.resolve()):
        raise ContractError("browser evidence and final site must be separate trees")
    evidence_files = Site(evidence_root)
    if measured:
        wanted = {(key[4], SCENARIOS[key[2]][2], SCENARIOS[key[2]][3], key[3], SCENARIOS[key[2]][-1])
                  for key in expected}
        actual = set()
        for home in array(evidence["homepages"], "homepage observations", nonempty=True):
            fields(home, {"locale", "mode", "prefix", "viewport", "screenshots"}, set(), "homepage observation")
            fields(home["viewport"], {"width", "height"}, set(), "homepage viewport")
            identity = (home["locale"], home["viewport"]["width"], home["viewport"]["height"], home["mode"], home["prefix"])
            if identity not in wanted or identity in actual:
                raise ContractError("unexpected or repeated homepage observation")
            actual.add(identity)
            validate_theme_images(home["screenshots"], evidence_files, home["viewport"]["width"])
        if actual != wanted:
            raise ContractError("homepage locale/viewport/transport screenshot matrix is incomplete")
    seen = set()
    for case in array(evidence["results"], "browser results"):
        key = _validate_case(case, expected, evidence_files, measured)
        if key in seen:
            raise ContractError(f"duplicate browser evidence: {key}")
        seen.add(key)
    if missing := expected.keys() - seen:
        raise ContractError(f"missing browser scenarios: {sorted(missing)}")
