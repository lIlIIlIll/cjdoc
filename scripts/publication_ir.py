"""Project complete author IR into audience-safe machine documentation."""
from __future__ import annotations

import copy
import hashlib


def _redact_reference_field_ids(declaration: dict, hidden: set[str]) -> None:
    comment = declaration.get("documentation")
    if not isinstance(comment, dict):
        return
    fields = comment.get("localizedTexts", []) + comment.get("tags", [])
    reserved = {field.get("fieldId", "") for field in fields}
    prefixes = {}
    # Reference targets can already be unavailable while their keys still embed
    # hidden SymbolIds. One mapping keeps language variants and projected tags paired.
    for field in fields:
        kind = field.get("kind", field.get("name"))
        if kind not in ("see", "throws"):
            continue
        prefix = f"{declaration['id']}:doc:{kind}:"
        identity = field.get("fieldId", "")
        if identity.startswith(prefix) and identity[len(prefix):] in hidden:
            prefixes[identity] = prefix
    replacements = {}
    for identity, prefix in sorted(prefixes.items()):
        base = prefix + "opaque:" + hashlib.sha256(identity.encode("utf-8")).hexdigest()
        candidate = base
        suffix = 0
        while candidate in reserved:
            suffix += 1
            candidate = f"{base}:{suffix}"
        reserved.add(candidate)
        replacements[identity] = candidate
    for field in fields:
        identity = field.get("fieldId", "")
        if identity in replacements:
            field["fieldId"] = replacements[identity]


def project(document: dict) -> dict:
    result = copy.deepcopy(document)
    declarations = {item["id"]: item for item in result["declarations"]}
    audience = result["configuration"]["audience"]
    if audience != "all":
        # Unbound author text has no declaration whose audience we can prove.
        for name in ("orphanDocComments", "unsupportedDeclarations", "macroInvocations", "unboundSemanticDeclarations"):
            if name in result:
                result[name] = []

    def directly_visible(item: dict) -> bool:
        visibility = item["visibility"]
        return (audience == "all" or
                audience == "external" and visibility in ("public", "protected") or
                audience == "package" and visibility != "private")

    def visible(item: dict, extensions: set[str] = frozenset()) -> bool:
        visited = set()
        while item:
            if item["id"] in visited or not (directly_visible(item) or item["id"] in extensions):
                return False
            visited.add(item["id"])
            item = declarations.get(item.get("ownerId"))
        return True

    members = {item.get("ownerId") for item in declarations.values() if directly_visible(item)}
    extensions = {item["id"] for item in declarations.values()
                  if item.get("kind") == "extend" and item["id"] in members
                  and any(relation["kind"] == "extensionTarget" and relation["state"] == "resolved"
                          and relation.get("targetSymbolId") in declarations
                          and visible(declarations[relation["targetSymbolId"]])
                          for relation in item.get("symbolRelationships", []))}
    kept = {key for key, value in declarations.items() if visible(value, extensions)}
    result["declarations"] = [value for key, value in declarations.items() if key in kept]
    if audience != "all":
        hidden = set(declarations) - kept
        for declaration in result["declarations"]:
            _redact_reference_field_ids(declaration, hidden)
    if "externalDocumentation" in result:
        result["externalDocumentation"] = [item for item in result["externalDocumentation"] if item["symbolId"] in kept]
    result["diagnostics"] = [item for item in result["diagnostics"]
                             if item.get("symbolId") is None or item["symbolId"] in kept]
    if audience != "all":
        for diagnostic in result["diagnostics"]:
            if diagnostic.get("symbolId") is None:
                diagnostic["message"] = "Details omitted because this diagnostic has no visible declaration binding."
    for package in result["packages"]:
        package["symbolIds"] = [key for key in package["symbolIds"] if key in kept]
        for export in package.get("reExports", []):
            bindings = []
            for binding in export.get("bindings", []):
                binding["targetSymbolIds"] = [key for key in binding["targetSymbolIds"] if key in kept]
                if binding["targetSymbolIds"]:
                    bindings.append(binding)
            export["bindings"] = bindings
            if export["kind"] != "packageAlias" and not bindings:
                export["state"] = "unavailable"
    for page in result.get("pages", []):
        page["targetSymbolIds"] = [key for key in page["targetSymbolIds"] if key in kept]
        for binding in page.get("bindings", []):
            if binding["state"] == "unavailable" or (binding.get("targetSymbolId") and binding["targetSymbolId"] not in kept):
                binding.update(target="", selector="", state="unavailable", targetSymbolId=None)

    assets = set()

    def sanitize(value: object) -> None:
        if isinstance(value, list):
            for item in value:
                sanitize(item)
        elif isinstance(value, dict):
            if value.get("kind") == "image":
                assets.add(value.get("literal"))
            if value.get("macroSymbolId") and value["macroSymbolId"] not in kept:
                value["macroSymbolId"] = None
            for target, state in (("targetSymbolId", "referenceState"),
                                  ("semanticTargetSymbolId", "semanticState")):
                if value.get(target) and value[target] not in kept:
                    value[target] = None
                    value[state if state in value else "state"] = "unavailable"
                    if target == "semanticTargetSymbolId":
                        value["semanticExternalUrl"] = None
            for item in value.values():
                sanitize(item)

    sanitize(result["declarations"])
    sanitize(result.get("pages", []))
    result["assets"] = [asset for asset in result["assets"]
                        if asset["id"] in assets or asset["sourcePath"] in assets]
    return result
