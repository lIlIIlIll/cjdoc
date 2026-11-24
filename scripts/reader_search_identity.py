"""Independently prove publisher/search identities before gate-only comparison."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import os
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


# Each published generation is verified; each keeps its own reading projection
# and therefore its own snapshot identity domain. A package never mixes them.
MANIFEST_PAIRS = (("cjdoc.machine-manifest/1", "cjdoc.read/1"),
                  ("cjdoc.machine-manifest/2", "cjdoc.read/2"),
                  ("cjdoc.machine-manifest/3", "cjdoc.read/3"))
SCHEMA_DIR = Path(__file__).resolve().parent.parent / "docs/schema"
LEGACY_INDEX = "cjdoc.search-index/11"
CURRENT_INDEX = "cjdoc.search-index/12"
BASELINE_CONTRACT_SHA256 = "3bed34e5882e1d131189b5162f6ae281504acb68c1239fca605dcd5d71bd7ae1"
BASELINE_SCHEMAS = {
    "search-index-v11": "c218233c3ee773b0460a49b76caab2ad83c01ea9e2ee30feae02318e76cea3f3",
    "doc-ir-v17": "a83f100c26a17fa7b8f3b3c4bd11cec869d275b6837d29f92e9a96373127f437",
    "symbol-index": "88770d602a73b85600617fe9f2780a84960065a302d87c5314601b8cd392962b",
}


def baseline_schema(name: str) -> dict:
    root = os.environ.get("CJDOC_READER_BASELINE_SCHEMAS")
    _require(bool(root), "CJDOC_READER_BASELINE_SCHEMAS must name the pinned checkout's docs/schema")
    encoded = (Path(root) / (name + ".schema.json")).read_bytes()
    _require(hashlib.sha256(encoded).hexdigest() == BASELINE_SCHEMAS[name],
             "schema differs from the pinned baseline checkout: " + name)
    return strict_loads(encoded, description=name)


def verify_reader_doc_ir_schema(document: dict) -> None:
    if document.get("schemaVersion") == "cjdoc.doc-ir/17":
        schema = baseline_schema("doc-ir-v17")
    else:
        schema = strict_load(SCHEMA_DIR / "doc-ir-v19.schema.json")
    check_schema(document, schema, "docs.json")


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
    """Recover each producer's ordered UTF-8 length-prefixed facts."""
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

    legacy = index["schemaVersion"] == LEGACY_INDEX
    field("format", "cjdoc.search-projection/3" if legacy else "cjdoc.search-projection/4")
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
    if not legacy:
        field("commentFieldCount", str(len(index["commentFields"])))
        for definition in index["commentFields"]:
            fields("commentField.", definition, "scope id title repeatable")
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
        if not legacy:
            for row in entry["commentFields"]:
                field("entry.field.id", row["id"])
                for value in row["values"]:
                    field("entry.field.value", value)
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
    schema_dir = schema_dir or SCHEMA_DIR
    encoded = _verified_bytes(site, "search-index.json", resources["search-index.json"]).decode("utf-8")
    wrapper = _verified_bytes(site, "search-index.js", resources["search-index.js"]).decode("utf-8")
    index = strict_loads(encoded, description="search index")
    version = index.get("schemaVersion")
    _require(version in {LEGACY_INDEX, CURRENT_INDEX}, "unsupported search index version")
    legacy = version == LEGACY_INDEX
    schema = baseline_schema("search-index-v11") if legacy else strict_load(schema_dir / "search-index-v12.schema.json")
    check_schema(index, schema, "search-index.json")
    scripted_index, signatures = _script_data(wrapper)
    _require(scripted_index == index, "script data differs from the JSON index")
    manifest = strict_load(document(site, "agent/manifest.json"))
    pair = (manifest["schemaVersion"], manifest["projection"])
    _require(pair in MANIFEST_PAIRS and manifest["pathBase"] == "document-root",
             "unsupported publisher manifest")
    doc_record = manifest["docIr"]
    matching = [row for row in manifest["resources"] if row["path"] == doc_record["path"]]
    _require(len(matching) == 1 and matching[0]["sha256"] == doc_record["sha256"],
             "packaged Doc IR receipt is absent, duplicate or contradictory")
    packaged = _verified_bytes(site, doc_record["path"], matching[0]).decode("utf-8")
    packaged_ir = strict_loads(packaged, description="packaged Doc IR")
    snapshot = publisher_snapshot_id(packaged, manifest["publicationRevision"], manifest["projection"])
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
    if legacy:
        contract_path = os.environ.get("CJDOC_READER_BASELINE_CONTRACT")
        _require(bool(contract_path), "CJDOC_READER_BASELINE_CONTRACT must name the pinned producer's contract")
        pinned = Path(contract_path).read_bytes()
        _require(hashlib.sha256(pinned).hexdigest() == BASELINE_CONTRACT_SHA256,
                 "contract file differs from the pinned baseline generator")
        _require(contract == pinned.decode("utf-8").rstrip("\n"),
                 "raw contract differs from the pinned baseline generator")
        verify_reader_doc_ir_schema(packaged_ir)
    projection = projection_fingerprint(index, contract)
    _require(projection == index["projectionId"] == index["coverage"]["projectionId"],
             "search projection identity is forged")
    inventory, inventory_sha = None, None
    if "symbolIndex" in manifest:
        record = manifest["symbolIndex"]
        rows = [row for row in manifest["resources"] if row["path"] == record["path"]]
        _require(len(rows) == 1 and rows[0]["sha256"] == record["sha256"],
                 "machine symbol inventory receipt is absent, duplicate or contradictory")
        payload = _verified_bytes(site, record["path"], rows[0])
        inventory_sha = record["sha256"]
        inventory = strict_loads(payload, description="machine symbol inventory")
        symbol_schema = baseline_schema("symbol-index") if legacy else strict_load(schema_dir / "symbol-index.schema.json")
        check_schema(inventory, symbol_schema, record["path"])
    return {"index": index, "signatures": signatures, "contractText": contract,
            "snapshotId": snapshot, "projectionId": projection,
            "docIr": packaged_ir, "docIrSha256": doc_record["sha256"],
            "docIrPath": doc_record["path"], "manifestPair": pair,
            "representations": manifest.get("representations", []),
            "inventory": inventory, "symbolIndexSha256": inventory_sha}


def normalized_search_pair(before: dict, after: dict, *, registered: bool) -> tuple[dict, dict]:
    """Return independent copies with only the registered empty-field delta removed."""
    old, new = deepcopy(before["index"]), deepcopy(after["index"])
    if not registered or old["schemaVersion"] == new["schemaVersion"]:
        _require(before["contractText"] == after["contractText"], "raw embedded contract changed")
        return old, new
    _require((old["schemaVersion"], new["schemaVersion"]) == (LEGACY_INDEX, CURRENT_INDEX),
             "unsupported registered search versions")
    verify_reader_doc_ir_schema(after["docIr"])
    _require(new.get("commentFields") == [] and
             all(entry.get("commentFields") == [] for entry in new["entries"]),
             "registered search transition requires empty comment fields")
    del new["commentFields"]
    for entry in new["entries"]:
        del entry["commentFields"]
    new["schemaVersion"] = old["schemaVersion"]
    contract = new["contract"]
    props = contract["requestProperties"]
    identifier = {"type": "string", "pattern": "^[a-z][a-z0-9-]{0,63}$", "minLength": 1, "maxLength": 64}
    expected = {
        "commentFields": {"type": "array", "minItems": 1, "maxItems": 64,
                          "items": {"type": "object", "additionalProperties": False,
                                    "required": ["id", "value"], "properties": {
                                        "id": identifier,
                                        "value": {"type": "string", "minLength": 1, "maxLength": 16384}}}},
        "commentFieldFacets": {"type": "object", "additionalProperties": False, "properties": {
            "id": identifier, "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            "cursor": {"type": "string", "minLength": 1, "maxLength": 1024}}},
    }
    _require(contract.get("version") == "cjdoc.search-contract/3" and
             props.get("schemaVersion") == {"const": "cjdoc.query-request/4"} and
             contract["searchFields"][-2:] == list(expected) and
             all(props.get(key) == value for key, value in expected.items()),
             "search contract does not have the exact registered additions")
    for key in expected:
        del props[key]
    del contract["searchFields"][-2:]
    contract["version"] = "cjdoc.search-contract/2"
    props["schemaVersion"] = {"const": "cjdoc.query-request/3"}
    _require(contract == old["contract"], "embedded contract changed beyond the registered additions")
    return old, new


def compare_search_identities(before: dict, after: dict) -> None:
    _require(before["signatures"] == after["signatures"], "native script signatures changed")
    compared = normalized_search_pair(before, after, registered=True)
    for index in compared:
        for name in ("snapshotId", "sourceSnapshotId"):
            index["scope"][name] = "<registered-paired-snapshot>"
        for entry in index["entries"]:
            entry["snapshotId"] = "<registered-paired-snapshot>"
        index["projectionId"] = "<registered-paired-projection>"
        index["coverage"]["projectionId"] = "<registered-paired-projection>"
    _require(compared[0] == compared[1], "search payload changed beyond the proved paired identities")
