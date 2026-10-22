package cjdoc.schema_data

// Current distribution-time schema contracts; docs/schema copies are emitted by cjdoc schema.
public let SYMBOL_INDEX_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/symbol-index.schema.json",
  "title": "cjdoc symbol index v2",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "project", "entries", "dependencies", "documentSets"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.symbol-index/2"},
    "provenance": {"type":"array","items":{"type":"object","additionalProperties":false,"required":["documentSetId","sourceUri","revision","sha256","excerpt","verification","sdkMapping","license"],"properties":{"documentSetId":{"type":"string","minLength":1},"sourceUri":{"type":"string","minLength":1},"revision":{"type":"string","minLength":1},"sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"excerpt":{"type":"object","additionalProperties":false,"required":["startLine","endLine","sha256"],"properties":{"startLine":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1},"sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},"verification":{"const":"pinned-documentation-source-lines"},"sdkMapping":{"const":"none"},"license":{"type":"string","minLength":1}}}},
    "version": {"type": "string", "minLength": 1},
    "project": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "audience"],
      "properties": {"name": {"type": "string"}, "audience": {"type": "string"}}
    },
    "dependencies": {"type": "array", "items": {"$ref": "#/$defs/dependencyInstance"}},
    "documentSets": {"type": "array", "items": {"$ref": "#/$defs/documentSetIdentity"}},
    "entries": {
      "type": "array",
      "items": {
        "type": "object", "additionalProperties": false,
        "required": ["id", "canonicalId", "name", "qualifiedName", "kind", "moduleId", "packageName", "ownerId", "visibility", "semanticState", "summary", "source", "href", "relations", "references", "identity", "documentSetId", "symbolKey", "typeNavigations"],
        "properties": {
          "id": {"type": "string", "pattern": "^cjdoc:v2:.+$"},
          "sourceHeader": {"type": "string"}, "identity": {"type": "string"}, "documentSetId": {"type": "string"},
          "symbolKey": {"type": "string", "minLength": 1},
          "typeNavigations": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["spelling", "navigation"], "properties": {"spelling": {"type": "string"}, "navigation": {"$ref": "#/$defs/typeNavigation"}}}},
          "canonicalId": {"type": "string", "pattern": "^cjdoc:v2:.+$"},
          "name": {"type": "string"}, "qualifiedName": {"type": "string", "minLength": 1},
          "kind": {"type": "string", "minLength": 1}, "moduleId": {"type": "string", "minLength": 1},
          "packageName": {"type": "string", "minLength": 1},
          "ownerId": {"type": ["string", "null"]}, "visibility": {"type": "string"},
          "semanticState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
          "summary": {"type": "string"},
          "source": {"$ref": "#/$defs/source"},
          "href": {"type": "string", "pattern": "^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\).+$"},
          "relations": {"type": "array", "items": {"$ref": "#/$defs/link"}},
          "references": {"type": "array", "items": {"$ref": "#/$defs/reference"}}
        }
      }
    }
  },
  "$defs": {
    "dependencyInstance": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "moduleId",
        "componentModuleId",
        "name",
        "instanceId",
        "kind",
        "identity",
        "state",
        "evidence",
        "version",
        "revision",
        "target",
        "cfg"
      ],
      "properties": {
        "moduleId": {
          "type": "string",
          "minLength": 1
        },
        "componentModuleId": {"type": "string"},
        "name": {
          "type": "string",
          "minLength": 1
        },
        "instanceId": {
          "type": "string",
          "minLength": 1
        },
        "kind": {
          "enum": [
            "source",
            "binary",
            "std",
            "stdx",
            "toolchain"
          ]
        },
        "identity": {
          "type": "string"
        },
        "state": {
          "enum": [
            "unknown",
            "declared",
            "observed",
            "verified",
            "conflict"
          ]
        },
        "evidence": {
          "type": "string"
        },
        "provenance": {"type":"array","items":{"type":"object","additionalProperties":false,"required":["documentSetId","sourceUri","revision","sha256","excerpt","verification","sdkMapping","license"],"properties":{"documentSetId":{"type":"string","minLength":1},"sourceUri":{"type":"string","minLength":1},"revision":{"type":"string","minLength":1},"sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"excerpt":{"type":"object","additionalProperties":false,"required":["startLine","endLine","sha256"],"properties":{"startLine":{"type":"integer","minimum":1},"endLine":{"type":"integer","minimum":1},"sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},"verification":{"const":"pinned-documentation-source-lines"},"sdkMapping":{"const":"none"},"license":{"type":"string","minLength":1}}}},
    "version": {
          "type": "string"
        },
        "revision": {
          "type": "string"
        },
        "target": {
          "type": "string"
        },
        "cfg": {
          "type": "string"
        }
      }
    },
    "documentSetIdentity": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "moduleId",
        "library",
        "identity",
        "state",
        "source",
        "target",
        "cfg",
        "audience",
        "language",
        "revision",
        "apiVersion",
        "documentationRevision",
        "indexIdentity",
        "baseUrl"
      ],
      "properties": {
        "id": {
          "type": "string",
          "minLength": 1
        },
        "moduleId": {"type": "string"},
        "library": {
          "type": "string",
          "minLength": 1
        },
        "identity": {
          "type": "string"
        },
        "state": {
          "enum": [
            "observed",
            "verified",
            "declared",
            "unknown"
          ]
        },
        "source": {
          "type": "string"
        },
        "target": {
          "type": "string"
        },
        "cfg": {
          "type": "string"
        },
        "audience": {
          "type": "string"
        },
        "language": {
          "type": "string"
        },
        "revision": {
          "type": "string"
        },
        "apiVersion": {"type": "string"},
        "documentationRevision": {"type": "string"},
        "indexIdentity": {
          "type": "string"
        },
        "baseUrl": {
          "type": "string"
        }
      }
    },
    "typeNavigation": {
      "oneOf": [
        {"$ref": "#/$defs/contextFreeNavigationFailure"},
        {"$ref": "#/$defs/contextualTypeNavigation"}
      ]
    },
    "contextFreeNavigationFailure": {
      "type": "array",
      "minItems": 2,
      "maxItems": 2,
      "prefixItems": [
        {"enum": ["unresolved", "ambiguous", "unavailable"]},
        {"type": "string", "minLength": 1}
      ],
      "items": false
    },
    "contextualTypeNavigation": {
      "type": "object",
      "additionalProperties": false,
      "not": {
        "properties": {
          "state": {"enum": ["unresolved", "ambiguous", "unavailable"]},
          "matchLevel": {"const": "none"},
          "dependencyInstanceId": {"const": ""},
          "documentSetId": {"const": ""},
          "indexIdentity": {"const": ""},
          "symbolKey": {"const": ""},
          "url": {"const": ""},
          "apiIdentity": {"const": ""},
          "language": {"const": ""}
        }
      },
      "required": [
        "state",
        "matchLevel",
        "reason",
        "dependencyInstanceId",
        "documentSetId",
        "indexIdentity",
        "symbolKey",
        "url",
        "apiIdentity",
        "language"
      ],
      "properties": {
        "state": {
          "enum": [
            "resolved",
            "unresolved",
            "ambiguous",
            "unavailable"
          ]
        },
        "matchLevel": {
          "enum": [
            "exact",
            "compatible",
            "manual",
            "none"
          ]
        },
        "reason": {
          "type": "string",
          "minLength": 1
        },
        "dependencyInstanceId": {
          "type": "string"
        },
        "documentSetId": {
          "type": "string"
        },
        "indexIdentity": {
          "type": "string"
        },
        "symbolKey": {
          "type": "string"
        },
        "url": {
          "type": "string"
        },
        "apiIdentity": {
          "type": "string"
        },
        "language": {
          "type": "string"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "state": {
                "const": "resolved"
              }
            }
          },
          "then": {
            "properties": {
              "url": {
                "minLength": 1
              },
              "matchLevel": {
                "enum": [
                  "exact",
                  "compatible",
                  "manual"
                ]
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "state": {
                "enum": [
                  "unresolved",
                  "ambiguous",
                  "unavailable"
                ]
              }
            }
          },
          "then": {
            "properties": {
              "url": {
                "const": ""
              }
            }
          }
        }
      ]
    },

    "position": {
      "type": "object", "additionalProperties": false,
      "required": ["line", "column", "byteOffset"],
      "properties": {"line": {"type": "integer", "minimum": 1}, "column": {"type": "integer", "minimum": 1}, "byteOffset": {"type": "integer", "minimum": 0}}
    },
    "source": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "start", "end"],
      "properties": {"path": {"type": "string", "minLength": 1}, "start": {"$ref": "#/$defs/position"}, "end": {"$ref": "#/$defs/position"}}
    },
    "link": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "display", "state", "targetId"],
      "properties": {"kind": {"type": "string", "minLength": 1}, "display": {"type": "string"}, "state": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]}, "targetId": {"type": ["string", "null"]}}
    },
    "reference": {
      "type": "object", "additionalProperties": false,
      "required": ["subject", "description", "state", "targetId", "navigation"],
      "properties": {"navigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}, "subject": {"type": "string"}, "description": {"type": "string"}, "state": {"enum": ["resolved", "partial", "unavailable", "ambiguous", "unresolved", "broken"]}, "targetId": {"type": ["string", "null"]}}
    }
  }
}
"""
