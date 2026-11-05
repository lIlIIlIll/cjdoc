package cjdoc.schema_data

import yjson.*

private let SOURCE_PROVENANCE_SCHEMA_TEMPLATE = ##"{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/source-provenance.schema.json",
  "title": "cjdoc caller-pinned source receipt",
  "type": "object", "additionalProperties": false,
  "required": ["schemaVersion", "repository", "files"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.source-provenance/1"},
    "repository": {
      "type": "object", "additionalProperties": false, "required": ["url", "revision"],
      "properties": {
        "url": {"type": "string", "pattern": "^https://github.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"},
        "revision": {"type": "string", "pattern": "^[0-9a-f]{40}$"}
      }
    },
    "files": {
      "type": "array", "maxItems": 100000,
      "items": {
        "type": "object", "additionalProperties": false, "required": ["path", "sha256"],
        "properties": {
          "path": {"$ref": "#/$defs/sourceRepositoryPath"},
          "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"}
        }
      }
    }
  },
  "$defs": {}
}"##

/** Strict receipt format; the trust pin is supplied independently by the caller. */
public func sourceProvenanceReceiptSchema(): String {
    let schema = JsonNode.parse(SOURCE_PROVENANCE_SCHEMA_TEMPLATE).asObject()
    let definitions = schema.get("$defs").getOrThrow().asObject()
    let frozen = JsonNode.parse(DOC_IR_V18_SCHEMA).asObject().get("$defs").getOrThrow().asObject()
    definitions.put("sourceRepositoryPath", frozen.get("sourceRepositoryPath").getOrThrow())
    schema.toJson()
}
