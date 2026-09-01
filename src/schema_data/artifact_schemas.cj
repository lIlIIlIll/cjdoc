package cjdoc.schema_data

public let API_SURFACE_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface.schema.json",
  "title": "cjdoc API surface v1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "project", "audience", "declarations", "exposures"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.api-surface/1"},
    "project": {"type": "string", "minLength": 1},
    "audience": {"enum": ["external", "package", "all"]},
    "declarations": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/declaration"}},
    "exposures": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/exposure"}}
  },
  "$defs": {
    "moduleId": {"type": "string", "pattern": "^cjdoc:module:v1:.+$"},
    "symbolId": {"type": "string", "pattern": "^cjdoc:v2:.+$"},
    "nullableSymbolId": {"anyOf": [{"$ref": "#/$defs/symbolId"}, {"type": "null"}]},
    "sourceApiSignature": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "tokens"],
      "properties": {
        "state": {"enum": ["available", "unavailable"]},
        "tokens": {"type": "array", "maxItems": 100000, "items": {"type": "string"}}
      },
      "allOf": [{"if": {"properties": {"state": {"const": "unavailable"}}}, "then": {"properties": {"tokens": {"maxItems": 0}}}}]
    },
    "declaration": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "moduleId", "packageName", "ownerId", "kind", "name", "visibility", "sourceApiSignature"],
      "properties": {
        "id": {"$ref": "#/$defs/symbolId"}, "moduleId": {"$ref": "#/$defs/moduleId"},
        "packageName": {"type": "string", "minLength": 1}, "ownerId": {"$ref": "#/$defs/nullableSymbolId"},
        "kind": {"type": "string", "minLength": 1}, "name": {"type": "string"},
        "visibility": {"enum": ["public", "protected", "internal", "private"]},
        "sourceApiSignature": {"$ref": "#/$defs/sourceApiSignature"}
      }
    },
    "exposure": {
      "type": "object", "additionalProperties": false,
      "required": ["reExportId", "moduleId", "packageName", "exposedName", "targetSymbolIds"],
      "properties": {
        "reExportId": {"type": "string", "pattern": "^cjdoc:reexport:v1:[0-9a-f]{64}$"},
        "moduleId": {"$ref": "#/$defs/moduleId"}, "packageName": {"type": "string", "minLength": 1},
        "exposedName": {"type": "string", "minLength": 1},
        "targetSymbolIds": {"type": "array", "minItems": 1, "uniqueItems": true, "items": {"$ref": "#/$defs/symbolId"}}
      }
    }
  }
}
"""

public let DOCUMENTATION_COVERAGE_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-coverage.schema.json",
  "title": "cjdoc documentation coverage v1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "audience", "symbols", "parameters"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.documentation-coverage/1"},
    "audience": {"enum": ["external", "package", "all"]},
    "symbols": {"$ref": "#/$defs/counts"},
    "parameters": {"$ref": "#/$defs/counts"}
  },
  "$defs": {
    "counts": {
      "type": "object", "additionalProperties": false,
      "required": ["total", "documented", "percent"],
      "properties": {
        "total": {"type": "integer", "minimum": 0, "maximum": 100000},
        "documented": {"type": "integer", "minimum": 0, "maximum": 100000},
        "percent": {"type": "integer", "minimum": 0, "maximum": 100}
      }
    }
  }
}
"""
