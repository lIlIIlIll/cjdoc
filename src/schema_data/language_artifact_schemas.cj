package cjdoc.schema_data

// Current distribution-time schema contracts; docs/schema copies are emitted by cjdoc schema.
public let VERSIONS_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/versions-v2.schema.json",
  "title": "cjdoc composed documentation versions",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "project", "latest", "latestPolicy", "versions"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.versions/2"},
    "project": {"type": "string", "minLength": 1},
    "latest": {"type": "string", "minLength": 1},
    "latestPolicy": {"enum": ["explicit", "first-listed"]},
    "versions": {"type": "array", "minItems": 1, "maxItems": 64, "items": {"$ref": "#/$defs/version"}}
  },
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "pattern": "^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\)(?!.*(^|/)[.][.]?(/|$))(?!.*(^|/)latest(/|$)).+$"
    },
    "version": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "label", "basePath", "channel", "status", "index", "symbolIndex", "apiDiff"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "label": {"type": "string", "minLength": 1},
        "basePath": {"$ref": "#/$defs/safePath"},
        "channel": {"type": "string", "minLength": 1},
        "status": {"type": "string", "minLength": 1},
        "index": {"$ref": "#/$defs/safePath"},
        "symbolIndex": {"anyOf": [{"$ref": "#/$defs/safePath"}, {"type": "null"}]},
        "apiDiff": {"anyOf": [{"$ref": "#/$defs/safePath"}, {"type": "null"}]},
        "release": {"type": "string", "minLength": 1},
        "languages": {"type": "array", "maxItems": 2, "items": {"type": "object", "additionalProperties": false, "required": ["language", "root", "index"], "properties": {"language": {"enum": ["en", "zh-CN"]}, "root": {"$ref": "#/$defs/safePath"}, "index": {"$ref": "#/$defs/safePath"}}}}
      }
    }
  }
}
"""

public let API_SURFACE_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface-v3.schema.json",
  "title": "cjdoc API surface v3",
  "type": "object", "additionalProperties": false,
  "required": ["schemaVersion", "project", "audience", "cfgProfile", "collectionState", "declarations", "exposures"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.api-surface/3"},
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
      "required": ["id", "moduleId", "packageName", "ownerId", "kind", "name", "qualifiedName", "visibility", "sourceApiSignature", "genericParameters", "parameters", "return", "relationships", "enumNonExhaustive", "documentationFingerprint", "documentationLanguages", "sourceFingerprint", "metadataFingerprint", "collectionState"],
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
        "documentationFingerprint": {"$ref": "#/$defs/fingerprint"},
        "documentationLanguages": {"type": "array", "maxItems": 3, "items": {"type": "object", "additionalProperties": false, "required": ["language", "fingerprint"], "properties": {"language": {"enum": ["zh-CN", "en", null]}, "fingerprint": {"$ref": "#/$defs/fingerprint"}}}}, "sourceFingerprint": {"$ref": "#/$defs/fingerprint"},
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
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-diff-v2.schema.json",
  "title": "cjdoc API diff v2",
  "type": "object", "additionalProperties": false,
  "required": ["schemaVersion", "baseline", "current", "comparisonState", "summary", "entries"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.api-diff/2"},
    "baseline": {"$ref": "#/$defs/identity"}, "current": {"$ref": "#/$defs/identity"},
    "comparisonState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "summary": {"$ref": "#/$defs/summary"}, "entries": {"type": "array", "maxItems": 400000, "items": {"$ref": "#/$defs/entry"}}
  },
  "$defs": {
    "nullableString": {"anyOf": [{"type": "string"}, {"type": "null"}]},
    "identity": {"type": "object", "additionalProperties": false, "required": ["project", "audience", "cfgProfile", "schemaVersion", "collectionState"], "properties": {"project": {"type": "string", "minLength": 1}, "audience": {"type": "string", "minLength": 1}, "cfgProfile": {"type": "string", "minLength": 1}, "schemaVersion": {"type": "string", "minLength": 1}, "collectionState": {"type": "string", "minLength": 1}}},
    "summary": {"type": "object", "additionalProperties": false, "required": ["breaking", "potentiallyBreaking", "additive", "documentationOnly", "metadataOnly", "unchanged"], "properties": {"breaking": {"type": "integer", "minimum": 0}, "potentiallyBreaking": {"type": "integer", "minimum": 0}, "additive": {"type": "integer", "minimum": 0}, "documentationOnly": {"type": "integer", "minimum": 0}, "metadataOnly": {"type": "integer", "minimum": 0}, "unchanged": {"type": "integer", "minimum": 0}}},
    "evidence": {"type": "object", "additionalProperties": false, "required": ["field", "before", "after", "state", "language"], "properties": {"field": {"type": "string", "minLength": 1}, "language": {"enum": ["zh-CN", "en", null]}, "before": {"$ref": "#/$defs/nullableString"}, "after": {"$ref": "#/$defs/nullableString"}, "state": {"type": "string", "minLength": 1}}},
    "entry": {"type": "object", "additionalProperties": false, "required": ["oldId", "newId", "kind", "classification", "matchState", "reasons", "evidence"], "properties": {"oldId": {"$ref": "#/$defs/nullableString"}, "newId": {"$ref": "#/$defs/nullableString"}, "kind": {"type": "string", "minLength": 1}, "classification": {"enum": ["breaking", "potentially-breaking", "additive", "documentation-only", "metadata-only", "unchanged"]}, "matchState": {"type": "string", "minLength": 1}, "reasons": {"type": "array", "items": {"type": "string"}}, "evidence": {"type": "array", "items": {"$ref": "#/$defs/evidence"}}}}
  }
}
"""

private let SEARCH_INDEX_SCHEMA_TEMPLATE = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/search-index-v11.schema.json",
  "title": "cjdoc search index v11",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "profile", "contract", "projectionId", "scope", "coverage", "modules", "tags", "entries"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.search-index/11"},
    "profile": {"type": "string", "minLength": 1},
    "contract": {"$ref": "#/$defs/searchContract"},
    "projectionId": {"type": "string", "minLength": 1},
    "scope": {"type": "object", "additionalProperties": false,
      "required": ["snapshotId", "sourceSnapshotId", "publicationRevision", "project", "language",
        "audience", "cfgProfile", "apiCollectionState"],
      "properties": {
        "snapshotId": {"type": "string", "minLength": 1},
        "sourceSnapshotId": {"type": "string", "minLength": 1},
        "publicationRevision": {"type": "string"},
        "project": {"type": "string"},
        "language": {"type": "string", "minLength": 1},
        "audience": {"enum": ["external", "package", "all"]},
        "cfgProfile": {"type": "string"},
        "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]}
      }},
    "coverage": {"type": "object", "additionalProperties": false,
      "required": ["profile", "projectionId", "bodyTextLimit", "bodyComplete", "truncatedEntries"],
      "properties": {
        "profile": {"type": "string", "minLength": 1},
        "projectionId": {"type": "string", "minLength": 1},
        "bodyTextLimit": {"type": ["integer", "null"], "minimum": 0},
        "bodyComplete": {"type": "boolean"},
        "truncatedEntries": {"type": "integer", "minimum": 0}
      }},
    "modules": {"type": "array", "maxItems": 4096, "items": {"$ref": "#/$defs/module"}},
    "tags": {"type": "array", "items": {"$ref": "#/$defs/tagDictionaryEntry"}},
    "entries": {"type": "array", "items": {"$ref": "#/$defs/entry"}}
  },
  "$defs": {
    "nullableString": {"type": ["string", "null"]},
    "searchRule": {"type": "object", "additionalProperties": false,
      "required": ["primitive", "level", "score", "reason"],
      "properties": {
        "primitive": {"type": "string", "minLength": 1},
        "level": {"type": "integer"},
        "score": {"type": "integer"},
        "reason": {"type": "string", "minLength": 1}
      }},
    "filterField": {"type": "object", "additionalProperties": false,
      "required": ["field", "property", "context"],
      "properties": {
        "field": {"type": "string", "minLength": 1},
        "property": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]},
        "context": {"type": "string", "minLength": 1}
      }},
    "filterOp": {"type": "object", "additionalProperties": false,
      "required": ["op", "primitive"],
      "properties": {
        "op": {"type": "string", "minLength": 1},
        "primitive": {"type": "string", "minLength": 1}
      }},
    "searchContract": {"type": "object", "additionalProperties": false,
      "required": ["version", "maxRequestBytes", "textPolicy", "defaultMode", "defaultProfile", "defaultLimit", "maxLimit",
        "maxFilters", "maxTags", "staticBodyTextLimit", "summaryDisplayLimit", "signatureDisplayLimit",
        "requestProperties", "globalFields", "searchFields", "filterFields", "filterOps", "setPredicates",
        "preciseRules", "discoveryRules"],
      "properties": {
        "version": {"const": "cjdoc.search-contract/2"},
        "maxRequestBytes": {"type": "integer", "minimum": 1},
        "textPolicy": {"$ref": "#/$defs/textPolicy"},
        "defaultMode": {"type": "string", "minLength": 1},
        "defaultProfile": {"type": "string", "minLength": 1},
        "defaultLimit": {"type": "integer", "minimum": 0},
        "maxLimit": {"type": "integer", "minimum": 0},
        "maxFilters": {"type": "integer", "minimum": 0},
        "maxTags": {"type": "integer", "minimum": 1, "maximum": 64},
        "staticBodyTextLimit": {"type": "integer", "minimum": 0},
        "summaryDisplayLimit": {"type": "integer", "minimum": 0},
        "signatureDisplayLimit": {"type": "integer", "minimum": 0},
        "requestProperties": {"type": "object"},
        "globalFields": {"type": "array", "items": {"type": "string"}},
        "searchFields": {"type": "array", "items": {"type": "string"}},
        "filterFields": {"type": "array", "items": {"$ref": "#/$defs/filterField"}},
        "filterOps": {"type": "array", "items": {"$ref": "#/$defs/filterOp"}},
        "setPredicates": {"type": "array", "minItems": 1, "maxItems": 1,
          "items": {"type": "object", "additionalProperties": false,
            "required": ["field", "property", "primitive"],
            "properties": {
              "field": {"const": "tags"},
              "property": {"const": "tagIds"},
              "primitive": {"const": "all_exact"}
            }}},
        "preciseRules": {"type": "array", "items": {"$ref": "#/$defs/searchRule"}},
        "discoveryRules": {"type": "array", "items": {"$ref": "#/$defs/searchRule"}}
      }},
    "textPolicy": {"type": "object", "additionalProperties": false,
      "required": ["caseFold", "normalization", "tokens", "words", "edit", "minEditRunes", "maxEditRunes"],
      "properties": {
        "caseFold": {"const": "ascii-only"},
        "normalization": {"const": "none"},
        "tokens": {"const": "ascii-alnum-underscore-or-u0080-plus"},
        "words": {"const": "ascii-camel-acronym-boundaries"},
        "edit": {"const": "one-scalar-insert-delete-substitute"},
        "minEditRunes": {"type": "integer", "minimum": 1, "maximum": 128},
        "maxEditRunes": {"type": "integer", "minimum": 1, "maximum": 128}
      }},
    "documentSet": {"type": "object", "additionalProperties": false,
      "required": ["id", "moduleId", "library", "identity", "state", "source", "target", "cfg",
        "audience", "language", "revision", "apiVersion", "documentationRevision", "indexIdentity", "baseUrl"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "moduleId": {"type": "string"},
        "library": {"type": "string", "minLength": 1},
        "identity": {"type": "string"},
        "state": {"enum": ["observed", "verified", "declared", "unknown"]},
        "source": {"type": "string"},
        "target": {"type": "string"},
        "cfg": {"type": "string"},
        "audience": {"type": "string"},
        "language": {"type": "string"},
        "revision": {"type": "string"},
        "apiVersion": {"type": "string"},
        "documentationRevision": {"type": "string"},
        "indexIdentity": {"type": "string"},
        "baseUrl": {"type": "string"}
      }},
    "dependency": {"type": "object", "additionalProperties": false,
      "required": ["moduleId", "componentModuleId", "name", "instanceId", "kind", "identity",
        "state", "evidence", "version", "revision", "target", "cfg"],
      "properties": {
        "moduleId": {"type": "string", "minLength": 1},
        "componentModuleId": {"type": "string"},
        "name": {"type": "string", "minLength": 1},
        "instanceId": {"type": "string", "minLength": 1},
        "kind": {"enum": ["source", "binary", "std", "stdx", "toolchain"]},
        "identity": {"type": "string"},
        "state": {"enum": ["unknown", "declared", "observed", "verified", "conflict"]},
        "evidence": {"type": "string"},
        "version": {"type": "string"},
        "revision": {"type": "string"},
        "target": {"type": "string"},
        "cfg": {"type": "string"}
      }},
    "tagDictionaryEntry": {"type": "object", "additionalProperties": false,
      "required": ["scope", "id", "title"],
      "properties": {
        "scope": {"type": "integer", "minimum": 0, "maximum": 4095},
        "id": {"$ref": "#/$defs/classificationId"},
        "title": {"$ref": "#/$defs/classificationTitle"}
      }},
    "module": {"type": "object", "additionalProperties": false,
      "required": ["moduleId", "moduleName", "documentSet", "dependency",
        "dependencyInstanceState"],
      "properties": {
        "moduleId": {"type": "string", "minLength": 1},
        "moduleName": {"$ref": "#/$defs/nullableString"},
        "documentSet": {"anyOf": [{"$ref": "#/$defs/documentSet"}, {"type": "null"}]},
        "dependency": {"anyOf": [{"$ref": "#/$defs/dependency"}, {"type": "null"}]},
        "dependencyInstanceState": {"enum": ["recorded", "not_applicable", "unrecorded", "ambiguous"]}
      }},
    "navigation": {"type": "object", "additionalProperties": false,
      "required": ["state", "matchLevel", "reason", "dependencyInstanceId", "documentSetId",
        "indexIdentity", "symbolKey", "url", "apiIdentity", "language"],
      "properties": {
        "state": {"enum": ["resolved", "unresolved", "ambiguous", "unavailable"]},
        "matchLevel": {"enum": ["exact", "compatible", "manual", "none"]},
        "reason": {"type": "string", "minLength": 1},
        "dependencyInstanceId": {"type": "string"},
        "documentSetId": {"type": "string"},
        "indexIdentity": {"type": "string"},
        "symbolKey": {"type": "string"},
        "url": {"type": "string"},
        "apiIdentity": {"type": "string"},
        "language": {"type": "string"}
      }},
    "binding": {"type": "object", "additionalProperties": false,
      "required": ["target", "selector", "provenance", "version", "sourceLine", "language", "state",
        "targetSymbolId", "href", "navigationTitle", "navigation"],
      "properties": {
        "target": {"type": "string"},
        "selector": {"type": "string"},
        "provenance": {"type": "string"},
        "version": {"type": "string"},
        "sourceLine": {"type": "integer", "minimum": 1},
        "language": {"type": "string"},
        "state": {"enum": ["resolved", "unresolved", "ambiguous", "unavailable", "conflict"]},
        "targetSymbolId": {"$ref": "#/$defs/nullableString"},
        "href": {"$ref": "#/$defs/nullableString"},
        "navigationTitle": {"type": "string"},
        "navigation": {"anyOf": [
          {"type": "null"},
          {"$ref": "#/$defs/navigation"},
          {"type": "array", "prefixItems": [{"type": "string"}, {"type": "string"}],
            "items": false, "minItems": 2, "maxItems": 2}
        ]}
      }},
    "exposure": {"type": "object", "additionalProperties": false,
      "required": ["id", "name", "qualifiedName", "packageName", "scope"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "name": {"type": "string", "minLength": 1},
        "qualifiedName": {"type": "string", "minLength": 1},
        "packageName": {"type": "string", "minLength": 1},
        "scope": {"type": "integer", "minimum": 0, "maximum": 4095}
      }},
    "externalDoc": {"type": "object", "additionalProperties": false,
      "required": ["name", "state", "url", "reason", "version", "index", "format", "fingerprint"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "state": {"enum": ["available", "unavailable", "ambiguous"]},
        "url": {"type": "string"},
        "reason": {"type": "string"},
        "version": {"type": "string"},
        "index": {"type": "string"},
        "format": {"type": "string"},
        "fingerprint": {"type": "string"}
      }},
    "section": {"type": "object", "additionalProperties": false,
      "required": ["kind", "anchor", "text"],
      "properties": {
        "kind": {"type": "string", "minLength": 1},
        "anchor": {"type": "string", "minLength": 1},
        "text": {"type": "string"}
      }},
    "entry": {"type": "object", "additionalProperties": false,
      "required": ["id", "canonicalId", "snapshotId", "scope", "concept", "genericArity", "ownerId",
        "name", "packageName", "qualifiedName", "kind", "ownerName", "ownerQualifiedName", "symbolKey",
        "parameterTypes", "returnType", "returnCanonical", "summary", "summaryDisplay", "body",
        "bodyTruncated", "href", "exposures", "externalDocs", "bindings", "sections", "classification"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "canonicalId": {"type": "string", "minLength": 1},
        "snapshotId": {"type": "string", "minLength": 1},
        "scope": {"type": "integer", "minimum": -1},
        "concept": {"type": "boolean"},
        "genericArity": {"type": "integer", "minimum": 0},
        "ownerId": {"$ref": "#/$defs/nullableString"},
        "name": {"type": "string"},
        "packageName": {"$ref": "#/$defs/nullableString"},
        "qualifiedName": {"$ref": "#/$defs/nullableString"},
        "kind": {"type": "string", "minLength": 1},
        "ownerName": {"$ref": "#/$defs/nullableString"},
        "ownerQualifiedName": {"$ref": "#/$defs/nullableString"},
        "symbolKey": {"$ref": "#/$defs/nullableString"},
        "parameterTypes": {"type": "array", "items": {"type": "string"}},
        "returnType": {"$ref": "#/$defs/nullableString"},
        "returnCanonical": {"$ref": "#/$defs/nullableString"},
        "summary": {"type": "string"},
        "summaryDisplay": {"type": "string"},
        "body": {"type": "string"},
        "bodyTruncated": {"type": "boolean"},
        "href": {"type": "string", "pattern": "^.+$",
          "not": {"anyOf": [
            {"pattern": "^/"},
            {"pattern": "^[A-Za-z]:"},
            {"pattern": "^.*\\\\\\\\"}
          ]}},
        "exposures": {"type": "array", "items": {"$ref": "#/$defs/exposure"}},
        "externalDocs": {"type": "array", "items": {"$ref": "#/$defs/externalDoc"}},
        "bindings": {"type": "array", "items": {"$ref": "#/$defs/binding"}},
        "sections": {"type": "array", "items": {"$ref": "#/$defs/section"}},
        "classification": {"$ref": "#/$defs/documentationClassification"}
      },
      "allOf": [
        {"if": {"properties": {"concept": {"const": true}}},
          "then": {"properties": {"scope": {"const": -1}, "genericArity": {"const": 0},
            "ownerId": {"type": "null"}, "ownerName": {"type": "null"},
            "ownerQualifiedName": {"type": "null"}, "packageName": {"type": "null"},
            "qualifiedName": {"type": "null"},
            "symbolKey": {"type": "null"}, "returnType": {"type": "null"},
            "returnCanonical": {"type": "null"}, "parameterTypes": {"maxItems": 0},
            "classification": {"const": {"group": null, "tags": []}}}}},
        {"if": {"properties": {"concept": {"const": false}}},
          "then": {"properties": {"scope": {"minimum": 0}, "packageName": {"type": "string", "minLength": 1},
            "qualifiedName": {"type": "string", "minLength": 1}}}}
      ]
    }
  }
}
"""

public let SEARCH_INDEX_SCHEMA: String =
    documentationSchemaWithClassification(SEARCH_INDEX_SCHEMA_TEMPLATE)

public let TRANSLATION_COVERAGE_SCHEMA = """
{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/translation-coverage.schema.json","title":"cjdoc translation coverage v1","type":"object","additionalProperties":false,"required":["schemaVersion","languages"],"properties":{"schemaVersion":{"const":"cjdoc.translation-coverage/1"},"languages":{"type":"array","maxItems":2,"items":{"type":"object","additionalProperties":false,"required":["language","total","translated","percent","fallback","missing","empty","unknown","conflict","unpaired","entries"],"properties":{"language":{"enum":["en","zh-CN"]},"total":{"type":"integer","minimum":0},"translated":{"type":"integer","minimum":0},"percent":{"type":"integer","minimum":0,"maximum":100},"fallback":{"type":"integer","minimum":0},"missing":{"type":"integer","minimum":0},"empty":{"type":"integer","minimum":0},"unknown":{"type":"integer","minimum":0},"conflict":{"type":"integer","minimum":0},"unpaired":{"type":"integer","minimum":0},"entries":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["symbolId","fieldId","kind","subject","state","actualLanguage"],"properties":{"symbolId":{"type":["string","null"]},"fieldId":{"type":"string"},"kind":{"type":"string"},"subject":{"type":"string"},"state":{"enum":["complete","fallback","missing","empty","unknown","conflict","unpaired"]},"actualLanguage":{"enum":["en","zh-CN",null]}}}}}}}}}
"""

public let SITE_MANIFEST_SCHEMA = """
{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/site-manifest.schema.json","title":"cjdoc site manifest v1","type":"object","additionalProperties":false,"required":["schemaVersion","project","version","routes"],"properties":{"schemaVersion":{"const":"cjdoc.site-manifest/1"},"project":{"type":"string"},"version":{"type":["string","null"]},"defaultLanguage":{"enum":["en","zh-CN",null]},"routes":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["language","pageId","symbolId","sectionId","href"],"properties":{"language":{"enum":["en","zh-CN"]},"pageId":{"type":["string","null"]},"symbolId":{"type":["string","null"]},"sectionId":{"type":["string","null"]},"ownerSymbolId":{"type":["string","null"]},"href":{"type":"string"}}}}}}
"""
