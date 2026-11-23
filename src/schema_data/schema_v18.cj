package cjdoc.schema_data

// Current distribution-time schema contracts; docs/schema copies are emitted by cjdoc schema.
private let DOC_IR_V18_ROOT = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v18.schema.json",
  "title": "cjdoc Doc IR v18",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "generator", "status", "apiCollectionState", "documentationRevision", "project", "configuration", "metadata", "providers", "modules", "packages", "files", "declarations", "assets", "orphanDocComments", "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations", "diagnostics", "dependencies", "documentSets"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.doc-ir/18"},
    "generator": {"$ref": "#/$defs/generator"},
    "status": {"enum": ["complete", "partial"]},
    "apiCollectionState": {"enum": ["resolved", "partial", "unavailable"]},
    "documentationRevision": {"type": "string"},
    "project": {"$ref": "#/$defs/project"},
    "configuration": {"$ref": "#/$defs/configuration"},
    "metadata": {"$ref": "#/$defs/documentationMetadata"},
    "dependencies": {"type": "array", "items": {"$ref": "#/$defs/dependencyInstance"}},
    "documentSets": {"type": "array", "items": {"$ref": "#/$defs/documentSetIdentity"}},
    "providers": {"type": "array", "items": {"$ref": "#/$defs/provider"}},
    "modules": {"type": "array", "items": {"$ref": "#/$defs/module"}},
    "packages": {"type": "array", "items": {"$ref": "#/$defs/package"}},
    "files": {"type": "array", "items": {"$ref": "#/$defs/file"}},
    "declarations": {"type": "array", "items": {"$ref": "#/$defs/declaration"}},
    "assets": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/asset"}},
    "orphanDocComments": {"type": "array", "items": {"$ref": "#/$defs/orphanComment"}},
    "macroInvocations": {"type": "array", "items": {"$ref": "#/$defs/macroInvocation"}},
    "unsupportedDeclarations": {"type": "array", "items": {"$ref": "#/$defs/unsupportedDeclaration"}},
    "unboundSemanticDeclarations": {"type": "array", "items": {"$ref": "#/$defs/unboundSemanticDeclaration"}},
    "diagnostics": {"type": "array", "items": {"$ref": "#/$defs/diagnostic"}},
    "languageOptions": {"$ref": "#/$defs/documentationLanguageOptions"},
    "pages": {"type": "array", "maxItems": 128, "items": {"$ref": "#/$defs/documentationPage"}},
    "readingLanguage": {"enum": ["zh-CN", "en"]},
    "externalDocumentation": {"type": "array", "items": {"$ref": "#/$defs/externalDocumentationReference"}}
  },
  "$defs": {
    "semanticLinkMetadata": {
      "type": "object", "additionalProperties": false,
      "required": ["target", "state", "targetSymbolId", "externalUrl", "semanticNavigation"],
      "properties": {
        "target": {"type": "string", "minLength": 1},
        "state": {"enum": ["resolved", "unresolved", "ambiguous", "unavailable"]},
        "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"},
        "externalUrl": {"$ref": "#/$defs/nullableString"},
        "semanticNavigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}
      }
    },
    "repository": {
      "type": "object", "additionalProperties": false,
      "required": ["url", "revision"],
      "properties": {
        "url": {"type": "string", "minLength": 1,
          "pattern": "^https://github.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"},
        "revision": {"type": "string", "minLength": 1}
      }
    },
    "documentationText": {
      "type": "object", "additionalProperties": false,
      "required": ["fieldId", "kind", "subject", "language", "text", "markdown", "source", "state", "referenceState", "targetSymbolId", "directives", "navigation", "entryId"],
      "properties": {
        "fieldId": {"type": "string"}, "kind": {"type": "string"}, "subject": {"type": "string"},
        "language": {"enum": ["zh-CN", "en", null]}, "text": {"type": "string"},
        "markdown": {"$ref": "#/$defs/markdownDocument"},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "state": {"enum": ["valid", "empty", "conflict", "unpaired", "invalid"]},
        "referenceState": {"$ref": "#/$defs/semanticState"},
        "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"}, "directives": {"type": "string"},
        "entryId": {"$ref": "#/$defs/nullableAuthorEntryId"},
        "navigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}
      },
      "allOf": [
        {"if": {"properties": {"kind": {"enum": ["note", "warning", "danger"]}}},
          "then": {"allOf": [
            {"properties": {"state": {"enum": ["valid", "empty", "unpaired", "invalid"]}}},
            {"if": {"properties": {"state": {"enum": ["valid", "unpaired"]}}},
              "then": {"properties": {"markdown": {"$ref": "#/$defs/admonitionDocumentShape"}}},
              "else": {"properties": {"markdown": {"properties": {"children": {"maxItems": 0}}}}}},
            {"if": {"properties": {"state": {"enum": ["unpaired", "invalid"]}}},
              "then": {"properties": {"fieldId": {"const": ""}}},
              "else": {"properties": {"entryId": {"type": "string"}}}}
          ]}},
        {"if": {"properties": {"state": {"enum": ["valid", "empty", "conflict"]}}},
          "then": {"properties": {"fieldId": {"minLength": 1}}}},
        {"if": {"properties": {"referenceState": {"const": "resolved"}}},
          "then": {"properties": {"targetSymbolId": {"$ref": "#/$defs/symbolId"}}}},
        {"if": {"properties": {"kind": {"enum": ["see", "throws"]}, "referenceState": {"not": {"const": "resolved"}}}},
          "then": {"properties": {"targetSymbolId": {"type": "null"}}}}
      ]
    },
    "documentationLanguageOptions": {
      "type": "object", "additionalProperties": false,
      "required": ["defaultLanguage", "languages", "missingTranslation"],
      "properties": {
        "defaultLanguage": {"enum": ["zh-CN", "en"]},
        "languages": {"type": "array", "minItems": 1, "maxItems": 2, "uniqueItems": true, "items": {"enum": ["zh-CN", "en"]}},
        "missingTranslation": {"enum": ["warn", "deny"]}
      }
    },
    "documentationPage": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "source", "route", "title", "kind", "packageName", "language", "defaultLanguage", "text", "markdown", "sections", "targetSymbolIds"],
      "properties": {
        "id": {"type": "string", "minLength": 1}, "source": {"type": "string"}, "route": {"type": "string"},
        "title": {"type": "string"}, "kind": {"enum": ["project", "package", "module", "guide"]},
        "packageName": {"type": "string"}, "language": {"enum": ["zh-CN", "en", null]},
        "defaultLanguage": {"enum": ["zh-CN", "en", null]}, "text": {"type": "string"},
        "markdown": {"$ref": "#/$defs/markdownDocument"},
        "targetSymbolIds": {"type": "array", "uniqueItems": true, "items": {"$ref": "#/$defs/symbolId"}},
        "bindings": {"type": "array", "items": {"type": "object", "additionalProperties": false,
          "required": ["target", "selector", "provenance", "version", "sourceLine", "language", "state", "targetSymbolId", "navigation"],
          "properties": {"target": {"type": "string"}, "selector": {"type": "string"}, "provenance": {"type": "string"},
            "version": {"type": "string"}, "sourceLine": {"type": "integer", "minimum": 1}, "language": {"type": "string"},
            "state": {"enum": ["resolved", "unresolved", "ambiguous", "unavailable", "conflict"]},
            "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"},
            "navigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}}}},
        "sections": {"type": "array", "items": {"type": "object", "additionalProperties": false,
          "required": ["id", "anchor"], "properties": {"id": {"type": "string"}, "anchor": {"type": "string"}}}}
      }
    },
    "externalDocumentationReference": {
      "type": "object", "additionalProperties": false,
      "required": ["symbolId", "name", "state", "url", "reason", "version", "index", "format", "fingerprint"],
      "properties": {"symbolId": {"$ref": "#/$defs/symbolId"}, "name": {"type": "string", "minLength": 1},
        "state": {"enum": ["available", "unavailable", "ambiguous"]}, "url": {"type": "string"},
        "reason": {"type": "string"}, "version": {"type": "string"}, "index": {"type": "string"},
        "format": {"type": "string"}, "fingerprint": {"type": "string"}},
      "allOf": [
        {"if": {"properties": {"state": {"const": "available"}}},
          "then": {"properties": {"url": {"minLength": 1}}}},
        {"if": {"properties": {"state": {"enum": ["unavailable", "ambiguous"]}}},
          "then": {"properties": {"url": {"const": ""}}}}
      ]
    },
"""

private let DOC_IR_V18_WORKSPACE = """
    "semanticState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "nullableString": {"type": ["string", "null"]},
    "moduleId": {"type": "string", "pattern": "^cjdoc:module:v1:.+$"},
    "symbolId": {"type": "string", "pattern": "^cjdoc:v2:.+$"},
    "nullableSymbolId": {"anyOf": [{"$ref": "#/$defs/symbolId"}, {"type": "null"}]},
    "stringArray": {"type": "array", "items": {"type": "string"}},
    "portablePath": {"type": "string", "minLength": 1, "pattern": "^[^/]+(?:/[^/]+)*$"},
    "generator": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "version", "toolchain"],
      "properties": {"name": {"const": "cjdoc"}, "version": {"type": "string", "minLength": 1}, "toolchain": {"type": "string"}}
    },
    "project": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "kind", "repository"],
      "properties": {"name": {"type": "string", "minLength": 1}, "kind": {"type": "string", "minLength": 1}, "repository": {"anyOf": [{"$ref": "#/$defs/repository"}, {"type": "null"}]}}
    },
    "configuration": {
      "type": "object", "additionalProperties": false,
      "required": ["audience", "lintProfile", "cfgProfile"],
      "properties": {
        "audience": {"enum": ["external", "package", "all"]},
        "lintProfile": {"enum": ["off", "standard", "strict"]},
        "cfgProfile": {"type": "string", "minLength": 1}
      }
    },
    "capabilities": {
      "type": "object", "additionalProperties": false,
      "required": ["sourceBinding", "ownership", "visibility", "canonicalTypes", "canonicalSignatures", "relationships", "annotations"],
      "properties": {
        "sourceBinding": {"type": "boolean"}, "ownership": {"type": "boolean"},
        "visibility": {"type": "boolean"}, "canonicalTypes": {"type": "boolean"},
        "canonicalSignatures": {"type": "boolean"}, "relationships": {"type": "boolean"},
        "annotations": {"type": "boolean"}
      }
    },
    "provider": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "version", "moduleId", "state", "capabilities"],
      "properties": {
        "name": {"type": "string", "minLength": 1, "maxLength": 1024, "pattern": "\\\\S"}, "version": {"type": "string", "minLength": 1, "maxLength": 1024, "pattern": "\\\\S"},
        "moduleId": {"$ref": "#/$defs/moduleId"},
        "state": {"$ref": "#/$defs/semanticState"}, "capabilities": {"$ref": "#/$defs/capabilities"}
      }
    },
    "module": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "name", "role", "sourcePrefix", "organization", "packageNames", "dependencyIds"],
      "properties": {
        "id": {"$ref": "#/$defs/moduleId"}, "name": {"type": "string", "minLength": 1},
        "role": {"enum": ["root", "workspace", "pathDependency", "externalDependency"]},
        "sourcePrefix": {"anyOf": [{"const": ""}, {"$ref": "#/$defs/portablePath"}]}, "organization": {"$ref": "#/$defs/nullableString"}, "packageNames": {"$ref": "#/$defs/stringArray"},
        "dependencyIds": {"type": "array", "items": {"$ref": "#/$defs/moduleId"}}
      }
    },
    "package": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "moduleId", "sourceFiles", "symbolIds", "reExports"],
      "properties": {
        "name": {"type": "string", "minLength": 1}, "moduleId": {"$ref": "#/$defs/moduleId"},
        "sourceFiles": {"type": "array", "items": {"$ref": "#/$defs/portablePath"}},
        "symbolIds": {"type": "array", "items": {"$ref": "#/$defs/symbolId"}},
        "reExports": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/reExport"}}
      }
    },
    "reExportBinding": {
      "type": "object", "additionalProperties": false,
      "required": ["exposedName", "targetSymbolIds"],
      "properties": {
        "exposedName": {"type": "string", "minLength": 1},
        "targetSymbolIds": {"type": "array", "minItems": 1, "items": {"$ref": "#/$defs/symbolId"}}
      }
    },
    "reExport": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "kind", "organization", "targetPackageName", "targetModuleId", "alias", "state", "source", "bindings"],
      "properties": {
        "id": {"type": "string", "pattern": "^cjdoc:reexport:v1:[0-9a-f]{64}$"},
        "kind": {"enum": ["single", "alias", "all", "multi", "packageAlias"]},
        "organization": {"$ref": "#/$defs/nullableString"},
        "targetPackageName": {"type": "string", "minLength": 1},
        "targetModuleId": {"anyOf": [{"$ref": "#/$defs/moduleId"}, {"type": "null"}]},
        "alias": {"$ref": "#/$defs/nullableString"},
        "state": {"$ref": "#/$defs/semanticState"},
        "source": {"$ref": "#/$defs/sourceRange"},
        "bindings": {"type": "array", "items": {"$ref": "#/$defs/reExportBinding"}}
      }
    },
"""

private let DOC_IR_V18_ASSETS_AND_METADATA = """
    "asset": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "mediaType", "sourcePath", "base64"],
      "properties": {
        "id": {"type": "string", "pattern": "^sha256-[0-9a-f]{64}$"},
        "mediaType": {"enum": ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]},
        "sourcePath": {"$ref": "#/$defs/portablePath"},
        "base64": {"type": "string", "minLength": 4, "maxLength": 22369624, "pattern": "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"}
      }
    },
    "orphanComment": {
      "type": "object", "additionalProperties": false,
      "required": ["rawText", "source"],
      "properties": {"rawText": {"type": "string"}, "source": {"$ref": "#/$defs/sourceRange"}}
    },
    "macroInvocation": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "source"],
      "properties": {"name": {"type": "string", "minLength": 1}, "source": {"$ref": "#/$defs/sourceRange"}}
    },
    "unsupportedDeclaration": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "name", "reason", "source"],
      "properties": {
        "kind": {"type": "string"}, "name": {"type": "string"}, "reason": {"type": "string", "minLength": 1},
        "source": {"$ref": "#/$defs/sourceRange"}
      }
    },
    "unboundSemanticDeclaration": {
      "type": "object", "additionalProperties": false,
      "required": ["provider", "display", "reason"],
      "properties": {
        "provider": {"type": "string", "minLength": 1}, "display": {"type": "string"},
        "reason": {"type": "string", "minLength": 1}
      }
    },
    "metadataTitleText": {
      "type": "string", "minLength": 1, "maxLength": 256, "x-maxUtf8Bytes": 256,
      "description": "Nonblank single-line metadata title of 1-256 UTF-8 bytes; the model enforces the byte limit and rejects controls."
    },
    "documentationTitle": {
      "type": "object", "additionalProperties": false,
      "required": ["language", "title"],
      "properties": {
        "language": {"enum": ["zh-CN", "en"]},
        "title": {"$ref": "#/$defs/metadataTitleText"}
      }
    },
    "documentationGroupDefinition": {
      "type": "object", "additionalProperties": false,
      "required": ["moduleId", "packageName", "ownerId", "id", "title", "titles", "order"],
      "properties": {
        "moduleId": {"type": "string", "minLength": 1},
        "packageName": {"type": "string", "minLength": 1},
        "ownerId": {"$ref": "#/$defs/nullableSymbolId"},
        "id": {"type": "string", "pattern": "^[A-Za-z0-9_-]{1,64}$"},
        "title": {"$ref": "#/$defs/metadataTitleText"},
        "titles": {"type": "array", "maxItems": 2, "items": {"$ref": "#/$defs/documentationTitle"}},
        "order": {"anyOf": [{"type": "integer", "minimum": 0, "maximum": 999999}, {"type": "null"}]}
      }
    },
    "documentationTagDefinition": {
      "type": "object", "additionalProperties": false,
      "required": ["moduleId", "id", "title", "titles"],
      "properties": {
        "moduleId": {"type": "string", "minLength": 1},
        "id": {"type": "string", "pattern": "^[A-Za-z0-9_-]{1,64}$"},
        "title": {"$ref": "#/$defs/metadataTitleText"},
        "titles": {"type": "array", "maxItems": 2, "items": {"$ref": "#/$defs/documentationTitle"}}
      }
    },
    "documentationMetadata": {
      "type": "object", "additionalProperties": false,
      "required": ["groups", "tags"],
      "properties": {
        "groups": {"type": "array", "maxItems": 2048, "items": {"$ref": "#/$defs/documentationGroupDefinition"}},
        "tags": {"type": "array", "maxItems": 2048, "items": {"$ref": "#/$defs/documentationTagDefinition"}}
      }
    },
    "diagnostic": {
      "type": "object", "additionalProperties": false,
      "required": ["severity", "code", "message", "source", "symbolId"],
      "properties": {
        "severity": {"enum": ["warning", "error"]}, "code": {"type": "string", "pattern": "^CJDOC[0-9]{4}$"},
        "message": {"type": "string", "minLength": 1},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "symbolId": {"$ref": "#/$defs/nullableSymbolId"}
      }
    }
  }
}
"""

// Assemble the versioned schema in published field order.
private func buildDocIrV18Schema(): String {
    let out = StringBuilder(DOC_IR_V18_ROOT.size + DOC_IR_V18_EXTERNAL_NAVIGATION.size +
        DOC_IR_V18_WORKSPACE.size + DOC_IR_V18_SOURCE_AND_TYPES.size + DOC_IR_V18_COMMENTS.size +
        DOC_IR_V18_DECLARATIONS.size + DOC_IR_V18_ASSETS_AND_METADATA.size)
    out.append(DOC_IR_V18_ROOT)
    out.append(DOC_IR_V18_EXTERNAL_NAVIGATION)
    out.append(DOC_IR_V18_WORKSPACE)
    out.append(DOC_IR_V18_SOURCE_AND_TYPES)
    out.append(DOC_IR_V18_COMMENTS)
    out.append(DOC_IR_V18_DECLARATIONS)
    out.append(DOC_IR_V18_ASSETS_AND_METADATA)
    out.toString()
}

public let DOC_IR_V18_SCHEMA = buildDocIrV18Schema()
public let DOC_IR_SCHEMA = DOC_IR_V18_SCHEMA.replace("doc-ir-v18.schema.json", "doc-ir.schema.json")
