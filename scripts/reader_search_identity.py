"""Independently prove publisher/search identities before gate-only comparison."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_load, strict_loads
    from .test_agent_artifacts import check_schema, document, publisher_snapshot_id
except ImportError:
    from strict_json import strict_load, strict_loads
    from test_agent_artifacts import check_schema, document, publisher_snapshot_id


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError("Reader search identity: " + message)


def _raw_contract(encoded: str) -> str:
    """Locate a root value without reserializing or searching inside strings."""
    decoder = json.JSONDecoder()
    at = encoded.index("{") + 1
    while True:
        while encoded[at].isspace():
            at += 1
        key, at = decoder.raw_decode(encoded, at)
        while encoded[at].isspace():
            at += 1
        _require(encoded[at] == ":", "invalid root property separator")
        at += 1
        while encoded[at].isspace():
            at += 1
        start = at
        _, at = decoder.raw_decode(encoded, at)
        if key == "contract":
            return encoded[start:at]
        while encoded[at].isspace():
            at += 1
        _require(encoded[at] == ",", "missing root search contract")
        at += 1


def _script_data(encoded: str) -> tuple[dict, dict]:
    """Accept only the two assignments emitted by renderSearchIndexScript."""
    decoder = json.JSONDecoder()
    first = "globalThis.__CJDOC_SEARCH_INDEX__ = "
    second = ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = "
    _require(encoded.startswith(first), "unexpected script prefix")
    start = len(first)
    _, end = decoder.raw_decode(encoded, start)
    index = strict_loads(encoded[start:end], description="search script index")
    _require(encoded.startswith(second, end), "unexpected executable script content")
    start = end + len(second)
    _, end = decoder.raw_decode(encoded, start)
    signatures = strict_loads(encoded[start:end], description="search script signatures")
    _require(encoded[end:] == ";\n", "unexpected script suffix")
    _require(isinstance(signatures, dict) and all(isinstance(value, str) for value in signatures.values()),
             "signature payload is not a string map")
    return index, signatures


def projection_fingerprint(index: dict, raw_contract: str) -> str:
    """Recover the schema11 producer's ordered UTF-8 length-prefixed facts."""
    parts: list[bytes] = []

    def field(name: str, value: str) -> None:
        _require(type(value) is str, "fingerprint field is not text: " + name)
        key, content = name.encode("utf-8"), value.encode("utf-8")
        parts.extend((str(len(key)).encode(), b":", key, str(len(content)).encode(), b":", content))

    def scalar(value: object) -> str:
        if type(value) is bool:
            return "true" if value else "false"
        if type(value) is int:
            return str(value)
        _require(type(value) is str, "unexpected fingerprint scalar")
        return value

    def optional(name: str, value: object) -> None:
        field(name + ".present", "0" if value is None else "1")
        if value is not None:
            field(name, scalar(value))

    def fields(prefix: str, value: dict, names: str) -> None:
        for name in names.split():
            field(prefix + name, scalar(value[name]))

    def object_fields(prefix: str, value: dict | None, names: str) -> None:
        field(prefix + "present", "0" if value is None else "1")
        if value is not None:
            fields(prefix, value, names)

    field("format", "cjdoc.search-projection/3")
    field("contract", raw_contract)
    field("profile", index["profile"])
    fields("", index["scope"],
           "snapshotId sourceSnapshotId publicationRevision project language audience cfgProfile apiCollectionState")
    field("moduleCount", str(len(index["modules"])))
    for module in index["modules"]:
        field("module.moduleId", module["moduleId"])
        optional("module.moduleName", module["moduleName"])
        field("module.dependencyState", module["dependencyInstanceState"])
        object_fields("documentSet.", module["documentSet"],
                      "id moduleId library identity state source target cfg audience language revision apiVersion "
                      "documentationRevision indexIdentity baseUrl")
        object_fields("dependency.", module["dependency"],
                      "moduleId componentModuleId name instanceId kind identity state evidence version revision target cfg")
    field("tagDictionaryCount", str(len(index["tags"])))
    for tag in index["tags"]:
        fields("tag.", tag, "scope id title")
    field("entryCount", str(len(index["entries"])))
    for entry in index["entries"]:
        fields("entry.", entry, "id canonicalId snapshotId concept scope genericArity")
        optional("entry.ownerId", entry["ownerId"])
        fields("entry.", entry, "kind name")
        for name in ("qualifiedName", "packageName"):
            field("entry." + name, entry[name] or "")
        module = index["modules"][entry["scope"]] if entry["scope"] >= 0 else None
        field("entry.moduleId", module["moduleId"] if module else "")
        field("entry.moduleName", (module["moduleName"] or "") if module else "")
        for name in ("ownerName", "ownerQualifiedName", "symbolKey", "returnType", "returnCanonical"):
            field("entry." + name, entry[name] or "")
        fields("entry.", entry, "href summary body bodyTruncated")
        classification = entry["classification"]
        group = classification["group"]
        field("classification.group", "false" if group is None else "true")
        if group is not None:
            fields("group.", group, "id packageName")
            optional("group.ownerId", group["ownerId"])
            field("group.title", group["title"])
            optional("group.order", group["order"])
        field("classification.tagCount", str(len(classification["tags"])))
        for tag in classification["tags"]:
            fields("classification.tag.", tag, "id title")
        field("entry.parameterCount", str(len(entry["parameterTypes"])))
        for parameter in entry["parameterTypes"]:
            field("entry.parameter", parameter)
        field("entry.exposureCount", str(len(entry["exposures"])))
        for exposure in entry["exposures"]:
            fields("exposure.", exposure, "id name qualifiedName packageName scope")
        field("entry.sectionCount", str(len(entry["sections"])))
        for section in entry["sections"]:
            fields("section.", section, "kind anchor text")
        field("entry.externalDocCount", str(len(entry["externalDocs"])))
        for external in entry["externalDocs"]:
            fields("external.", external, "name state url reason version index format fingerprint")
        field("entry.bindingCount", str(len(entry["bindings"])))
        for binding in entry["bindings"]:
            fields("binding.", binding, "target selector provenance version sourceLine language state")
            optional("binding.targetSymbolId", binding["targetSymbolId"])
            optional("binding.href", binding["href"])
            field("binding.navigationTitle", binding["navigationTitle"])
            navigation = binding["navigation"]
            if isinstance(navigation, list):
                navigation = dict(state=navigation[0], reason=navigation[1], matchLevel="none",
                                  **{key: "" for key in "dependencyInstanceId documentSetId indexIdentity "
                                     "symbolKey url apiIdentity language".split()})
            object_fields("binding.navigation.", navigation,
                          "state matchLevel reason dependencyInstanceId documentSetId indexIdentity "
                          "symbolKey url apiIdentity language")
    return hashlib.sha256(b"".join(parts)).hexdigest()


def _verified_bytes(site: Path, name: str, record: dict) -> bytes:
    value = document(site, name).read_bytes()
    _require(hashlib.sha256(value).hexdigest() == record["sha256"], name + " raw receipt hash mismatch")
    if "bytes" in record:
        _require(len(value) == record["bytes"], name + " raw receipt size mismatch")
    return value


def verify_search_identity(site: Path, resources: dict, schema_dir: Path | None = None) -> dict:
    schema_dir = schema_dir or Path(__file__).resolve().parent.parent / "docs/schema"
    encoded = _verified_bytes(site, "search-index.json", resources["search-index.json"]).decode("utf-8")
    wrapper = _verified_bytes(site, "search-index.js", resources["search-index.js"]).decode("utf-8")
    index = strict_loads(encoded, description="search index")
    check_schema(index, strict_load(schema_dir / "search-index-v11.schema.json"), "search-index.json")
    scripted_index, signatures = _script_data(wrapper)
    _require(scripted_index == index, "script data differs from the JSON index")
    manifest = strict_load(document(site, "agent/manifest.json"))
    _require(manifest["projection"] == "cjdoc.read/1" and manifest["pathBase"] == "document-root",
             "unsupported publisher manifest")
    doc_record = manifest["docIr"]
    matching = [row for row in manifest["resources"] if row["path"] == doc_record["path"]]
    _require(len(matching) == 1 and matching[0]["sha256"] == doc_record["sha256"],
             "packaged Doc IR receipt is absent, duplicate or contradictory")
    packaged = _verified_bytes(site, doc_record["path"], matching[0]).decode("utf-8")
    packaged_ir = strict_loads(packaged, description="packaged Doc IR")
    snapshot = publisher_snapshot_id(packaged, manifest["publicationRevision"])
    _require(snapshot == manifest["snapshotId"] == manifest["scope"]["snapshotId"],
             "publisher snapshot identity is forged")
    _require(index["scope"]["snapshotId"] == snapshot and index["scope"]["sourceSnapshotId"] == snapshot,
             "index scope is not the directly published snapshot")
    _require(all(entry["snapshotId"] == snapshot for entry in index["entries"]),
             "entry snapshot differs from the published snapshot")
    for name, manifest_name in (("audience", "audience"), ("cfgProfile", "cfgProfile"),
                                ("language", "readingLanguage"), ("apiCollectionState", "apiCollectionState"),
                                ("publicationRevision", "publicationRevision")):
        _require(index["scope"][name] == manifest["scope"][manifest_name], "publisher scope differs: " + name)
    contract = _raw_contract(encoded)
    projection = projection_fingerprint(index, contract)
    _require(projection == index["projectionId"] == index["coverage"]["projectionId"],
             "search projection identity is forged")
    return {"index": index, "signatures": signatures, "contractText": contract,
            "snapshotId": snapshot, "projectionId": projection,
            "docIr": packaged_ir, "docIrSha256": doc_record["sha256"],
            "docIrPath": doc_record["path"]}


def compare_search_identities(before: dict, after: dict) -> None:
    _require(before["contractText"] == after["contractText"], "raw embedded contract changed")
    _require(before["signatures"] == after["signatures"], "native script signatures changed")
    compared = []
    for observation in (before, after):
        index = deepcopy(observation["index"])
        for name in ("snapshotId", "sourceSnapshotId"):
            index["scope"][name] = "<registered-paired-snapshot>"
        for entry in index["entries"]:
            entry["snapshotId"] = "<registered-paired-snapshot>"
        index["projectionId"] = "<registered-paired-projection>"
        index["coverage"]["projectionId"] = "<registered-paired-projection>"
        compared.append(index)
    _require(compared[0] == compared[1], "search payload changed beyond the proved paired identities")
