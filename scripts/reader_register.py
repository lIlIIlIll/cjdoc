#!/usr/bin/env python3
"""Bind supplied thresholds and exact transitions before reading after evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
from copy import deepcopy
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .reader_aria_transition import register_aria_transition
    from .reader_ir_transition import TRANSITION_NAME, register_ir_observation, register_ir_transition
    from .reader_search_identity import verify_search_identity
    from .strict_json import strict_dumps, strict_loads
    from .test_agent_artifacts import document
except ImportError:
    from reader_aria_transition import register_aria_transition
    from reader_ir_transition import TRANSITION_NAME, register_ir_observation, register_ir_transition
    from reader_search_identity import verify_search_identity
    from strict_json import strict_dumps, strict_loads
    from test_agent_artifacts import document

REPO = Path(__file__).resolve().parent.parent
REFERENCE_TEMPLATE = REPO / "docs/maintainer/reader-scale-budgets.json"
REGISTRATION_FIELDS = {"baseline", "baselineQueryFailures", "presentation", "docIrTransition",
                       "ariaTransition", "transitionTemplate"}


def validate_transition_budget(budget: dict, reference: Path) -> None:
    if "docIrTransition" not in budget and "ariaTransition" not in budget:
        return
    if "presentation" in budget:
        raise ValueError("exact IR/ARIA transitions cannot waive presentation or font equality")
    encoded = reference.read_bytes()
    registration = budget.get("transitionTemplate", {})
    if set(registration) != {"sha256"} or registration["sha256"] != hashlib.sha256(encoded).hexdigest():
        raise ValueError("transition threshold template changed after registration")
    core = {key: value for key, value in budget.items() if key not in REGISTRATION_FIELDS}
    if core != strict_loads(encoded, description="committed Reader threshold template"):
        raise ValueError("registered transition cannot modify the fixed Reader budgets")


def register(baseline: Path, template: Path, presentation: Path | None = None, *,
             doc_ir_transition: str | None = None, aria_transition: Path | None = None) -> dict:
    budget = deepcopy(strict_loads(template.read_bytes(), description="Reader budget template"))
    if budget.get("schemaVersion") != "cjdoc.reader-budgets/1" or "baseline" in budget:
        raise ValueError("an unbound cjdoc.reader-budgets/1 template is required")
    if type(budget.get("minimumSamples")) is not int or budget["minimumSamples"] < 20:
        raise ValueError("registered percentiles require at least 20 raw samples")
    has_transition = doc_ir_transition is not None or aria_transition is not None
    if has_transition:
        if presentation is not None:
            raise ValueError("exact transitions cannot be combined with a presentation exemption")
        reference_bytes = REFERENCE_TEMPLATE.read_bytes()
        if budget != strict_loads(reference_bytes, description="committed Reader threshold template"):
            raise ValueError("exact transitions require unchanged committed Reader budgets")
        budget["transitionTemplate"] = {"sha256": hashlib.sha256(reference_bytes).hexdigest()}
    if presentation is not None:
        profile_bytes = presentation.read_bytes()
        profile = strict_loads(profile_bytes, description="presentation profile")
        if profile.get("schemaVersion") != "cjdoc.reader-presentation/1":
            raise ValueError("unsupported presentation profile")
        encoded = json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        budget["presentation"] = {"sha256": hashlib.sha256(encoded).hexdigest(),
                                  "fileSha256": hashlib.sha256(profile_bytes).hexdigest(), "profile": profile}
    receipt = baseline / "reader-generation.json"
    native_bytes = receipt.read_bytes()
    native = strict_loads(native_bytes, description="baseline native observation")
    if native.get("label") != "baseline" or native.get("status") not in {"measured", "resource-limited"}:
        raise ValueError("baseline must be a completed native observation or an explicit resource rejection")
    if has_transition and native["status"] != "measured":
        raise ValueError("transitions require complete observations; resource-limited is not PASS")
    if doc_ir_transition is not None:
        if doc_ir_transition != TRANSITION_NAME:
            raise ValueError("unsupported Doc IR transition")
        native_registration = register_ir_transition(baseline / "native-json/docs.json",
                                                      native["nativeResult"]["docIrSha256"])
        budget["docIrTransition"] = {"name": TRANSITION_NAME, "native": native_registration, "published": {}}
    browser_hashes, failure_sets = {}, []
    for locale in native["locales"]:
        browser_file = document(baseline, locale["browserReport"])
        browser_bytes = browser_file.read_bytes()
        browser = strict_loads(browser_bytes, description="baseline browser observation")
        if browser["failures"]:
            raise ValueError("instrumentation failure cannot become a registered baseline")
        browser_hashes[locale["locale"]] = hashlib.sha256(browser_bytes).hexdigest()
        for transport in browser["transports"]:
            failure_sets.append(sorted(row["id"] for row in transport["queries"] if row["pass"] is not True))
        if doc_ir_transition is not None:
            site = document(baseline, locale["site"] + "/search-index.json").parent
            proof = verify_search_identity(site, browser["resources"], REPO / "docs/schema")
            budget["docIrTransition"]["published"][locale["locale"]] = register_ir_observation(
                proof["docIr"], proof["docIrSha256"])
    if failure_sets and any(items != failure_sets[0] for items in failure_sets):
        raise ValueError("baseline query failures disagree across languages or transports")
    budget["baselineQueryFailures"] = failure_sets[0] if failure_sets else []
    budget["baseline"] = {"generationSha256": hashlib.sha256(native_bytes).hexdigest(),
                          "browserSha256": browser_hashes, "rendererRevision": native["rendererRevision"],
                          "sourceSha256": native["sourceSha256"], "status": native["status"]}
    if aria_transition is not None:
        budget["ariaTransition"] = register_aria_transition(aria_transition, baseline, native, REPO)
    validate_transition_budget(budget, REFERENCE_TEMPLATE)
    return budget


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--presentation", type=Path, help="expected presentation changes, frozen before after capture")
    parser.add_argument("--doc-ir-transition", choices=[TRANSITION_NAME])
    parser.add_argument("--aria-transition", type=Path, help="exact complete ARIA snapshots, frozen before after capture")
    args = parser.parse_args()
    result = register(args.baseline, args.template, args.presentation,
                      doc_ir_transition=args.doc_ir_transition, aria_transition=args.aria_transition)
    with args.output.open("x", encoding="utf-8") as output:
        output.write(strict_dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(strict_dumps({"status": result["baseline"]["status"],
                       "baselineGenerationSha256": result["baseline"]["generationSha256"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
