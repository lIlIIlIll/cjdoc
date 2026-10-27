#!/usr/bin/env python3
"""Bind supplied engineering thresholds to actual baseline receipts, without reading after evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
from copy import deepcopy
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .reader_benchmark import file_digest
    from .strict_json import strict_load, strict_dumps
except ImportError:
    from reader_benchmark import file_digest
    from strict_json import strict_load, strict_dumps


def register(baseline: Path, template: Path, presentation: Path | None = None) -> dict:
    budget = deepcopy(strict_load(template))
    if budget.get("schemaVersion") != "cjdoc.reader-budgets/1" or "baseline" in budget:
        raise ValueError("an unbound cjdoc.reader-budgets/1 template is required")
    if type(budget.get("minimumSamples")) is not int or budget["minimumSamples"] < 20:
        raise ValueError("registered percentiles require at least 20 raw samples")
    if presentation is not None:
        profile = strict_load(presentation)
        if profile.get("schemaVersion") != "cjdoc.reader-presentation/1":
            raise ValueError("unsupported presentation profile")
        encoded = json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        budget["presentation"] = {"sha256": hashlib.sha256(encoded).hexdigest(),
                                  "fileSha256": file_digest(presentation), "profile": profile}
    receipt = baseline / "reader-generation.json"
    native = strict_load(receipt)
    if native.get("label") != "baseline" or native.get("status") not in {"measured", "resource-limited"}:
        raise ValueError("baseline must be a completed native observation or an explicit resource rejection")
    browser_hashes, failure_sets = {}, []
    for locale in native["locales"]:
        browser_file = baseline / locale["browserReport"]
        browser = strict_load(browser_file)
        if browser["failures"]:
            raise ValueError("instrumentation failure cannot become a registered baseline")
        browser_hashes[locale["locale"]] = file_digest(browser_file)
        for transport in browser["transports"]:
            failure_sets.append(sorted(row["id"] for row in transport["queries"] if row["pass"] is not True))
    if failure_sets and any(items != failure_sets[0] for items in failure_sets):
        raise ValueError("baseline query failures disagree across languages or transports")
    budget["baselineQueryFailures"] = failure_sets[0] if failure_sets else []
    budget["baseline"] = {"generationSha256": file_digest(receipt), "browserSha256": browser_hashes,
                          "rendererRevision": native["rendererRevision"], "sourceSha256": native["sourceSha256"],
                          "status": native["status"]}
    return budget


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--presentation", type=Path, help="expected presentation changes, frozen before after capture")
    args = parser.parse_args()
    result = register(args.baseline, args.template, args.presentation)
    with args.output.open("x", encoding="utf-8") as output:
        output.write(strict_dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(strict_dumps({"status": result["baseline"]["status"],
                       "baselineGenerationSha256": result["baseline"]["generationSha256"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
