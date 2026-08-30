package cjdoc.schema_data

// Frozen legacy schema accepted only through the in-memory v6 -> v7 migration path.
public let DOC_IR_V6_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
  "title": "cjdoc Doc IR v6",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "generator", "status", "project", "configuration", "providers", "modules", "packages", "files", "declarations", "assets", "orphanDocComments", "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations", "diagnostics"],
  "properties": {
    "schemaVersion": {"const": "cjdoc.doc-ir/6"},
    "generator": {"$ref": "#/$defs/generator"},
    "status": {"enum": ["complete", "partial"]},
    "project": {"$ref": "#/$defs/project"},
    "configuration": {"$ref": "#/$defs/configuration"},
    "providers": {"type": "array", "items": {"$ref": "#/$defs/provider"}},
    "modules": {"type": "array", "items": {"$ref": "#/$defs/module"}},
    "packages": {"type": "array", "items": {"$ref": "#/$defs/package"}},
    "files": {"type": "array", "items": {"$ref": "#/$defs/file"}},
    "declarations": {"type": "array", "items": {"$ref": "#/$defs/declaration"}},
    "assets": {"type": "array", "items": {"$ref": "#/$defs/asset"}},
    "orphanDocComments": {"type": "array", "items": {"$ref": "#/$defs/orphanComment"}},
    "macroInvocations": {"type": "array", "items": {"$ref": "#/$defs/macroInvocation"}},
    "unsupportedDeclarations": {"type": "array", "items": {"$ref": "#/$defs/unsupportedDeclaration"}},
    "unboundSemanticDeclarations": {"type": "array", "items": {"$ref": "#/$defs/unboundSemanticDeclaration"}},
    "diagnostics": {"type": "array", "items": {"$ref": "#/$defs/diagnostic"}}
  },
  "$defs": {
    "semanticState": {"enum": ["resolved", "partial", "unavailable", "ambiguous"]},
    "nullableString": {"type": ["string", "null"]},
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
      "required": ["sourceBinding", "ownership", "visibility", "canonicalTypes", "canonicalSignatures", "relationships"],
      "properties": {
        "sourceBinding": {"type": "boolean"}, "ownership": {"type": "boolean"},
        "visibility": {"type": "boolean"}, "canonicalTypes": {"type": "boolean"},
        "canonicalSignatures": {"type": "boolean"}, "relationships": {"type": "boolean"}
      }
    },
    "provider": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "version", "state", "capabilities"],
      "properties": {
        "name": {"type": "string", "minLength": 1}, "version": {"type": "string", "minLength": 1},
        "state": {"$ref": "#/$defs/semanticState"}, "capabilities": {"$ref": "#/$defs/capabilities"}
      }
    },
    "module": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "name", "role", "sourcePrefix", "packageNames", "dependencyIds"],
      "properties": {
        "id": {"type": "string", "minLength": 1}, "name": {"type": "string", "minLength": 1},
        "role": {"enum": ["root", "workspace", "pathDependency", "externalDependency"]},
        "sourcePrefix": {"type": "string"}, "packageNames": {"$ref": "#/$defs/stringArray"},
        "dependencyIds": {"$ref": "#/$defs/stringArray"}
      }
    },
    "package": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "moduleId", "sourceFiles", "symbolIds"],
      "properties": {
        "name": {"type": "string", "minLength": 1}, "moduleId": {"type": "string", "minLength": 1},
        "sourceFiles": {"type": "array", "items": {"$ref": "#/$defs/portablePath"}},
        "symbolIds": {"$ref": "#/$defs/stringArray"}
      }
    },
    "file": {
      "type": "object", "additionalProperties": false,
      "required": ["path", "moduleId", "packageName"],
      "properties": {
        "path": {"$ref": "#/$defs/portablePath"}, "moduleId": {"type": "string", "minLength": 1},
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
        "targetSymbolId": {"$ref": "#/$defs/nullableString"}
      }
    },
    "markdownNode": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "literal", "source", "children"],
      "properties": {
        "kind": {"type": "string", "minLength": 1}, "literal": {"type": "string"},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "children": {"type": "array", "items": {"$ref": "#/$defs/markdownNode"}}
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
        "state": {"$ref": "#/$defs/semanticState"}, "targetSymbolId": {"$ref": "#/$defs/nullableString"}
      }
    },
    "declaration": {
      "type": "object", "additionalProperties": false,
      "required": ["id", "kind", "name", "qualifiedName", "packageName", "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations", "typeRelationships", "symbolRelationships", "documentation", "source", "headerSpelling", "semantic", "origin"],
      "properties": {
        "id": {"type": "string", "minLength": 1}, "kind": {"type": "string", "minLength": 1},
        "name": {"type": "string"}, "qualifiedName": {"type": "string", "minLength": 1},
        "packageName": {"type": "string", "minLength": 1}, "ownerId": {"$ref": "#/$defs/nullableString"},
        "visibility": {"enum": ["public", "protected", "internal", "private"]},
        "genericParameters": {"$ref": "#/$defs/stringArray"},
        "parameters": {"type": "array", "items": {"$ref": "#/$defs/parameter"}},
        "returnType": {"anyOf": [{"$ref": "#/$defs/typeRef"}, {"type": "null"}]},
        "annotations": {"$ref": "#/$defs/stringArray"},
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
        "id": {"type": "string", "minLength": 1}, "mediaType": {"type": "string", "minLength": 1},
        "sourcePath": {"$ref": "#/$defs/portablePath"}, "base64": {"type": "string"}
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
        "symbolId": {"$ref": "#/$defs/nullableString"}
      }
    }
  }
}
"""
