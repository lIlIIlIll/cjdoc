#!/usr/bin/env python3
"""Compare native reader observations against an explicitly registered baseline and budget."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_load, strict_dumps
except ImportError:
    from strict_json import strict_load, strict_dumps


class EvidenceError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(value: object, label: str) -> float:
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0,
            f"{label}: missing, negative, or non-finite measurement")
    return float(value)


def p95(metric: dict, minimum: int, label: str) -> float:
    samples = metric.get("samples", [])
    require(isinstance(samples, list) and len(samples) >= minimum, f"{label}: insufficient raw samples")
    values = sorted(number(value, label) for value in samples)
    result = values[math.ceil(.95 * len(values)) - 1]
    require(number(metric.get("p95Ms"), label) == result, f"{label}: P95 disagrees with raw samples")
    require(number(metric.get("p50Ms"), label) == values[math.ceil(.5 * len(values)) - 1],
            f"{label}: P50 disagrees with raw samples")
    return result


def keyed(rows: list[dict], field: str, label: str) -> dict:
    require(isinstance(rows, list), f"{label}: expected a list")
    result = {row[field]: row for row in rows}
    require(len(result) == len(rows), f"{label}: duplicate {field}")
    return result


def bounded(label: str, before: float, after: float, absolute: float, relative: dict,
            failures: list[str]) -> dict:
    ceiling = max(before * number(relative["factor"], label), before + number(relative["slack"], label))
    if after > absolute:
        failures.append(f"{label}: {after:g} exceeds absolute budget {absolute:g}")
    if after > ceiling:
        failures.append(f"{label}: {after:g} exceeds preregistered paired ceiling {ceiling:g}")
    return {"metric": label, "baseline": before, "after": after,
            "absoluteCeiling": absolute, "pairedCeiling": ceiling}


def task_metrics(before: list[dict], after: list[dict], tasks: list[dict], budgets: dict,
                 label: str, failures: list[str]) -> list[dict]:
    old = keyed(before, "id", label + "/baseline")
    new = keyed(after, "id", label + "/after")
    expected = {task["id"] for task in tasks}
    require(set(old) == set(new) == expected, f"{label}: missing or unexpected task")
    measurements = []
    for identifier in sorted(expected):
        a, b = old[identifier], new[identifier]
        require(a.get("expectedIds", a.get("expectedId")) == b.get("expectedIds", b.get("expectedId")),
                f"{label}/{identifier}: native target identity changed")
        if "first20Hrefs" in a:
            require(a["first20Hrefs"] == b.get("first20Hrefs"), f"{label}/{identifier}: first-20 ranking changed")
        if b.get("pass") is not True:
            failures.append(f"{label}/{identifier}: reader task failed")
        for name in ("synchronous", "frame"):
            require(len(a[name]["samples"]) == len(b[name]["samples"]), f"{label}: sample count changed")
            metric = label.split("/")[-1] + ("SyncP95Ms" if name == "synchronous" else "FrameP95Ms")
            measurements.append(bounded(f"{label}/{identifier}/{name}",
                p95(a[name], budgets["minimumSamples"], label),
                p95(b[name], budgets["minimumSamples"], label),
                number(budgets["absolute"][metric], metric), budgets["relative"]["latency"], failures))
        if label.endswith("/member"):
            measurements.append(bounded(f"{label}/{identifier}/heap",
                number(a["finalLayout"]["jsHeapUsedBytes"], label), number(b["finalLayout"]["jsHeapUsedBytes"], label),
                number(budgets["absolute"]["memberHeapBytes"], label), budgets["relative"]["memory"], failures))
            old_dom = number(a["finalLayout"]["domNodes"], label)
            new_dom = number(b["finalLayout"]["domNodes"], label)
            if new_dom > budgets["absolute"]["memberDomNodes"] or new_dom > old_dom + budgets["relative"]["domGrowthNodes"]:
                failures.append(f"{label}/{identifier}: member DOM budget exceeded")
    return measurements


def check_overloads(before: list[dict], after: list[dict], tasks: list[dict], label: str,
                    failures: list[str]) -> None:
    old, new = keyed(before, "id", label), keyed(after, "id", label)
    require(set(old) == set(new) == {task["id"] for task in tasks}, f"{label}: overload task set changed")
    for identifier, row in new.items():
        previous = old[identifier]
        require([item.get("expectedId") for item in row["selections"]] ==
                [item.get("expectedId") for item in previous["selections"]], f"{label}: overload identities changed")
        require(row["comparison"]["details"] == previous["comparison"]["details"],
                f"{label}: original signatures or author contract changed")
        if row.get("pass") is not True:
            failures.append(f"{label}/{identifier}: native selection, multi-open, or history failed")


def presentation_profile(budgets: dict) -> dict | None:
    registration = budgets.get("presentation")
    if registration is None:
        return None
    profile = registration["profile"]
    encoded = json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(hashlib.sha256(encoded).hexdigest() == registration["sha256"], "presentation registration changed")
    require(profile["schemaVersion"] == "cjdoc.reader-presentation/1", "unsupported presentation profile")
    return profile


def check_font_usage(before: dict, after: dict, profile: dict | None) -> None:
    if profile is None:
        require(before.get("fontUsage") == after.get("fontUsage"), "used font identities changed")
        return
    locale = after["environment"]["requestedUiLocale"]
    require(before["recipe"] == after["recipe"] == profile["recipe"], "presentation corpus recipe changed")
    inventory = keyed(before["environment"]["fontFiles"], "family", "installed fonts")
    for label, report in (("baseline", before), ("after", after)):
        usage = report.get("fontUsage")
        require(isinstance(usage, list) and bool(usage), "actual font usage is missing")
        require([font["family"] for font in usage] == profile["locales"][locale][label]["fontFamilies"],
                f"{label}: unregistered font usage")
        require(all(font == inventory.get(font["family"]) for font in usage), "used font file differs from installed inventory")


def check_native_ir(baseline: Path, after: Path, old: dict, new: dict, profile: dict | None) -> None:
    documents = []
    for root, receipt in ((baseline, old), (after, new)):
        path = root / "native-json/docs.json"
        require(digest(path) == receipt["nativeResult"]["docIrSha256"], "native Doc IR receipt hash mismatch")
        documents.append(strict_load(path))
    if old["nativeResult"]["docIrSha256"] == new["nativeResult"]["docIrSha256"]:
        return
    require(profile is not None, "native Doc IR changed; author input was not preserved")
    for label, document in zip(("baseline", "after"), documents):
        require(document["generator"]["version"] == profile["generatorVersions"][label],
                "unregistered generator version")
        # Only this provenance field may differ; every native declaration,
        # contract, signature, diagnostic and source range still compares exactly.
        document["generator"]["version"] = "<registered-generator-version>"
    require(documents[0] == documents[1], "native Doc IR changed beyond registered generator provenance")


def check_visuals(before: dict, after: dict, required: bool, failures: list[str],
                  profile: dict | None = None) -> None:
    def key(row: dict) -> str:
        return json.dumps([row["viewport"], row["theme"], row["target"], row["locale"]], sort_keys=True)
    old, new = {key(row): row for row in before["visuals"]}, {key(row): row for row in after["visuals"]}
    require(len(old) == len(before["visuals"]) and len(new) == len(after["visuals"]), "duplicate visual task")
    require(set(old) == set(new) and (not required or len(new) > 0), "missing paired visual evidence")
    for identifier, row in new.items():
        if number(row["metrics"]["horizontalOverflowPx"], identifier) > 1:
            failures.append(f"visual {identifier}: page overflow")
        if row["focus"]["positiveTabindex"] or row["focus"]["mainLandmark"] != 1 or row["focus"]["headingCount"] != 1:
            failures.append(f"visual {identifier}: landmark or tabindex regression")
        if profile is None:
            require(row["metrics"]["typography"] == old[identifier]["metrics"]["typography"],
                    f"visual {identifier}: body typography changed")
        else:
            for label, observation in (("baseline", old[identifier]), ("after", row)):
                require(observation["metrics"]["typography"] == profile["typography"][label],
                        f"visual {identifier}: unregistered {label} body typography")
    a, b = before["accessibility"], after["accessibility"]
    require(a["screenReaderSpeech"] == b["screenReaderSpeech"], "screen-reader evidence boundary changed")
    if a.get("status") != "not-applicable":
        if profile is None:
            require(a["noScript"]["accessibleTree"] == b["noScript"]["accessibleTree"], "no-JS accessible tree changed")
        else:
            locale = after["environment"]["requestedUiLocale"]
            for label, observation in (("baseline", a), ("after", b)):
                tree_hash = hashlib.sha256(observation["noScript"]["accessibleTree"].encode()).hexdigest()
                require(tree_hash == profile["locales"][locale][label]["noScriptTreeSha256"],
                        f"{label}: unregistered no-JS accessible tree")
        if b["noScript"]["independentlyOpen"] is not True or not b["print"]["contentVisible"] or b["print"]["overflowPx"] > 1:
            failures.append("no-JS multi-open or print visibility/overflow regression")
        require(a["print"]["signatures"] == b["print"]["signatures"] and
                a["print"]["detailBodies"] == b["print"]["detailBodies"], "print omitted signatures or detail bodies")
        for key in ("visibleSignatureIds", "visibleDetailIds"):
            require(isinstance(a["print"].get(key), list) and
                    a["print"][key] == b["print"].get(key), "print changed visible native member identities")
        for observation in (a, b):
            guards = observation.get("printCounterexamples", [])
            require(len(guards) == 3 and all(row.get("detected") is True for row in guards),
                    "missing actual print visibility counterexamples")


def compare_browser(before: dict, after: dict, manifest: dict, budgets: dict,
                    failures: list[str]) -> list[dict]:
    for key in ("schemaVersion", "recipe", "sourceSha256", "taskManifestSha256", "harness", "environment", "nativeIndexEntries"):
        require(before.get(key) == after.get(key) and before.get(key) is not None, f"browser {key} changed or missing")
    require(before.get("harness") and before["environment"].get("fontFiles"), "missing harness or font identities")
    require(all(font.get("status") == "measured" for font in before["environment"]["fontFiles"]), "font file identity unavailable")
    profile = presentation_profile(budgets)
    check_font_usage(before, after, profile)
    require(not before["failures"] and not after["failures"], "browser instrumentation failed")
    for name in ("search-index.json", "search-index.js"):
        require(before["resources"][name]["sha256"] == after["resources"][name]["sha256"],
                f"{name}: index/body/identity payload changed; not a same-input UI comparison")
    old, new = keyed(before["transports"], "transport", "transport"), keyed(after["transports"], "transport", "transport")
    require(set(old) == set(new) == set(budgets["transports"]), "missing or unexpected transport")
    measurements = []
    for transport in budgets["transports"]:
        a, b = old[transport], new[transport]
        measured_failures = sorted(row["id"] for row in a["queries"] if row.get("pass") is not True)
        require(measured_failures == sorted(budgets["baselineQueryFailures"]), "baseline query failures differ from registration")
        measurements += task_metrics(a["queries"], b["queries"], manifest["queries"], budgets, transport + "/query", failures)
        measurements += task_metrics(a["members"], b["members"], manifest["members"], budgets, transport + "/member", failures)
        check_overloads(a["overloads"], b["overloads"], manifest["overloads"], transport, failures)
        for state in ("cold", "warm"):
            metric = state + "InteractiveMs"
            measurements.append(bounded(transport + "/" + metric,
                number(a["loading"][state]["firstInteractiveProbeMs"], metric),
                number(b["loading"][state]["firstInteractiveProbeMs"], metric),
                number(budgets["absolute"][metric], metric), budgets["relative"]["loading"], failures))
        measurements.append(bounded(transport + "/queryHeapBytes",
            number(a["queryLayout"]["jsHeapUsedBytes"], "heap"), number(b["queryLayout"]["jsHeapUsedBytes"], "heap"),
            number(budgets["absolute"]["queryHeapBytes"], "heap"), budgets["relative"]["memory"], failures))
    for name, size in after["resources"].items():
        measurements.append(bounded(name + "/bytes", number(before["resources"][name]["bytes"], name),
            number(size["bytes"], name), number(budgets["absolute"]["bundleFileBytes"], name),
            budgets["relative"]["bundle"], failures))
    check_visuals(before, after, budgets["requireScreenshots"], failures, profile)
    return measurements


def compare(baseline: Path, after: Path, manifest_file: Path, budget_file: Path) -> dict:
    manifest, budgets = strict_load(manifest_file), strict_load(budget_file)
    require(budgets["schemaVersion"] == "cjdoc.reader-budgets/1", "unsupported registered budget")
    require(type(budgets["minimumSamples"]) is int and budgets["minimumSamples"] >= 20, "budget requires at least 20 samples")
    old_file, new_file = baseline / "reader-generation.json", after / "reader-generation.json"
    old, new = strict_load(old_file), strict_load(new_file)
    require(digest(old_file) == budgets["baseline"]["generationSha256"], "baseline generation receipt is not the registered observation")
    require(old["label"] == "baseline" and new["label"] == "after", "incorrect pair labels")
    require(old["schemaVersion"] == new["schemaVersion"] == "cjdoc.reader-generation/1", "unsupported native receipt")
    for name in ("recipe", "sourceSha256", "taskManifestSha256", "configuration", "sources"):
        require(old[name] == new[name], f"native {name} changed")
    require(digest(manifest_file) == old["taskManifestSha256"], "manifest differs from measured input")
    for name in ("CJDOC_TOOLCHAIN_FINGERPRINT", "CJDOC_STDX_DIGEST", "CJDOC_TOOLCHAIN_VERSION", "CJDOC_TOOLCHAIN_TARGET"):
        require(old["toolchain"][name] and old["toolchain"][name] == new["toolchain"][name], f"toolchain {name} changed")
    for name in ("cjc", "cjpm"):
        for key in ("version", "sha256"):
            require(old["toolchain"][name][key] and old["toolchain"][name][key] == new["toolchain"][name][key], f"{name} {key} changed")
    if old["status"] == "resource-limited" or new["status"] == "resource-limited":
        return {"schemaVersion": "cjdoc.reader-comparison/1", "status": "resource-limited", "pass": False,
                "baselineReason": old.get("reason"), "afterReason": new.get("reason"), "measurements": [],
                "semantics": "unsupported scale is not PASS; no missing browser metrics are synthesized"}
    require(old["status"] == new["status"] == "measured", "native pipeline did not complete")
    check_native_ir(baseline, after, old, new, presentation_profile(budgets))
    require(old["nativeResult"]["status"] == new["nativeResult"]["status"], "native uncertainty status changed")
    failures, measurements = [], []
    require([item["locale"] for item in old["locales"]] == [item["locale"] for item in new["locales"]], "locale set changed")
    for a, b in zip(old["locales"], new["locales"]):
        old_browser, new_browser = baseline / a["browserReport"], after / b["browserReport"]
        require(digest(old_browser) == budgets["baseline"]["browserSha256"][a["locale"]], "unregistered browser baseline")
        measurements += compare_browser(strict_load(old_browser), strict_load(new_browser), manifest, budgets, failures)
    return {"schemaVersion": "cjdoc.reader-comparison/1", "status": "failed" if failures else "pass",
            "pass": not failures, "failures": failures, "measurements": measurements,
            "baselineGenerationSha256": digest(old_file), "afterGenerationSha256": digest(new_file),
            "budgetSha256": digest(budget_file), "baselineRevision": old["rendererRevision"], "afterRevision": new["rendererRevision"],
            "semantics": "paired engineering gates, not human timing, screen-reader speech, or portable hardware scores"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "after", "manifest", "budgets", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    try:
        result = compare(args.baseline, args.after, args.manifest, args.budgets)
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {"schemaVersion": "cjdoc.reader-comparison/1", "status": "invalid-evidence", "pass": False,
                  "reason": str(error).replace(str(Path.home()), "$HOME")}
    args.output.write_text(strict_dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(strict_dumps({"status": result["status"], "pass": result["pass"]}))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
