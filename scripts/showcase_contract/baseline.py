"""Enforce the reviewed showcase scope, independently of browser execution.

The first baseline records the scope promised for issue #50 in this change. It
is not an earlier release manifest and does not claim any scenario has passed.
Only an explicit source review may change it; builds never create or update it.
"""
from __future__ import annotations

import re

from .contract import (
    DEMONSTRATIONS, IMPLEMENTATIONS, array, fields, identifier, text,
    validate_manifest,
)
from .site import ContractError

BASELINE_SCHEMA = "cjdoc.showcase-baseline/1"
SCOPE_BASIS = "issue-50-promised-scope"
TRANSPORT_MODES = {"root": "http", "subpath": "http", "offline": "file"}
VIEWPORTS = {"desktop", "narrow", "mobile"}


def unique_strings(value: object, label: str) -> list[str]:
    values = array(value, label, nonempty=True)
    seen = set()
    for item in values:
        text(item, label)
        if item in seen:
            raise ContractError(f"duplicate {label}: {item}")
        seen.add(item)
    return values


def validate_baseline(baseline: object) -> dict:
    baseline = fields(baseline, {"schemaVersion", "basis", "issue", "executionEvidence",
                                 "locales", "transports", "viewports", "features"}, set(), "baseline")
    if baseline["schemaVersion"] != BASELINE_SCHEMA:
        raise ContractError("unsupported showcase baseline schema")
    if baseline["basis"] != SCOPE_BASIS or type(baseline["issue"]) is not int or baseline["issue"] != 50:
        raise ContractError("baseline must identify the reviewed issue #50 scope")
    if baseline["executionEvidence"] != "none; browser evidence is required separately":
        raise ContractError("a scope baseline cannot claim browser execution evidence")
    for locale in unique_strings(baseline["locales"], "baseline locale"):
        if not re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", locale):
            raise ContractError("baseline locale must be an explicit HTML language tag")
    if set(unique_strings(baseline["transports"], "baseline transport")) != TRANSPORT_MODES.keys():
        raise ContractError("baseline requires root, subpath and offline transports")
    if set(unique_strings(baseline["viewports"], "baseline viewport")) != VIEWPORTS:
        raise ContractError("baseline requires desktop, narrow and mobile viewports")
    feature_ids = set()
    for feature in array(baseline["features"], "baseline features", nonempty=True):
        fields(feature, {"id", "implementation", "demonstration", "journey", "targets"}, set(), "baseline feature")
        fid = identifier(feature["id"], "baseline feature id")
        if fid in feature_ids:
            raise ContractError(f"duplicate baseline feature: {fid}")
        feature_ids.add(fid)
        for key, choices in (("implementation", IMPLEMENTATIONS), ("demonstration", DEMONSTRATIONS)):
            if not isinstance(feature[key], str) or feature[key] not in choices:
                raise ContractError(f"invalid baseline {key}: {fid}")
        identifier(feature["journey"], "baseline journey")
        available = feature["demonstration"] == "available"
        if available and feature["implementation"] == "not-implemented":
            raise ContractError("unimplemented baseline capability cannot be available")
        targets = array(feature["targets"], "baseline targets", nonempty=available)
        if not available and targets:
            raise ContractError("unavailable baseline capabilities must have no promised targets")
        seen = set()
        for target in targets:
            fields(target, {"id", "version"}, set(), "baseline target")
            tid = identifier(target["id"], "baseline target id")
            text(target["version"], "baseline target version")
            if tid in seen:
                raise ContractError(f"duplicate baseline target: {fid}/{tid}")
            seen.add(tid)
            for locale in baseline["locales"]:
                identifier(tid + "-" + locale, "expanded baseline target id")
    return baseline


def check_baseline(baseline: dict, manifest: dict) -> None:
    """Reject scope changes until the committed baseline is explicitly reviewed.

    The matrix expands scenario identities only. Routes and SymbolIds still
    come exclusively from the native output resolver, never from this baseline.
    Exact comparison also exposes upgrades and additions for scope review; it
    does not silently certify a new claim or hide an unavailable capability.
    """
    validate_baseline(baseline)
    validate_manifest(manifest)
    actual = {feature["id"]: feature for feature in manifest["features"]}
    expected_ids = {feature["id"] for feature in baseline["features"]}
    if set(actual) != expected_ids:
        raise ContractError("showcase baseline feature scope changed: "
                            f"missing={sorted(expected_ids - actual.keys())}, "
                            f"unexpected={sorted(actual.keys() - expected_ids)}")
    for expected in baseline["features"]:
        fid = expected["id"]
        current = actual[fid]
        for state in ("implementation", "demonstration"):
            if current[state] != expected[state]:
                raise ContractError(f"showcase baseline {state} changed: {fid}")
        promised = {(target["id"] + "-" + locale, locale, target["version"])
                    for target in expected["targets"] for locale in baseline["locales"]}
        current_targets = {(target["id"], target["locale"], target["version"]): target
                           for target in current["targets"]}
        if set(current_targets) != promised:
            raise ContractError(f"showcase baseline target/locale/version scope changed: {fid}")
        scenarios = {(expected["journey"] + "-" + transport + "-" + viewport, TRANSPORT_MODES[transport])
                     for transport in baseline["transports"] for viewport in baseline["viewports"]}
        for key, target in current_targets.items():
            actual_scenarios = {(scenario["id"], scenario["mode"]) for scenario in target["scenarios"]}
            if actual_scenarios != scenarios:
                raise ContractError(f"showcase baseline scenario scope changed: {fid}/{key[0]}")
