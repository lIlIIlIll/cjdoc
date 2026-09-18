package cjdoc.schema_data

public let API_SURFACE_V1_SCHEMA = """
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

public let API_SURFACE_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface.schema.json",
  "title": "cjdoc API surface v2",
  "type": "object", "additionalProperties": false,
  "required": ["schemaVersion", "project", "audience", "cfgProfile", "collectionState", "declarations", "exposures"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.api-surface/2"},
    "project": {"type": "string", "minLength": 1},
    "audience": {"enum": ["external", "package", "all"]},
    "cfgProfile": {"type": "string", "minLength": 1},
    "collectionState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "declarations": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/declaration"}},
    "exposures": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/exposure"}}
  },
  "$defs": {
    "state": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "nullableString": {"anyOf": [{"type": "string"}, {"type": "null"}]},
    "nullableBool": {"anyOf": [{"type": "boolean"}, {"type": "null"}]},
    "fingerprint": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "sourceApiSignature": {
      "type": "object", "additionalProperties": false, "required": ["state", "tokens"],
      "properties": {"state": {"$ref": "#/$defs/state"}, "tokens": {"type": "array", "items": {"type": "string"}}}
    },
    "evidence": {
      "type": "object", "additionalProperties": false, "required": ["state", "value"],
      "properties": {"state": {"$ref": "#/$defs/state"}, "value": {"$ref": "#/$defs/nullableString"}}
    },
    "returnEvidence": {
      "type": "object", "additionalProperties": false, "required": ["state", "type"],
      "properties": {"state": {"$ref": "#/$defs/state"}, "type": {"$ref": "#/$defs/nullableString"}}
    },
    "parameter": {
      "type": "object", "additionalProperties": false, "required": ["name", "type", "default"],
      "properties": {"name": {"type": "string", "minLength": 1}, "type": {"$ref": "#/$defs/evidence"}, "default": {"$ref": "#/$defs/evidence"}}
    },
    "declaration": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "moduleId", "packageName", "ownerId", "kind", "name", "qualifiedName", "visibility", "sourceApiSignature", "genericParameters", "parameters", "return", "relationships", "enumNonExhaustive", "documentationFingerprint", "sourceFingerprint", "metadataFingerprint", "collectionState"],
      "properties": {
        "id": {"type": "string", "minLength": 1}, "moduleId": {"type": "string", "minLength": 1},
        "packageName": {"type": "string", "minLength": 1}, "ownerId": {"$ref": "#/$defs/nullableString"},
        "kind": {"type": "string", "minLength": 1}, "name": {"type": "string", "minLength": 1},
        "qualifiedName": {"type": "string", "minLength": 1}, "visibility": {"type": "string", "minLength": 1},
        "sourceApiSignature": {"$ref": "#/$defs/sourceApiSignature"},
        "genericParameters": {"type": "array", "items": {"type": "string"}},
        "parameters": {"type": "array", "items": {"$ref": "#/$defs/parameter"}},
        "return": {"$ref": "#/$defs/returnEvidence"}, "relationships": {"type": "array", "items": {"type": "string"}},
        "enumNonExhaustive": {"$ref": "#/$defs/nullableBool"},
        "documentationFingerprint": {"$ref": "#/$defs/fingerprint"}, "sourceFingerprint": {"$ref": "#/$defs/fingerprint"},
        "metadataFingerprint": {"$ref": "#/$defs/fingerprint"}, "collectionState": {"$ref": "#/$defs/state"}
      }
    },
    "exposure": {
      "type": "object", "additionalProperties": false, "required": ["id", "moduleId", "packageName", "exposedName", "targetIds", "state"],
      "properties": {"id": {"type": "string", "minLength": 1}, "moduleId": {"type": "string", "minLength": 1}, "packageName": {"type": "string", "minLength": 1}, "exposedName": {"type": "string", "minLength": 1}, "targetIds": {"type": "array", "minItems": 1, "items": {"type": "string"}}, "state": {"$ref": "#/$defs/state"}}
    }
  }
}
"""

public let API_DIFF_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-diff.schema.json",
  "title": "cjdoc API diff v1",
  "type": "object", "additionalProperties": false,
  "required": ["schemaVersion", "baseline", "current", "comparisonState", "summary", "entries"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.api-diff/1"},
    "baseline": {"$ref": "#/$defs/identity"}, "current": {"$ref": "#/$defs/identity"},
    "comparisonState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "summary": {"$ref": "#/$defs/summary"}, "entries": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/entry"}}
  },
  "$defs": {
    "nullableString": {"anyOf": [{"type": "string"}, {"type": "null"}]},
    "identity": {"type": "object", "additionalProperties": false, "required": ["project", "audience", "cfgProfile", "schemaVersion", "collectionState"], "properties": {"project": {"type": "string", "minLength": 1}, "audience": {"type": "string", "minLength": 1}, "cfgProfile": {"type": "string", "minLength": 1}, "schemaVersion": {"type": "string", "minLength": 1}, "collectionState": {"type": "string", "minLength": 1}}},
    "summary": {"type": "object", "additionalProperties": false, "required": ["breaking", "potentiallyBreaking", "additive", "documentationOnly", "metadataOnly", "unchanged"], "properties": {"breaking": {"type": "integer", "minimum": 0}, "potentiallyBreaking": {"type": "integer", "minimum": 0}, "additive": {"type": "integer", "minimum": 0}, "documentationOnly": {"type": "integer", "minimum": 0}, "metadataOnly": {"type": "integer", "minimum": 0}, "unchanged": {"type": "integer", "minimum": 0}}},
    "evidence": {"type": "object", "additionalProperties": false, "required": ["field", "before", "after", "state"], "properties": {"field": {"type": "string", "minLength": 1}, "before": {"$ref": "#/$defs/nullableString"}, "after": {"$ref": "#/$defs/nullableString"}, "state": {"type": "string", "minLength": 1}}},
    "entry": {"type": "object", "additionalProperties": false, "required": ["oldId", "newId", "kind", "classification", "matchState", "reasons", "evidence"], "properties": {"oldId": {"$ref": "#/$defs/nullableString"}, "newId": {"$ref": "#/$defs/nullableString"}, "kind": {"type": "string", "minLength": 1}, "classification": {"enum": ["breaking", "potentially-breaking", "additive", "documentation-only", "metadata-only", "unchanged"]}, "matchState": {"type": "string", "minLength": 1}, "reasons": {"type": "array", "items": {"type": "string"}}, "evidence": {"type": "array", "items": {"$ref": "#/$defs/evidence"}}}}
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
