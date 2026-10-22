package cjdoc.schema_data

// Current distribution-time schema contracts; docs/schema copies are emitted by cjdoc schema.
public let DIAGNOSTICS_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/diagnostics.schema.json",
  "title": "cjdoc diagnostics v2",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "diagnostics"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.diagnostics/2"},
    "diagnostics": {"type": "array", "items": {"$ref": "doc-ir.schema.json#/$defs/diagnostic"}}
  }
}
"""

public let CFG_MATRIX_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/cfg-matrix.schema.json",
  "title": "cjdoc cfg matrix v2",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "generator", "profiles"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.cfg-matrix/2"},
    "generator": {"type": "object", "additionalProperties": false, "required": ["name", "version"], "properties": {"name": {"const": "cjdoc"}, "version": {"type": "string"}}},
    "profiles": {"type": "array", "minItems": 1, "items": {"type": "object", "additionalProperties": false, "required": ["name", "documentation"], "properties": {"name": {"type": "string", "minLength": 1}, "documentation": {"$ref": "doc-ir.schema.json"}}}}
  }
}
"""
