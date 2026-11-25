package cjdoc.schema_data

internal let DOC_IR_SOURCE_AND_TYPES = """
    "sourceDigest": {"type": "string", "pattern": "^sha256:[0-9a-f]{64}$"},
    "nullableSourceDigest": {"anyOf": [{"$ref": "#/$defs/sourceDigest"}, {"type": "null"}]},
    "sourceRepositoryPath": {
      "type": "string", "minLength": 1, "pattern": "^[^/]+(?:/[^/]+)*$",
      "not": {"anyOf": [{"pattern": "^[A-Za-z]:"}, {"pattern": "[\\\\\\\\]"},
        {"pattern": "[\\u0000-\\u001f\\u007f]"}, {"pattern": "(^|/)\\\\.{1,2}(/|$)"}]}
    },
    "sourceProvenanceState": {"enum": ["verified", "declared", "unavailable", "ambiguous"]},
    "sourceProvenanceReason": {"enum": ["receipt_matched", "legacy_project_repository", "no_registration", "no_project_repository",
      "missing_receipt", "unpinned_receipt", "receipt_unavailable", "invalid_receipt", "receipt_pin_mismatch",
      "receipt_repository_mismatch", "missing_file_record", "digest_mismatch", "conflicting_registration",
      "path_escape", "invalid_range", "capture_unavailable", "resource_limit"]},
    "sourceProvenance": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "reason", "repository", "repositoryPath", "sourceDigest", "normalizedDigest", "evidenceIdentity", "evidenceKind"],
      "properties": {
        "state": {"$ref": "#/$defs/sourceProvenanceState"},
        "reason": {"$ref": "#/$defs/sourceProvenanceReason"},
        "repository": {"anyOf": [{"$ref": "#/$defs/repository"}, {"type": "null"}]},
        "repositoryPath": {"anyOf": [{"$ref": "#/$defs/sourceRepositoryPath"}, {"type": "null"}]},
        "sourceDigest": {"$ref": "#/$defs/nullableSourceDigest"},
        "normalizedDigest": {"$ref": "#/$defs/nullableSourceDigest"},
        "evidenceIdentity": {"$ref": "#/$defs/nullableSourceDigest"},
        "evidenceKind": {"enum": ["caller_pinned_receipt", "none"]}
      },
      "allOf": [
        {"if": {"properties": {"state": {"const": "verified"}}},
          "then": {"properties": {"reason": {"const": "receipt_matched"},
            "repository": {"allOf": [{"$ref": "#/$defs/repository"}, {"properties": {"revision": {"pattern": "^[0-9a-f]{40}$"}}}]},
            "repositoryPath": {"$ref": "#/$defs/sourceRepositoryPath"}, "sourceDigest": {"$ref": "#/$defs/sourceDigest"},
            "normalizedDigest": {"$ref": "#/$defs/sourceDigest"}, "evidenceIdentity": {"$ref": "#/$defs/sourceDigest"},
            "evidenceKind": {"const": "caller_pinned_receipt"}}}},
        {"if": {"properties": {"state": {"const": "declared"}}},
          "then": {"properties": {"reason": {"const": "legacy_project_repository"}, "repository": {"$ref": "#/$defs/repository"},
            "repositoryPath": {"$ref": "#/$defs/sourceRepositoryPath"}, "sourceDigest": {"type": "null"},
            "normalizedDigest": {"type": "null"}, "evidenceIdentity": {"type": "null"}, "evidenceKind": {"const": "none"}}}},
        {"if": {"properties": {"state": {"enum": ["unavailable", "ambiguous"]}}},
          "then": {"properties": {"repository": {"type": "null"}, "repositoryPath": {"type": "null"},
            "evidenceIdentity": {"type": "null"}, "evidenceKind": {"const": "none"},
            "reason": {"not": {"enum": ["receipt_matched", "legacy_project_repository"]}}}}},
        {"if": {"properties": {"state": {"const": "ambiguous"}}},
          "then": {"properties": {"reason": {"const": "conflicting_registration"}}},
          "else": {"properties": {"reason": {"not": {"const": "conflicting_registration"}}}}}
      ]
    },
    "sourceReference": {
      "type": "object", "additionalProperties": false,
      "required": ["url", "range", "state", "reason", "repository", "recordedRevision", "revisionKind",
        "sourceDigest", "normalizedDigest", "evidenceIdentity", "evidenceKind"],
      "properties": {
        "url": {"$ref": "#/$defs/nullableString"}, "range": {"$ref": "#/$defs/sourceRange"},
        "state": {"$ref": "#/$defs/sourceProvenanceState"},
        "reason": {"$ref": "#/$defs/sourceProvenanceReason"},
        "repository": {"anyOf": [{"$ref": "#/$defs/repository"}, {"type": "null"}]},
        "recordedRevision": {"$ref": "#/$defs/nullableString"},
        "revisionKind": {"enum": ["exact", "ref", "unavailable"]},
        "sourceDigest": {"$ref": "#/$defs/nullableSourceDigest"},
        "normalizedDigest": {"$ref": "#/$defs/nullableSourceDigest"},
        "evidenceIdentity": {"$ref": "#/$defs/nullableSourceDigest"},
        "evidenceKind": {"enum": ["caller_pinned_receipt", "none"]}
      },
      "allOf": [
        {"if": {"properties": {"state": {"enum": ["unavailable", "ambiguous"]}}},
          "then": {"properties": {"url": {"type": "null"}, "repository": {"type": "null"},
            "recordedRevision": {"type": "null"}, "revisionKind": {"const": "unavailable"},
            "evidenceIdentity": {"type": "null"}, "evidenceKind": {"const": "none"}}}},
        {"if": {"properties": {"state": {"const": "verified"}}},
          "then": {"properties": {"reason": {"const": "receipt_matched"},
            "url": {"type": "string", "minLength": 1}, "repository": {"$ref": "#/$defs/repository"},
            "recordedRevision": {"type": "string", "pattern": "^[0-9a-f]{40}$"}, "revisionKind": {"const": "exact"},
            "sourceDigest": {"$ref": "#/$defs/sourceDigest"}, "normalizedDigest": {"$ref": "#/$defs/sourceDigest"},
            "evidenceIdentity": {"$ref": "#/$defs/sourceDigest"}, "evidenceKind": {"const": "caller_pinned_receipt"}}}},
        {"if": {"properties": {"state": {"const": "declared"}}},
          "then": {"properties": {"reason": {"const": "legacy_project_repository"},
            "url": {"type": "string", "minLength": 1}, "repository": {"$ref": "#/$defs/repository"},
            "recordedRevision": {"type": "string", "minLength": 1}, "revisionKind": {"enum": ["exact", "ref"]},
            "sourceDigest": {"type": "null"}, "normalizedDigest": {"type": "null"},
            "evidenceIdentity": {"type": "null"}, "evidenceKind": {"const": "none"}}}}
      ]
    },
    "file": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "moduleId", "packageName", "provenance"],
      "properties": {
        "path": {"$ref": "#/$defs/portablePath"}, "moduleId": {"$ref": "#/$defs/moduleId"},
        "packageName": {"type": "string", "minLength": 1},
        "provenance": {"$ref": "#/$defs/sourceProvenance"}
      }
    },
    "position": {
      "type": "object", "additionalProperties": false,
      "required": ["line", "column", "byteOffset"],
      "properties": {
        "line": {"type": "integer", "minimum": 1, "maximum": 9223372036854775807}, "column": {"type": "integer", "minimum": 1, "maximum": 9223372036854775807},
        "byteOffset": {"type": "integer", "minimum": 0, "maximum": 9223372036854775807}
      }
    },
    "sourceRange": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "start", "end"],
      "properties": {
        "path": {"$ref": "#/$defs/portablePath"}, "start": {"$ref": "#/$defs/position"},
        "end": {"$ref": "#/$defs/position"}
      }
    },
    "semanticType": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "canonical", "provider"],
      "properties": {
        "state": {"$ref": "#/$defs/semanticState"}, "canonical": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1, "pattern": "\\\\S"}]},
        "provider": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1}]}
      },
      "allOf": [
        {"if": {"properties": {"state": {"const": "unavailable"}}},
          "then": {"properties": {"canonical": {"type": "null"}, "provider": {"type": "null"}}},
          "else": {"properties": {"provider": {"type": "string", "minLength": 1}}}},
        {"if": {"properties": {"state": {"const": "resolved"}}},
          "then": {"properties": {"canonical": {"type": "string", "minLength": 1}}}}
      ]
    },
    "typeRef": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "spelling", "nullable", "arguments", "semanticState", "semanticCanonical", "semanticProvider", "navigation"],
      "properties": {
        "kind": {"type": "string", "minLength": 1}, "spelling": {"type": "string"},
        "nullable": {"type": "boolean"}, "arguments": {"type": "array", "items": {"$ref": "#/$defs/typeRef"}},
        "semanticState": {"$ref": "#/$defs/semanticState"},
        "semanticCanonical": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1, "pattern": "\\\\S"}]},
        "semanticProvider": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1}]},
        "navigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}
      },
      "allOf": [
        {"if": {"properties": {"semanticState": {"const": "unavailable"}}},
          "then": {"properties": {"semanticCanonical": {"type": "null"}, "semanticProvider": {"type": "null"}}},
          "else": {"properties": {"semanticProvider": {"type": "string", "minLength": 1}}}},
        {"if": {"properties": {"semanticState": {"const": "resolved"}}},
          "then": {"properties": {"semanticCanonical": {"type": "string", "minLength": 1}}}}
      ]

    },
    "parameter": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "type", "documentation", "defaultExpression"],
      "properties": {
        "name": {"type": "string"}, "type": {"$ref": "#/$defs/typeRef"},
        "documentation": {"$ref": "#/$defs/nullableString"}, "defaultExpression": {"$ref": "#/$defs/nullableString"}
      }
    },
"""

internal let DOC_IR_DECLARATIONS = """
    "semanticInfo": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "provider", "canonicalSignature"],
      "properties": {
        "state": {"$ref": "#/$defs/semanticState"}, "provider": {"type": "string", "minLength": 1},
        "canonicalSignature": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1, "pattern": "\\\\S"}]}
      }
    },
    "sourceApiSignature": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "tokens"],
      "properties": {
        "state": {"enum": ["available", "unavailable"]},
        "tokens": {"type": "array", "items": {"type": "string", "minLength": 1}}
      },
      "allOf": [
        {"if": {"properties": {"state": {"const": "available"}}},
          "then": {"properties": {"tokens": {"minItems": 1}}}},
        {"if": {"properties": {"state": {"const": "unavailable"}}},
          "then": {"properties": {"tokens": {"maxItems": 0}}}}
      ]
    },
    "origin": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "macroSymbolId"],
      "properties": {"kind": {"type": "string", "minLength": 1}, "macroSymbolId": {"$ref": "#/$defs/nullableSymbolId"}}
    },
    "annotation": {
      "type": "object", "additionalProperties": false,
      "required": ["spelling", "provenance", "provider"],
      "properties": {
        "spelling": {"type": "string", "minLength": 1},
        "provenance": {"enum": ["source", "provider"]},
        "provider": {"$ref": "#/$defs/nullableString"}
      },
      "allOf": [
        {"if": {"properties": {"provenance": {"const": "source"}}}, "then": {"properties": {"provider": {"type": "null"}}}},
        {"if": {"properties": {"provenance": {"const": "provider"}}}, "then": {"properties": {"provider": {"type": "string", "minLength": 1}}}}
      ]
    },
    "typeRelationship": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "target"],
      "properties": {"kind": {"type": "string", "minLength": 1}, "target": {"$ref": "#/$defs/typeRef"}}
    },
    "symbolRelationship": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "targetDisplay", "state", "targetSymbolId"],
      "properties": {
        "kind": {"type": "string", "minLength": 1}, "targetDisplay": {"type": "string"},
        "state": {"$ref": "#/$defs/semanticState"}, "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"}
      }
    },
    "declaration": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations", "typeRelationships", "symbolRelationships", "documentation", "source", "headerSpelling", "sourceApiSignature", "semantic", "origin", "enumNonExhaustive"],
      "properties": {
        "id": {"$ref": "#/$defs/symbolId"}, "kind": {"type": "string", "minLength": 1},
        "name": {"type": "string"}, "qualifiedName": {"type": "string", "minLength": 1},
        "packageName": {"type": "string", "minLength": 1}, "ownerId": {"$ref": "#/$defs/nullableSymbolId"},
        "moduleId": {"$ref": "#/$defs/moduleId"},
        "visibility": {"enum": ["public", "protected", "internal", "private"]},
        "genericParameters": {"$ref": "#/$defs/stringArray"},
        "parameters": {"type": "array", "items": {"$ref": "#/$defs/parameter"}},
        "returnType": {"anyOf": [{"$ref": "#/$defs/typeRef"}, {"type": "null"}]},
        "annotations": {"type": "array", "items": {"$ref": "#/$defs/annotation"}},
        "typeRelationships": {"type": "array", "items": {"$ref": "#/$defs/typeRelationship"}},
        "symbolRelationships": {"type": "array", "items": {"$ref": "#/$defs/symbolRelationship"}},
        "documentation": {"anyOf": [{"$ref": "#/$defs/comment"}, {"type": "null"}]},
        "source": {"$ref": "#/$defs/sourceRange"}, "headerSpelling": {"type": "string"},
        "sourceApiSignature": {"$ref": "#/$defs/sourceApiSignature"},
        "semantic": {"$ref": "#/$defs/semanticInfo"}, "origin": {"$ref": "#/$defs/origin"},
        "enumNonExhaustive": {"type": ["boolean", "null"]},
        "signatureHighlight": {
          "type": "object", "additionalProperties": false,
          "required": ["language", "sourceHash", "byteLength", "engineId", "engineRevision", "state", "reason", "spans"],
          "properties": {
            "language": {"type": "string"},
            "sourceHash": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
            "byteLength": {"type": "integer", "minimum": 0},
            "engineId": {"type": "string", "minLength": 1},
            "engineRevision": {"type": "string", "minLength": 1},
            "state": {"enum": ["complete", "partial", "plain"]},
            "reason": {"type": ["string", "null"], "enum": ["disabled", "no-language", "unsupported", "missing-metadata", "backend-unavailable", "invalid-spans", "resource-limit", "lexer-failed", "unterminated-token", null]},
            "spans": {"type": "array", "maxItems": 65536, "items": {
              "type": "object", "additionalProperties": false,
              "required": ["startByte", "endByte", "kind"],
              "properties": {
                "startByte": {"type": "integer", "minimum": 0},
                "endByte": {"type": "integer", "minimum": 1},
                "kind": {"enum": ["keyword", "type", "string", "number", "literal", "comment", "operator", "punctuation", "function", "property", "meta"]}
              }
            }}
          }
        }
      }
    },
"""
