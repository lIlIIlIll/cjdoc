"""Evidence-only comparison for the registered default-field v17/v18 transition.

This is not a product decoder or input migration. Raw observations stay unchanged.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_loads
except ImportError:
    from strict_json import strict_loads

TRANSITION_NAME = "v17-v18-unregistered-source"
UNREGISTERED_SOURCE = {
    "state": "unavailable", "reason": "no_project_repository",
    "repository": None, "repositoryPath": None, "sourceDigest": None,
    "normalizedDigest": None, "evidenceIdentity": None, "evidenceKind": "none",
}


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError("registered Doc IR transition: " + message)


def _reject_admonitions(value: object) -> None:
    if isinstance(value, list):
        for child in value:
            _reject_admonitions(child)
    elif isinstance(value, dict):
        _require(not (value.get("kind") == "admonition" and
                      isinstance(value.get("children"), list)),
                 "authored admonitions are not default fields")
        for child in value.values():
            _reject_admonitions(child)


def _baseline_document(document: dict) -> None:
    _require(document.get("schemaVersion") == "cjdoc.doc-ir/17", "baseline must be exactly v17")
    _reject_admonitions(document)
    for module in document["modules"]:
        _require("repositoryPath" in module and module["repositoryPath"] is None,
                 "baseline module repositoryPath must be present and null")
    for file in document["files"]:
        _require("provenance" not in file, "baseline unexpectedly contains file provenance")
    for declaration in document["declarations"]:
        comment = declaration.get("documentation")
        if comment is None:
            continue
        _require("localizationScope" not in comment, "baseline already contains localization scope")
        for tag in comment["tags"]:
            _require("entryId" not in tag and "source" not in tag,
                     "baseline already contains prompt tag fields")
        for text in comment.get("localizedTexts", []):
            _require("entryId" not in text, "baseline already contains prompt text identity")


def register_ir_transition(path: Path, expected_sha256: str) -> dict:
    encoded = path.read_bytes()
    _require(hashlib.sha256(encoded).hexdigest() == expected_sha256,
             "baseline raw Doc IR disagrees with its capture receipt")
    document = strict_loads(encoded, description="baseline native Doc IR")
    return register_ir_observation(document, expected_sha256)


def register_ir_observation(document: dict, observed_sha256: str) -> dict:
    """Bind a model already parsed from independently hash-verified bytes."""
    _baseline_document(document)
    return {"name": TRANSITION_NAME, "baselineDocIrSha256": observed_sha256,
            "baselineGenerator": deepcopy(document["generator"])}


def compare_ir_transition(before: dict, after: dict, registration: dict,
                          baseline_sha256: str) -> None:
    _require(set(registration) == {"name", "baselineDocIrSha256", "baselineGenerator"},
             "unexpected registration fields")
    _require(registration["name"] == TRANSITION_NAME, "unsupported transition name")
    _require(registration["baselineDocIrSha256"] == baseline_sha256,
             "baseline raw identity differs from registration")
    _baseline_document(before)
    _require(before["generator"] == registration["baselineGenerator"],
             "baseline generator differs from registration")
    _require(after.get("schemaVersion") == "cjdoc.doc-ir/18", "after must be exactly v18")
    _reject_admonitions(after)
    old, new = deepcopy(before), deepcopy(after)
    for module in old["modules"]:
        del module["repositoryPath"]
    for module in new["modules"]:
        _require("repositoryPath" not in module, "after retains an obsolete module field")
    for file in new["files"]:
        _require(file.get("provenance") == UNREGISTERED_SOURCE,
                 "after provenance is not the exact unavailable/no_project_repository default")
        del file["provenance"]
    for declaration in new["declarations"]:
        comment = declaration.get("documentation")
        if comment is None:
            continue
        _require(comment.get("localizationScope") == "all", "after comment has a nondefault scope")
        del comment["localizationScope"]
        for tag in comment["tags"]:
            _require("entryId" in tag and tag["entryId"] is None and
                     "source" in tag and tag["source"] is None,
                     "after tag has missing or nondefault prompt identity/source")
            del tag["entryId"]
            del tag["source"]
        for text in comment.get("localizedTexts", []):
            _require("entryId" in text and text["entryId"] is None,
                     "after localized text has missing or nondefault prompt identity")
            del text["entryId"]
    new["schemaVersion"] = old["schemaVersion"]
    _require(old == new, "original fields changed beyond the exact registered defaults")
