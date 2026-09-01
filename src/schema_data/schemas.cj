package cjdoc.schema_data

// These strings are the distribution-time schema source of truth. The repository
// copies under docs/schema are regenerated from `cjdoc schema ...` and compared in CI.
public let DOC_IR_V7_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
  "title": "cjdoc Doc IR v7",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "generator", "status", "project", "configuration", "providers", "modules", "packages", "files", "declarations", "assets", "orphanDocComments", "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations", "diagnostics"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.doc-ir/7"},
    "generator": {"$ref": "#/$defs/generator"},
    "status": {"enum": ["complete", "partial"]},
    "project": {"$ref": "#/$defs/project"},
    "configuration": {"$ref": "#/$defs/configuration"},
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
    "diagnostics": {"type": "array", "items": {"$ref": "#/$defs/diagnostic"}}
  },
  "$defs": {
    "semanticState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "nullableString": {"type": ["string", "null"]},
    "moduleId": {"type": "string", "pattern": "^cjdoc:module:v1:.+$"},
    "symbolId": {"type": "string", "pattern": "^cjdoc:v2:.+$"},
    "nullableSymbolId": {"anyOf": [{"$ref": "#/$defs/symbolId"}, {"type": "null"}]},
    "stringArray": {"type": "array", "items": {"type": "string"}},
    "portablePath": {"type": "string", "minLength": 1, "pattern": "^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\).+$"},
    "generator": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "version"],
      "properties": {"name": {"const": "cjdoc"}, "version": {"type": "string", "minLength": 1}}
    },
    "project": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "kind"],
      "properties": {"name": {"type": "string", "minLength": 1}, "kind": {"type": "string", "minLength": 1}}
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
        "name": {"type": "string", "minLength": 1}, "version": {"type": "string", "minLength": 1},
        "moduleId": {"$ref": "#/$defs/moduleId"},
        "state": {"$ref": "#/$defs/semanticState"}, "capabilities": {"$ref": "#/$defs/capabilities"}
      }
    },
    "module": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "name", "role", "sourcePrefix", "packageNames", "dependencyIds"],
      "properties": {
        "id": {"$ref": "#/$defs/moduleId"}, "name": {"type": "string", "minLength": 1},
        "role": {"enum": ["root", "workspace", "pathDependency", "externalDependency"]},
        "sourcePrefix": {"type": "string"}, "packageNames": {"$ref": "#/$defs/stringArray"},
        "dependencyIds": {"type": "array", "items": {"$ref": "#/$defs/moduleId"}}
      }
    },
    "package": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "moduleId", "sourceFiles", "symbolIds"],
      "properties": {
        "name": {"type": "string", "minLength": 1}, "moduleId": {"$ref": "#/$defs/moduleId"},
        "sourceFiles": {"type": "array", "items": {"$ref": "#/$defs/portablePath"}},
        "symbolIds": {"type": "array", "items": {"$ref": "#/$defs/symbolId"}}
      }
    },
    "file": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "moduleId", "packageName"],
      "properties": {
        "path": {"$ref": "#/$defs/portablePath"}, "moduleId": {"$ref": "#/$defs/moduleId"},
        "packageName": {"type": "string", "minLength": 1}
      }
    },
    "position": {
      "type": "object", "additionalProperties": false,
      "required": ["line", "column", "byteOffset"],
      "properties": {
        "line": {"type": "integer", "minimum": 1}, "column": {"type": "integer", "minimum": 1},
        "byteOffset": {"type": "integer", "minimum": 0}
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
        "state": {"$ref": "#/$defs/semanticState"}, "canonical": {"$ref": "#/$defs/nullableString"},
        "provider": {"$ref": "#/$defs/nullableString"}
      },
      "allOf": [{"if": {"properties": {"state": {"const": "resolved"}}}, "then": {"properties": {"canonical": {"type": "string", "minLength": 1}}}}]
    },
    "typeRef": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "spelling", "nullable", "arguments", "semantic"],
      "properties": {
        "kind": {"type": "string", "minLength": 1}, "spelling": {"type": "string"},
        "nullable": {"type": "boolean"}, "arguments": {"type": "array", "items": {"$ref": "#/$defs/typeRef"}},
        "semantic": {"$ref": "#/$defs/semanticType"}
      }
    },
    "parameter": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "type", "documentation", "defaultExpression"],
      "properties": {
        "name": {"type": "string"}, "type": {"$ref": "#/$defs/typeRef"},
        "documentation": {"$ref": "#/$defs/nullableString"}, "defaultExpression": {"$ref": "#/$defs/nullableString"}
      }
    },
    "tag": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "subject", "description", "referenceState", "targetSymbolId"],
      "properties": {
        "name": {"type": "string", "minLength": 1}, "subject": {"type": "string"},
        "description": {"type": "string"}, "referenceState": {"$ref": "#/$defs/semanticState"},
        "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"}
      }
    },
    "markdownNode": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "literal", "source", "children"],
      "properties": {
        "kind": {"enum": ["document", "block_quote", "list", "list_item", "paragraph", "heading", "thematic_break", "code_block", "html_block", "table", "table_row", "table_cell", "custom_block", "text", "soft_break", "hard_break", "code_span", "emphasis", "strong", "strikethrough", "link", "image", "html_inline", "custom_inline"]}, "literal": {"type": "string"},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "children": {"type": "array", "maxItems": 100000, "items": {"$ref": "#/$defs/markdownNode"}}
      }
    },
    "comment": {
      "type": "object", "additionalProperties": false,
      "required": ["rawText", "summary", "description", "markdown", "tags"],
      "properties": {
        "rawText": {"type": "string"}, "summary": {"type": "string"}, "description": {"type": "string"},
        "markdown": {"$ref": "#/$defs/markdownNode"}, "tags": {"type": "array", "items": {"$ref": "#/$defs/tag"}}
      }
    },
    "semanticInfo": {
      "type": "object", "additionalProperties": false,
      "required": ["state", "provider", "canonicalSignature"],
      "properties": {
        "state": {"$ref": "#/$defs/semanticState"}, "provider": {"type": "string", "minLength": 1},
        "canonicalSignature": {"$ref": "#/$defs/nullableString"}
      }
    },
    "origin": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "macroSymbolId"],
      "properties": {"kind": {"type": "string", "minLength": 1}, "macroSymbolId": {"$ref": "#/$defs/nullableString"}}
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
      "required": ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations", "typeRelationships", "symbolRelationships", "documentation", "source", "headerSpelling", "semantic", "origin"],
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
        "semantic": {"$ref": "#/$defs/semanticInfo"}, "origin": {"$ref": "#/$defs/origin"}
      }
    },
    "asset": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "mediaType", "sourcePath", "base64"],
      "properties": {
        "id": {"type": "string", "minLength": 1},
        "mediaType": {"enum": ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]},
        "sourcePath": {"$ref": "#/$defs/portablePath"},
        "base64": {"type": "string", "minLength": 4, "pattern": "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"}
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

public let SEARCH_INDEX_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/search-index.schema.json",
  "title": "cjdoc search index v4",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "entries"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.search-index/4"},
    "entries": {
      "type": "array",
      "items": {
        "type": "object", "additionalProperties": false,
        "required": ["id", "canonicalId", "exposure", "name", "qualifiedName", "kind", "packageName", "summary", "href"],
        "properties": {
          "id": {"type": "string", "minLength": 1},
          "canonicalId": {"type": "string", "pattern": "^cjdoc:v2:.+$"},
          "exposure": {"type": "boolean"}, "name": {"type": "string"},
          "qualifiedName": {"type": "string", "minLength": 1}, "kind": {"type": "string", "minLength": 1},
          "packageName": {"type": "string", "minLength": 1}, "summary": {"type": "string"},
          "href": {"type": "string", "pattern": "^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\).+$"}
        }
      }
    }
  }
}
"""
