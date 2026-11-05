"""Freeze complete expected accessible trees without waiving typography or tasks."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_load, strict_loads
    from .test_agent_artifacts import document
except ImportError:
    from strict_json import strict_load, strict_loads
    from test_agent_artifacts import document

SCHEMA = "cjdoc.reader-aria-transition/1"
PROFILE_FIELDS = {"schemaVersion", "recipe", "sourceSha256", "taskManifestSha256", "locales"}


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError("registered ARIA transition: " + message)


def _profile_digest(profile: dict) -> str:
    encoded = json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _validate_profile(profile: dict) -> None:
    _require(set(profile) == PROFILE_FIELDS and profile["schemaVersion"] == SCHEMA,
             "unsupported or incomplete profile")
    for name in ("sourceSha256", "taskManifestSha256"):
        _require(isinstance(profile[name], str) and re.fullmatch(r"[0-9a-f]{64}", profile[name]) is not None,
                 "invalid corpus digest: " + name)
    _require(isinstance(profile["recipe"], str) and bool(profile["recipe"]), "missing corpus recipe")
    _require(set(profile["locales"]) == {"en", "zh-CN"}, "complete bilingual snapshots are required")
    for observations in profile["locales"].values():
        _require(set(observations) == {"baseline", "after"}, "both full snapshots are required")
        for record in observations.values():
            _require(set(record) == {"snapshot", "sha256"}, "unexpected snapshot record")
            _require(isinstance(record["sha256"], str) and
                     re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is not None,
                     "invalid snapshot digest")


def _check_corpus(profile: dict, observation: dict) -> None:
    for name in ("recipe", "sourceSha256", "taskManifestSha256"):
        _require(profile[name] == observation[name], "different corpus or task selection: " + name)


def register_aria_transition(profile_file: Path, baseline: Path, native: dict,
                             snapshot_root: Path) -> dict:
    profile_bytes = profile_file.read_bytes()
    profile = strict_loads(profile_bytes, description="ARIA transition profile")
    _validate_profile(profile)
    _check_corpus(profile, native)
    _require({row["locale"] for row in native["locales"]} == set(profile["locales"]),
             "baseline locale set differs from the profile")
    snapshots = {}
    for locale, observations in profile["locales"].items():
        snapshots[locale] = {}
        for label, record in observations.items():
            encoded = document(snapshot_root, record["snapshot"]).read_bytes()
            _require(hashlib.sha256(encoded).hexdigest() == record["sha256"],
                     "full snapshot file digest differs: " + locale + "/" + label)
            snapshots[locale][label] = encoded.decode("utf-8")
        locale_record = next(row for row in native["locales"] if row["locale"] == locale)
        browser = strict_load(document(baseline, locale_record["browserReport"]))
        _check_corpus(profile, browser)
        _require(browser["environment"]["requestedUiLocale"] == locale, "baseline browser locale differs")
        _require(browser["accessibility"]["noScript"]["accessibleTree"] == snapshots[locale]["baseline"],
                 "baseline accessible tree is not the registered complete snapshot")
    return {"profile": profile, "sha256": _profile_digest(profile),
            "fileSha256": hashlib.sha256(profile_bytes).hexdigest(), "snapshots": snapshots}


def validate_aria_registration(registration: dict) -> dict:
    _require(set(registration) == {"profile", "sha256", "fileSha256", "snapshots"},
             "unexpected registration fields")
    profile = registration["profile"]
    _validate_profile(profile)
    _require(_profile_digest(profile) == registration["sha256"], "profile changed after registration")
    _require(set(registration["snapshots"]) == set(profile["locales"]), "registered locale set changed")
    for locale, observations in profile["locales"].items():
        _require(set(registration["snapshots"][locale]) == {"baseline", "after"},
                 "registered snapshot pair changed")
        for label, record in observations.items():
            text = registration["snapshots"][locale][label]
            _require(isinstance(text, str) and hashlib.sha256(text.encode("utf-8")).hexdigest() == record["sha256"],
                     "registered full snapshot changed: " + locale + "/" + label)
    return profile


def check_aria_pair(before: dict, after: dict, registration: dict) -> None:
    profile = validate_aria_registration(registration)
    for label, observation in (("baseline", before), ("after", after)):
        _check_corpus(profile, observation)
        locale = observation["environment"]["requestedUiLocale"]
        _require(locale in profile["locales"], "unregistered browser locale")
        _require(observation["accessibility"].get("status") != "not-applicable",
                 "actual no-JS accessible-tree observation is required")
        _require(observation["accessibility"]["noScript"]["accessibleTree"] ==
                 registration["snapshots"][locale][label],
                 "unregistered complete accessible-tree difference: " + locale + "/" + label)
