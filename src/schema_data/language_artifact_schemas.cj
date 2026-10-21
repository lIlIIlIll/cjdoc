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

public let SEARCH_INDEX_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/search-index-v9.schema.json",
  "title": "cjdoc search index v8",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "entries"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.search-index/9"},
    "entries": {
      "type": "array",
      "items": {
        "type": "object", "additionalProperties": false,
        "required": ["id", "canonicalId", "exposure", "name", "qualifiedName", "kind", "packageName", "summary", "href"],
        "properties": {
          "id": {"type": "string", "minLength": 1},
          "canonicalId": {"type": "string", "pattern": "^(cjdoc:v2:|cjdoc:concept:).+$"},
          "exposure": {"type": "boolean"}, "name": {"type": "string"},
          "qualifiedName": {"type": "string", "minLength": 1}, "kind": {"type": "string", "minLength": 1},
          "packageName": {"anyOf": [{"type": "string", "minLength": 1}, {"const": ""}]}, "moduleId": {"type": "string", "minLength": 1}, "moduleName": {"type": ["string", "null"]}, "ownerName": {"type": ["string", "null"]}, "parameterTypes": {"type": "array", "items": {"type": "string"}}, "returnType": {"type": ["string", "null"]}, "returnCanonical": {"type": ["string", "null"]}, "summary": {"type": "string"}, "body": {"type": "string"},
          "sections": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["kind", "anchor", "text"], "properties": {"kind": {"type": "string", "minLength": 1}, "anchor": {"type": "string", "minLength": 1}, "text": {"type": "string"}}}},
          "href": {"type": "string", "pattern": "^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\).+$"},
          "bindings": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["target", "state", "selector", "provenance", "version", "language", "sourceLine", "targetSymbolId"], "properties": {"target": {"type": "string", "minLength": 1}, "state": {"type": "string", "minLength": 1}, "selector": {"type": "string"}, "provenance": {"type": "string"}, "version": {"type": "string"}, "language": {"type": "string", "minLength": 1}, "sourceLine": {"type": "integer", "minimum": 1}, "targetSymbolId": {"type": ["string", "null"]}}}},
          "fields": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["kind", "subject", "actualLanguage", "state", "text"], "properties": {"kind": {"type": "string"}, "subject": {"type": "string"}, "actualLanguage": {"enum": ["zh-CN", "en", null]}, "state": {"enum": ["complete", "fallback", "empty-fallback", "conflict-fallback", "empty", "conflict", "missing", "unknown", "unpaired"]}, "text": {"type": "string"}}}},
          "externalDocs": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["name", "state", "url", "reason", "version", "index", "format", "fingerprint"], "properties": {"name": {"type": "string", "minLength": 1}, "state": {"type": "string", "minLength": 1}, "url": {"type": "string"}, "reason": {"type": "string"}, "version": {"type": "string"}, "index": {"type": "string"}, "format": {"type": "string"}, "fingerprint": {"type": "string"}}}}
        }
      }
    }
  }
}
"""

public let TRANSLATION_COVERAGE_SCHEMA = """
{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/translation-coverage.schema.json","title":"cjdoc translation coverage v1","type":"object","additionalProperties":false,"required":["schemaVersion","languages"],"properties":{"schemaVersion":{"const":"cjdoc.translation-coverage/1"},"languages":{"type":"array","maxItems":2,"items":{"type":"object","additionalProperties":false,"required":["language","total","translated","percent","fallback","missing","empty","unknown","conflict","unpaired","entries"],"properties":{"language":{"enum":["en","zh-CN"]},"total":{"type":"integer","minimum":0},"translated":{"type":"integer","minimum":0},"percent":{"type":"integer","minimum":0,"maximum":100},"fallback":{"type":"integer","minimum":0},"missing":{"type":"integer","minimum":0},"empty":{"type":"integer","minimum":0},"unknown":{"type":"integer","minimum":0},"conflict":{"type":"integer","minimum":0},"unpaired":{"type":"integer","minimum":0},"entries":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["symbolId","fieldId","kind","subject","state","actualLanguage"],"properties":{"symbolId":{"type":["string","null"]},"fieldId":{"type":"string"},"kind":{"type":"string"},"subject":{"type":"string"},"state":{"enum":["complete","fallback","missing","empty","unknown","conflict","unpaired"]},"actualLanguage":{"enum":["en","zh-CN",null]}}}}}}}}}
"""

public let SITE_MANIFEST_SCHEMA = """
{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/site-manifest.schema.json","title":"cjdoc site manifest v1","type":"object","additionalProperties":false,"required":["schemaVersion","project","version","routes"],"properties":{"schemaVersion":{"const":"cjdoc.site-manifest/1"},"project":{"type":"string"},"version":{"type":["string","null"]},"defaultLanguage":{"enum":["en","zh-CN",null]},"routes":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["language","pageId","symbolId","sectionId","href"],"properties":{"language":{"enum":["en","zh-CN"]},"pageId":{"type":["string","null"]},"symbolId":{"type":["string","null"]},"sectionId":{"type":["string","null"]},"ownerSymbolId":{"type":["string","null"]},"href":{"type":"string"}}}}}}
"""
