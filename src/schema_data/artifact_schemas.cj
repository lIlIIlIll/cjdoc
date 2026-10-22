package cjdoc.schema_data

// Current distribution-time schema contracts; docs/schema copies are emitted by cjdoc schema.
public let DOCUMENTATION_COVERAGE_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-coverage.schema.json",
  "title": "cjdoc documentation coverage v2",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "audience", "metrics", "packages", "modules"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.documentation-coverage/2"},
    "audience": {"enum": ["external", "package", "all"]},
    "metrics": {"$ref": "#/$defs/metrics"},
    "packages": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/group"}},
    "modules": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/group"}}
  },
  "$defs": {
    "metric": {
      "type": "object", "additionalProperties": false,
      "required": ["total", "documented", "percent"],
      "properties": {
        "total": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "documented": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "percent": {"type": "integer", "minimum": 0, "maximum": 100}
      }
    },
    "metrics": {
      "type": "object", "additionalProperties": false,
      "required": ["symbols", "parameters", "returns", "throws", "examples", "deprecated", "semanticLinks"],
      "properties": {
        "symbols": {"$ref": "#/$defs/metric"},
        "parameters": {"$ref": "#/$defs/metric"},
        "returns": {"$ref": "#/$defs/metric"},
        "throws": {"$ref": "#/$defs/metric"},
        "examples": {"$ref": "#/$defs/metric"},
        "deprecated": {"$ref": "#/$defs/metric"},
        "semanticLinks": {"$ref": "#/$defs/metric"}
      }
    },
    "group": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "metrics"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "metrics": {"$ref": "#/$defs/metrics"}
      }
    }
  }
}
"""

public let NAVIGATION_INDEX_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/navigation-index.schema.json",
  "title": "cjdoc agent navigation index",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "project", "pages"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.navigation-index/1"},
    "project": {"$ref": "#/$defs/project"},
    "pages": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/page"}}
  },
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "pattern": "^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\)(?!.*(^|/)[.][.]?(/|$)).+$"
    },
    "project": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "audience", "version"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "audience": {"type": "string", "minLength": 1},
        "version": {"anyOf": [{"type": "string", "minLength": 1}, {"type": "null"}]}
      }
    },
    "page": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "kind", "title", "href", "summary", "symbolId", "moduleId", "packageName", "semanticState"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "kind": {"enum": ["project", "machine", "concept", "package", "symbol", "module", "guide", "validation"]},
        "title": {"type": "string", "minLength": 1},
        "href": {"$ref": "#/$defs/safePath"},
        "summary": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "symbolId": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "moduleId": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "packageName": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "semanticState": {"anyOf": [{"type": "string"}, {"type": "null"}]}
      }
    }
  }
}
"""
