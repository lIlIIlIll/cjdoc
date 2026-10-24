package cjdoc.schema_data

import yjson.*

// Versioned contracts for the agent-readable artifacts that the HTML renderer
// actually deploys under the document root. Each published schema is
// self-contained so a consumer never needs a network resolver, and each avoids
// regular-expression lookaround so the native linear-regex validator can
// evaluate it.
//
// Doc IR v16 stays the single definition of a declaration, a documentation page,
// a package and a document-set identity. The declaration, page and manifest
// templates below reference those definition names, and
// `completeDocumentationSchema` merges the frozen v16 `$defs` in rather than
// cloning a second model.

/**
 * `navigation-index.json` plus its `navigation-index-part-N.json` continuations.
 *
 * Every part repeats the same scope and pagination metadata so a consumer that
 * starts from any continuation can still name the snapshot, query parameters
 * and position. `next` is a document-root-relative path, matching `pages[].href`.
 */
public let NAVIGATION_INDEX_V2_SCHEMA = ##"{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/navigation-index-v2.schema.json",
  "title": "cjdoc agent navigation index v2",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "project", "scope", "queryId", "apiCollectionState", "completeness", "pagination", "pages"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.navigation-index/2"},
    "project": {"$ref": "#/$defs/project"},
    "scope": {"$ref": "#/$defs/scope"},
    "queryId": {"type": "string", "pattern": "^cjdoc:query:v1:[0-9a-f]{64}$"},
    "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]},
    "completeness": {
      "type": "object", "additionalProperties": false,
      "required": ["enumerationComplete", "contentComplete"],
      "properties": {
        "enumerationComplete": {"type": "boolean"},
        "contentComplete": {"type": "boolean"}
      }
    },
    "pagination": {
      "type": "object", "additionalProperties": false,
      "required": ["offset", "returned", "total", "part", "parts", "next", "pathBase"],
      "properties": {
        "offset": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "returned": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "total": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "part": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "parts": {"type": "integer", "minimum": 1, "maximum": 1000000},
        "next": {"anyOf": [{"$ref": "#/$defs/safePath"}, {"type": "null"}]},
        "pathBase": {"const": "document-root"}
      }
    },
    "pages": {"type": "array", "maxItems": 1000000, "items": {"$ref": "#/$defs/page"}}
  },
  "allOf": [
    {"if": {"required": ["pagination"], "properties": {"pagination": {"required": ["parts"],
      "properties": {"parts": {"const": 1}}}}},
     "then": {"required": ["completeness"], "properties": {"completeness": {
       "required": ["enumerationComplete"],
       "properties": {"enumerationComplete": {"const": true}}}}}},
    {"if": {"required": ["pagination"], "properties": {"pagination": {"required": ["parts"],
      "properties": {"parts": {"minimum": 2}}}}},
     "then": {"required": ["completeness"], "properties": {"completeness": {
       "required": ["enumerationComplete"],
       "properties": {"enumerationComplete": {"const": false}}}}}}
  ],
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "not": {"anyOf": [
        {"pattern": "^/"},
        {"pattern": "\\\\"},
        {"pattern": ":"},
        {"pattern": "[?]"},
        {"pattern": "[#]"},
        {"pattern": "(^|/)[.][.]?(/|$)"},
        {"pattern": "//"},
        {"pattern": "/$"}
      ]}
    },
    "scope": {
      "type": "object", "additionalProperties": false,
      "required": ["snapshotId", "audience", "language", "order", "includeValidation"],
      "properties": {
        "snapshotId": {"type": "string", "pattern": "^cjdoc:snapshot:v1:[0-9a-f]{64}$"},
        "audience": {"enum": ["external", "package", "all"]},
        "language": {"type": "string"},
        "order": {"const": "href,id"},
        "includeValidation": {"type": "boolean"}
      }
    },
    "project": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "audience", "version"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "audience": {"enum": ["external", "package", "all"]},
        "version": {"anyOf": [{"type": "string", "minLength": 1}, {"type": "null"}]}
      }
    },
    "page": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "kind", "title", "href", "summary", "summaryState", "symbolId", "moduleId", "packageName", "semanticState"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "kind": {"type": "string", "minLength": 1},
        "title": {"type": "string"},
        "href": {"$ref": "#/$defs/safePath"},
        "summary": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "summaryState": {"enum": ["complete", "missing", "budget_omitted"]},
        "symbolId": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "moduleId": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "packageName": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "semanticState": {"anyOf": [{"type": "string"}, {"type": "null"}]}
      },
      "allOf": [
        {"if": {"required": ["summaryState"], "properties": {"summaryState": {"const": "complete"}}},
         "then": {"properties": {"summary": {"type": "string"}}}},
        {"if": {"required": ["summaryState"], "properties": {"summaryState": {"const": "missing"}}},
         "then": {"properties": {"summary": {"type": "null"}}}},
        {"if": {"required": ["summaryState"], "properties": {"summaryState": {"const": "budget_omitted"}}},
         "then": {"properties": {"summary": {"type": "string"}}}}
      ]
    }
  }
}"##

/**
 * `agent-full-index.json`: the part manifest for `llms-full.txt` and its
 * `llms-full-part-N.txt` continuations. A part records the digest of the exact
 * bytes it published, so a consumer can detect a truncated or replaced part
 * instead of trusting a syntactically valid text file.
 */
public let AGENT_FULL_INDEX_SCHEMA = ##"{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/agent-full-index.schema.json",
  "title": "cjdoc agent full-reference index",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "snapshotId", "audience", "language", "apiCollectionState", "completeness", "order", "unitCount", "partByteLimit", "parts"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.agent-full-index/1"},
    "snapshotId": {"type": "string", "pattern": "^cjdoc:snapshot:v1:[0-9a-f]{64}$"},
    "audience": {"enum": ["external", "package", "all"]},
    "language": {"type": "string"},
    "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]},
    "completeness": {"type": "object", "additionalProperties": false,
      "required": ["enumerationComplete", "contentComplete"], "properties": {
        "enumerationComplete": {"const": true}, "contentComplete": {"type": "boolean"}}},
    "order": {"const": "kind,id"},
    "unitCount": {"type": "integer", "minimum": 0, "maximum": 1000000},
    "partByteLimit": {"type": "integer", "minimum": 1, "maximum": 67108864},
    "parts": {"type": "array", "minItems": 1, "maxItems": 100000, "items": {"$ref": "#/$defs/part"}}
  },
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "not": {"anyOf": [
        {"pattern": "^/"},
        {"pattern": "\\\\"},
        {"pattern": ":"},
        {"pattern": "[?]"},
        {"pattern": "[#]"},
        {"pattern": "(^|/)[.][.]?(/|$)"},
        {"pattern": "//"},
        {"pattern": "/$"}
      ]}
    },
    "omittedSection": {
      "type": "object", "additionalProperties": false,
      "required": ["unitId", "sections", "reason", "next"],
      "properties": {
        "unitId": {"type": "string", "minLength": 1},
        "sections": {"type": "array", "minItems": 1, "maxItems": 1, "items": {"const": "reference"}},
        "reason": {"const": "aggregate_unit_budget"},
        "next": {"$ref": "#/$defs/safePath"}
      }
    },
    "part": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "offset", "returned", "bytes", "sha256", "contentComplete", "next", "omittedSections"],
      "properties": {
        "path": {"$ref": "#/$defs/safePath"},
        "offset": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "returned": {"type": "integer", "minimum": 0, "maximum": 1000000},
        "bytes": {"type": "integer", "minimum": 0, "maximum": 67108864},
        "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "contentComplete": {"type": "boolean"},
        "next": {"anyOf": [{"$ref": "#/$defs/safePath"}, {"type": "null"}]},
        "omittedSections": {"type": "array", "maxItems": 1000000, "items": {"$ref": "#/$defs/omittedSection"}}
      },
      "allOf": [
        {"if": {"required": ["omittedSections"], "properties": {"omittedSections": {"minItems": 1}}},
         "then": {"properties": {"contentComplete": {"const": false}}}}
      ]
    }
  }
}"##

/**
 * `agent/symbols/symbol-<slug>.json`: one audience/cfg-visible declaration with
 * its unchanged Doc IR `symbol`, its document-set identity, exact source range
 * and the same Markdown that the sibling `.md` representation carries.
 */
public let DECLARATION_SCHEMA_TEMPLATE = ##"{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/declaration.schema.json",
  "title": "cjdoc independent declaration representation",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "scope", "symbolKey", "dependencyInstanceId", "symbol", "representations", "source", "diagnostics", "documentationState", "exampleEvidence", "markdown"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.declaration/1"},
    "scope": {"$ref": "#/$defs/declarationScope"},
    "symbolKey": {"type": "string", "minLength": 1},
    "dependencyInstanceId": {"anyOf": [{"type": "string", "minLength": 1}, {"type": "null"}]},
    "symbol": {"$ref": "#/$defs/declaration"},
    "representations": {"$ref": "#/$defs/representations"},
    "source": {"$ref": "#/$defs/declarationSource"},
    "diagnostics": {"type": "array", "maxItems": 1000000, "items": {"$ref": "#/$defs/diagnostic"}},
    "documentationState": {"enum": ["available", "missing"]},
    "exampleEvidence": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "reports", "reason"],
      "properties": {
        "state": {"const": "not_attached"},
        "reports": {"type": "array", "maxItems": 0},
        "reason": {"type": "string", "minLength": 1}
      }
    },
    "markdown": {"type": "string"}
  },
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "not": {"anyOf": [
        {"pattern": "^/"},
        {"pattern": "\\\\"},
        {"pattern": ":"},
        {"pattern": "[?]"},
        {"pattern": "[#]"},
        {"pattern": "(^|/)[.][.]?(/|$)"},
        {"pattern": "//"},
        {"pattern": "/$"}
      ]}
    },
    "declarationScope": {
      "type": "object", "additionalProperties": false,
      "required": ["snapshotId", "audience", "cfgProfile", "readingLanguage", "apiCollectionState", "publicationRevision", "documentSet"],
      "properties": {
        "snapshotId": {"type": "string", "pattern": "^cjdoc:snapshot:v1:[0-9a-f]{64}$"},
        "audience": {"enum": ["external", "package", "all"]},
        "cfgProfile": {"type": "string", "minLength": 1},
        "readingLanguage": {"type": "string"},
        "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]},
        "publicationRevision": {"type": "string"},
        "documentSet": {"anyOf": [{"$ref": "#/$defs/documentSetIdentity"}, {"type": "null"}]}
      }
    },
    "representations": {
      "type": "object", "additionalProperties": false,
      "required": ["pathBase", "html", "markdown", "json"],
      "properties": {
        "pathBase": {"const": "document-root"},
        "html": {"$ref": "#/$defs/safePath"},
        "markdown": {"$ref": "#/$defs/safePath"},
        "json": {"$ref": "#/$defs/safePath"}
      }
    },
    "declarationSource": {
      "type": "object", "additionalProperties": false,
      "required": ["url", "range", "recordedRevision", "revisionKind"],
      "properties": {
        "url": {"$ref": "#/$defs/nullableString"},
        "range": {"$ref": "#/$defs/sourceRange"},
        "recordedRevision": {"$ref": "#/$defs/nullableString"},
        "revisionKind": {"enum": ["recorded", "unavailable"]}
      }
    }
  }
}"##

/**
 * `agent/pages/page-<slug>.json`: a selected conceptual page, a package
 * directory or the project index. A concept carries its captured
 * `documentationPage` and no package; a package carries its `package` record and
 * no page; the project index carries neither. No variant fabricates a symbol id.
 */
public let PAGE_SCHEMA_TEMPLATE = ##"{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/page.schema.json",
  "title": "cjdoc page representation",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "id", "kind", "scope", "page", "package", "representations", "markdown"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.page/1"},
    "id": {"type": "string", "minLength": 1},
    "kind": {"enum": ["concept", "package", "project"]},
    "scope": {"$ref": "#/$defs/pageScope"},
    "page": {"anyOf": [{"$ref": "#/$defs/documentationPage"}, {"type": "null"}]},
    "package": {"anyOf": [{"$ref": "#/$defs/package"}, {"type": "null"}]},
    "representations": {"$ref": "#/$defs/representations"},
    "markdown": {"type": "string"}
  },
  "allOf": [
    {"if": {"required": ["kind"], "properties": {"kind": {"const": "concept"}}},
     "then": {"properties": {"page": {"type": "object"}, "package": {"type": "null"}}}},
    {"if": {"required": ["kind"], "properties": {"kind": {"const": "package"}}},
     "then": {"properties": {"package": {"type": "object"}, "page": {"type": "null"}}}},
    {"if": {"required": ["kind"], "properties": {"kind": {"const": "project"}}},
     "then": {"properties": {"page": {"type": "null"}, "package": {"type": "null"}}}}
  ],
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "not": {"anyOf": [
        {"pattern": "^/"},
        {"pattern": "\\\\"},
        {"pattern": ":"},
        {"pattern": "[?]"},
        {"pattern": "[#]"},
        {"pattern": "(^|/)[.][.]?(/|$)"},
        {"pattern": "//"},
        {"pattern": "/$"}
      ]}
    },
    "pageScope": {
      "type": "object", "additionalProperties": false,
      "required": ["snapshotId", "audience", "cfgProfile", "readingLanguage", "apiCollectionState", "publicationRevision", "documentSet"],
      "properties": {
        "snapshotId": {"type": "string", "pattern": "^cjdoc:snapshot:v1:[0-9a-f]{64}$"},
        "audience": {"enum": ["external", "package", "all"]},
        "cfgProfile": {"type": "string", "minLength": 1},
        "readingLanguage": {"type": "string"},
        "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]},
        "publicationRevision": {"type": "string"},
        "documentSet": {"anyOf": [{"$ref": "#/$defs/documentSetIdentity"}, {"type": "null"}]}
      }
    },
    "representations": {
      "type": "object", "additionalProperties": false,
      "required": ["pathBase", "html", "markdown", "json"],
      "properties": {
        "pathBase": {"const": "document-root"},
        "html": {"$ref": "#/$defs/safePath"},
        "markdown": {"$ref": "#/$defs/safePath"},
        "json": {"$ref": "#/$defs/safePath"}
      }
    }
  }
}"##

/**
 * `agent/manifest.json`: the deployed representation map for one document root.
 *
 * It names the packaged Doc IR and symbol inventory with their digests, lists
 * every resource that the document root actually carries, and keeps optional
 * report attachments as a strict row shape. `reports` is `[]` when no report was
 * packaged; this schema does not claim a report exists or binds one.
 */
public let MACHINE_MANIFEST_SCHEMA_TEMPLATE = ##"{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/machine-manifest.schema.json",
  "title": "cjdoc machine manifest",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "snapshotId", "pathBase", "projection", "publicationRevision", "scope", "docIr", "symbolIndex", "documentSets", "representations", "resources", "reports", "fullReference", "limits"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.machine-manifest/1"},
    "snapshotId": {"type": "string", "pattern": "^cjdoc:snapshot:v1:[0-9a-f]{64}$"},
    "pathBase": {"const": "document-root"},
    "projection": {"const": "cjdoc.read/1"},
    "publicationRevision": {"type": "string"},
    "scope": {"$ref": "#/$defs/manifestScope"},
    "docIr": {"$ref": "#/$defs/docIrResource"},
    "symbolIndex": {"$ref": "#/$defs/symbolIndexResource"},
    "documentSets": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/documentSetIdentity"}},
    "representations": {"type": "array", "maxItems": 1000000, "items": {"$ref": "#/$defs/representation"}},
    "resources": {"description": "Complete immutable agent/ payload inventory; HTML representations are existing site artifacts whose chrome may be updated by language/version composition.", "type": "array", "maxItems": 1000000, "items": {"$ref": "#/$defs/resource"}},
    "reports": {"type": "array", "maxItems": 2, "items": {"$ref": "#/$defs/report"}},
    "fullReference": {"anyOf": [{"const": "agent-full-index.json"}, {"type": "null"}]},
    "limits": {"$ref": "#/$defs/limits"}
  },
  "$defs": {
    "safePath": {
      "type": "string", "minLength": 1,
      "not": {"anyOf": [
        {"pattern": "^/"},
        {"pattern": "\\\\"},
        {"pattern": ":"},
        {"pattern": "[?]"},
        {"pattern": "[#]"},
        {"pattern": "(^|/)[.][.]?(/|$)"},
        {"pattern": "//"},
        {"pattern": "/$"}
      ]}
    },
    "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "manifestScope": {
      "type": "object", "additionalProperties": false,
      "required": ["snapshotId", "audience", "cfgProfile", "readingLanguage", "apiCollectionState", "publicationRevision", "documentSet"],
      "properties": {
        "snapshotId": {"type": "string", "pattern": "^cjdoc:snapshot:v1:[0-9a-f]{64}$"},
        "audience": {"enum": ["external", "package", "all"]},
        "cfgProfile": {"type": "string", "minLength": 1},
        "readingLanguage": {"type": "string"},
        "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]},
        "publicationRevision": {"type": "string"},
        "documentSet": {"type": "null"}
      }
    },
    "docIrResource": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "sha256"],
      "properties": {
        "path": {"const": "agent/docs.json"},
        "sha256": {"$ref": "#/$defs/sha256"}
      }
    },
    "symbolIndexResource": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "sha256"],
      "properties": {
        "path": {"const": "agent/symbol-index.json"},
        "sha256": {"$ref": "#/$defs/sha256"}
      }
    },
    "representation": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "id", "html", "markdown", "json"],
      "properties": {
        "kind": {"enum": ["symbol", "concept", "package", "project"]},
        "id": {"type": "string", "minLength": 1},
        "html": {"$ref": "#/$defs/safePath"},
        "markdown": {"$ref": "#/$defs/safePath"},
        "json": {"$ref": "#/$defs/safePath"}
      }
    },
    "resource": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "mediaType", "bytes", "sha256"],
      "properties": {
        "path": {"allOf": [{"$ref": "#/$defs/safePath"}, {"pattern": "^agent/"}]},
        "mediaType": {"type": "string", "minLength": 1},
        "bytes": {"type": "integer", "minimum": 0, "maximum": 67108864},
        "sha256": {"$ref": "#/$defs/sha256"}
      }
    },
    "report": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "path", "sha256", "snapshotId", "baselineSnapshotId", "currentSnapshotId"],
      "properties": {
        "kind": {"enum": ["validation", "api-diff"]},
        "path": {"allOf": [{"$ref": "#/$defs/safePath"}, {"pattern": "^agent/"}]},
        "sha256": {"$ref": "#/$defs/sha256"},
        "snapshotId": {"type": "string", "minLength": 1},
        "baselineSnapshotId": {"anyOf": [{"type": "string", "minLength": 1}, {"type": "null"}]},
        "currentSnapshotId": {"anyOf": [{"type": "string", "minLength": 1}, {"type": "null"}]}
      }
    },
    "limits": {
      "type": "object", "additionalProperties": false,
      "required": ["navigationPartBytes", "fullPartBytes", "summaryBytes", "artifactBytes", "totalArtifactBytes", "artifactCount"],
      "properties": {
        "navigationPartBytes": {"const": 16777216},
        "fullPartBytes": {"const": 16777216},
        "summaryBytes": {"const": 16384},
        "artifactBytes": {"const": 67108864},
        "totalArtifactBytes": {"const": 536870912},
        "artifactCount": {"const": 65536}
      }
    }
  }
}"##

/**
 * Return a template with the frozen Doc IR v16 `$defs` merged in.
 *
 * The merge is a copy of the existing definition objects, so the published
 * artifact schema stays self-contained and `$ref: "#/$defs/declaration"` still
 * means the single Doc IR declaration model. A template may not shadow a v16
 * definition: that would fork the model rather than reuse it.
 */
public func completeDocumentationSchema(template: String): String {
    let schema = JsonNode.parse(template).asObject()
    let definitions = match (schema.get("$defs")) {
        case Some(node) => node.asObject()
        case None => throw IllegalArgumentException("artifact schema template has no $defs")
    }
    let frozen = JsonNode.parse(DOC_IR_V16_SCHEMA).asObject().get("$defs").getOrThrow().asObject()
    for (index in 0..frozen.size()) {
        let name = frozen.nameAt(index)
        if (definitions.contains(name)) {
            throw IllegalArgumentException("artifact schema redefines Doc IR definition '${name}'")
        }
        definitions.put(name, frozen.valueAt(index))
    }
    schema.toJson()
}

/**
 * Return the exact strict, self-contained schema for one static agent artifact.
 *
 * Query request/result schemas belong to the query contract module; this
 * function covers only artifacts the HTML renderer deploys.
 */
public func documentationArtifactSchema(name: String): String {
    match (name) {
        case "navigation-index-v2" => NAVIGATION_INDEX_V2_SCHEMA
        case "agent-full-index" => AGENT_FULL_INDEX_SCHEMA
        case "declaration" => completeDocumentationSchema(DECLARATION_SCHEMA_TEMPLATE)
        case "page" => completeDocumentationSchema(PAGE_SCHEMA_TEMPLATE)
        case "machine-manifest" => completeDocumentationSchema(MACHINE_MANIFEST_SCHEMA_TEMPLATE)
        case _ => throw IllegalArgumentException("unknown agent artifact schema '${name}'")
    }
}
