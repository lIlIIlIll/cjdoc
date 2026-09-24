"""Compile the maintained showcase catalog to the strict native-route contract."""
from __future__ import annotations

from copy import deepcopy
from pathlib import Path

from showcase_contract.contract import PLAN_SCHEMA, validate_plan
from showcase_contract.site import ContractError, load_json, relative_path

LOCALES = ("zh-CN", "en")
JOURNEYS = {"members", "types", "contracts", "resources", "guides", "search", "doctest",
            "diff", "versions", "quality", "external", "downloads", "machine", "diagnostics",
            "authoring", "extension"}
REPORTS = {"doctest", "diff", "coverage", "diagnostics"}


def roots(site: Path, locale: str) -> dict[str, Path]:
    composed = site / "examples" / locale
    manifest = load_json(composed / "versions.json")
    if manifest.get("schemaVersion") != "cjdoc.versions/1":
        raise ContractError("unsupported native version composition")
    result = {}
    for record in manifest["versions"]:
        version = record["id"]
        if version in result:
            raise ContractError("duplicate native version")
        result[version] = composed / relative_path(record["basePath"])
    if set(result) != {"demo-v1", "demo-v2"}:
        raise ContractError("showcase needs the same library's two native versions")
    result["diagnostics"] = site / "diagnostics" / locale
    return result


def select(ir: dict, specification: dict) -> dict:
    fields = {key: specification[key] for key in ("qualifiedName", "name", "packageName") if key in specification}
    if not fields.get("packageName") or not (fields.get("qualifiedName") or fields.get("name")):
        raise ContractError("catalog symbol selector must have an explicit package scope")
    candidates = [declaration for declaration in ir["declarations"]
                  if all(declaration.get(key) == value for key, value in fields.items())]
    if "signature" in specification:
        candidates = [declaration for declaration in candidates
                      if declaration["headerSpelling"] == specification["signature"]]
    if len(candidates) != 1:
        raise ContractError(f"catalog selector {fields} needs one declaration, got {len(candidates)}")
    return candidates[0]


def compile_plan(repo: Path, site: Path) -> dict:
    catalog = load_json(repo / "site/showcase-catalog.json")
    if catalog.get("schemaVersion") != "cjdoc.showcase-catalog/1":
        raise ContractError("unsupported maintained showcase catalog")
    plan = {"schemaVersion": PLAN_SCHEMA, "features": []}
    # Explicit, revision-controlled source inventory; derived indices are not source claims.
    inputs = ["site/showcase-catalog.json", "examples/pocketkit/LICENSE", "examples/pocketkit/reproduce.py"]
    for version in ("demo-v1", "demo-v2"):
        inputs += [f"examples/pocketkit/{version}/{path}" for path in
                   ("cjpm.toml", "cjdoc.toml", "src/catalog.cj", "src/io/reader.cj",
                    "src/parsing/parser.cj", "docs/index.md", "docs/guide.md")]
    inputs += [f"examples/pocketkit/{part}/{path}" for part in ("support-v1", "diagnostics")
               for path in ("cjpm.toml", "cjdoc.toml", "src/api.cj", "docs/index.md")]
    for source in catalog["features"]:
        feature = {key: deepcopy(source[key]) for key in
                   ("id", "title", "implementation", "demonstration", "reason")}
        feature.update(trackingIssues=[50], inputs=inputs, targets=[])
        if source["targets"] and source["journey"] not in JOURNEYS:
            raise ContractError("catalog contains an unsupported browser journey")
        for locale in LOCALES:
            documents = roots(site, locale)
            for specification in source["targets"]:
                target = {"id": specification["id"] + "-" + locale, "locale": locale,
                          "version": specification["version"], "instructions": source["instructions"],
                          "scenarios": [{"id": source["journey"] + "-" + transport + "-" + width,
                                         "mode": "file" if transport == "offline" else "http"}
                                        for transport in ("root", "subpath", "offline")
                                        for width in ("desktop", "narrow")]}
                if specification.get("download"):
                    target.update(kind="artifact", path=f"downloads/{locale}.html")
                else:
                    root = documents[specification["version"]]
                    relative = root.relative_to(site).as_posix()
                    if "report" in specification:
                        report = specification["report"]
                        if report not in REPORTS:
                            raise ContractError("unknown report presentation")
                        target.update(kind="artifact", path=f"{relative}/report-{report}.html")
                    else:
                        navigation = load_json(root / "navigation-index.json")
                        target.update(kind="navigation", index=f"{relative}/navigation-index.json",
                                      project=navigation["project"])
                        if "concept" in specification:
                            target["match"] = {"kind": "concept", "title": specification["concept"]}
                        else:
                            ir = load_json(root / "machine/docs.json")
                            declaration = select(ir, specification)
                            target.update(docIr=f"{relative}/machine/docs.json",
                                          signature=declaration["headerSpelling"],
                                          placement=specification.get("placement", "page"),
                                          match={"kind": "symbol", "title": declaration["qualifiedName"],
                                                 "packageName": declaration["packageName"]})
                feature["targets"].append(target)
        plan["features"].append(feature)
    return validate_plan(plan)
