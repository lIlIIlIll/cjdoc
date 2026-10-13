package cjdoc.schema_data

private let LOCALIZED_DOC_SCHEMA = """
    "documentationText": {
      "type": "object", "additionalProperties": false,
      "required": ["fieldId", "kind", "subject", "language", "text", "markdown", "source", "state", "referenceState", "targetSymbolId", "directives"],
      "properties": {
        "fieldId": {"type": "string"}, "kind": {"type": "string"}, "subject": {"type": "string"},
        "language": {"enum": ["zh-CN", "en", null]}, "text": {"type": "string"},
        "markdown": {"$ref": "#/$defs/markdownNode"},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "state": {"enum": ["valid", "empty", "conflict", "unpaired", "invalid"]},
        "referenceState": {"$ref": "#/$defs/semanticState"},
        "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"}, "directives": {"type": "string"}
      }
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
        "markdown": {"$ref": "#/$defs/markdownNode"},
        "targetSymbolIds": {"type": "array", "uniqueItems": true, "items": {"$ref": "#/$defs/symbolId"}},
        "bindings": {"type": "array", "items": {"type": "object", "additionalProperties": false,
          "required": ["target", "selector", "provenance", "version", "sourceLine", "language", "state", "targetSymbolId"],
          "properties": {"target": {"type": "string"}, "selector": {"type": "string"}, "provenance": {"type": "string"},
            "version": {"type": "string"}, "sourceLine": {"type": "integer", "minimum": 1}, "language": {"type": "string"},
            "state": {"enum": ["resolved", "unresolved", "ambiguous", "unavailable", "conflict"]},
            "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"}}}},
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

public let DOC_IR_V13_SCHEMA = DOC_IR_V12_SCHEMA
    .replace("doc-ir-v12.schema.json", "doc-ir-v13.schema.json")
    .replace("cjdoc Doc IR v12", "cjdoc Doc IR v13")
    .replace("cjdoc.doc-ir/12", "cjdoc.doc-ir/13")
    .replace("    \"diagnostics\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/diagnostic\"}}",
        "    \"diagnostics\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/diagnostic\"}},\n" +
        "    \"languageOptions\": {\"$ref\": \"#/$defs/documentationLanguageOptions\"},\n" +
        "    \"pages\": {\"type\": \"array\", \"maxItems\": 128, \"items\": {\"$ref\": \"#/$defs/documentationPage\"}},\n" +
        "    \"readingLanguage\": {\"enum\": [\"zh-CN\", \"en\"]},\n" +
        "    \"externalDocumentation\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/externalDocumentationReference\"}}")
    .replace("    \"semanticState\":", LOCALIZED_DOC_SCHEMA + "    \"semanticState\":")
    .replace("\"tags\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/tag\"}}",
        "\"tags\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/tag\"}},\n" +
        "        \"defaultLanguage\": {\"enum\": [\"zh-CN\", \"en\", null]},\n" +
        "        \"localizedTexts\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/documentationText\"}}")
    .replace("\"exampleMarkdown\": {\"$ref\": \"#/$defs/markdownNode\"}",
        "\"exampleMarkdown\": {\"$ref\": \"#/$defs/markdownNode\"},\n" +
        "        \"contentLanguage\": {\"enum\": [\"zh-CN\", \"en\", null]},\n" +
        "        \"translationState\": {\"enum\": [\"complete\", \"fallback\", \"empty-fallback\", \"conflict-fallback\", \"empty\", \"conflict\", \"missing\", \"unknown\", \"unpaired\"]},\n" +
        "        \"fieldId\": {\"type\": \"string\"},\n" +
        "        \"descriptionMarkdown\": {\"$ref\": \"#/$defs/markdownNode\"},\n" +
        "        \"evidenceKey\": {\"type\": \"string\"}")

public let DOC_IR_SCHEMA = DOC_IR_V13_SCHEMA
    .replace("doc-ir-v13.schema.json", "doc-ir.schema.json")
