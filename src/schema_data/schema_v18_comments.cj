package cjdoc.schema_data

internal let DOC_IR_V18_COMMENTS = """
    "tag": {
      "type": "object", "additionalProperties": false,
      "required": ["name", "subject", "description", "referenceState", "targetSymbolId", "navigation", "entryId", "source"],
      "properties": {
        "name": {"type": "string", "minLength": 1}, "subject": {"type": "string"},
        "description": {"type": "string"}, "referenceState": {"$ref": "#/$defs/semanticState"},
        "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"},
        "directives": {"type": "string"},
        "exampleMarkdown": {"$ref": "#/$defs/markdownDocument"},
        "contentLanguage": {"enum": ["zh-CN", "en", null]},
        "translationState": {"enum": ["complete", "fallback", "empty-fallback", "conflict-fallback", "empty", "conflict", "missing", "unknown", "unpaired"]},
        "fieldId": {"type": "string"},
        "descriptionMarkdown": {"$ref": "#/$defs/markdownDocument"},
        "entryId": {"$ref": "#/$defs/nullableAuthorEntryId"},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "navigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}
      },
      "allOf": [
        {"if": {"properties": {"name": {"enum": ["note", "warning", "danger"]}}},
          "then": {"required": ["descriptionMarkdown", "fieldId", "translationState"],
            "properties": {"descriptionMarkdown": {"$ref": "#/$defs/admonitionDocumentShape"}},
            "allOf": [{"if": {"properties": {"fieldId": {"const": ""}}},
              "then": {"properties": {"translationState": {"const": "unpaired"}}},
              "else": {"properties": {"entryId": {"type": "string"}}}}]}}
      ]
    },
    "nullableAuthorEntryId": {
      "anyOf": [{"type": "string", "pattern": "^[a-z][a-z0-9_-]{0,63}$"}, {"type": "null"}]
    },
    "admonitionMetadata": {
      "type": "object", "additionalProperties": false, "required": ["level"],
      "properties": {"level": {"enum": ["note", "warning", "danger"]}}
    },
    "admonitionDocumentShape": {
      "properties": {"children": {"minItems": 1, "maxItems": 1,
        "items": {"properties": {"kind": {"const": "admonition"}}}}}
    },
    "markdownDocument": {
      "allOf": [{"$ref": "#/$defs/markdownNode"}, {"properties": {"kind": {"const": "document"}}}]
    },
    "markdownChildNode": {
      "allOf": [{"$ref": "#/$defs/markdownNode"}, {"properties": {"kind": {"not": {"const": "document"}}}}]
    },
    "markdownNonAdmonitionNode": {
      "allOf": [{"$ref": "#/$defs/markdownNode"},
        {"properties": {"kind": {"not": {"enum": ["document", "admonition"]}}}}]
    },
    "headingMetadata": {
      "type": "object", "additionalProperties": false, "required": ["level"],
      "properties": {"level": {"type": "integer", "minimum": 1, "maximum": 6}}
    },
    "listMetadata": {
      "type": "object", "additionalProperties": false,
      "required": ["listKind", "start", "delimiter", "tight"],
      "properties": {
        "listKind": {"enum": ["bullet", "ordered"]},
        "start": {"type": "integer", "minimum": 0, "maximum": 999999999},
        "delimiter": {"enum": ["period", "parenthesis", "none"]},
        "tight": {"type": "boolean"}
      },
      "allOf": [
        {"if": {"properties": {"listKind": {"const": "bullet"}}},
          "then": {"properties": {"start": {"const": 0}, "delimiter": {"const": "none"}}}},
        {"if": {"properties": {"listKind": {"const": "ordered"}}},
          "then": {"properties": {"start": {"minimum": 1, "maximum": 999999999},
            "delimiter": {"enum": ["period", "parenthesis"]}}}}
      ]
    },
    "listItemMetadata": {
      "type": "object", "additionalProperties": false, "required": ["taskState"],
      "properties": {"taskState": {"enum": ["notTask", "checked", "unchecked"]}}
    },
    "codeBlockMetadata": {
      "type": "object", "additionalProperties": false,
      "required": ["codeKind", "fenceCharacter", "fenceLength", "infoRaw", "language", "attributesRaw"],
      "properties": {
        "codeKind": {"enum": ["indented", "fenced"]},
        "fenceCharacter": {"type": ["string", "null"], "enum": ["`", "~", null]},
        "fenceLength": {"type": "integer", "minimum": 0, "maximum": 1024},
        "infoRaw": {"type": "string", "not": {"pattern": "[\\\\r\\\\n]"}}, "language": {"type": "string"},
        "attributesRaw": {"type": "string"},
        "codeHighlight": {
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
      },
      "allOf": [
        {"if": {"properties": {"codeKind": {"const": "indented"}}},
          "then": {"properties": {"fenceCharacter": {"type": "null"}, "fenceLength": {"const": 0}}}},
        {"if": {"properties": {"codeKind": {"const": "fenced"}}},
          "then": {"properties": {"fenceCharacter": {"enum": ["`", "~"]},
            "fenceLength": {"minimum": 3, "maximum": 1024}}}},
        {"if": {"properties": {"fenceCharacter": {"const": "`"}}},
          "then": {"properties": {"infoRaw": {"not": {"pattern": "`"}}}}}
      ]
    },
    "tableMetadata": {
      "type": "object", "additionalProperties": false, "required": ["alignments"],
      "properties": {"alignments": {"type": "array", "items": {"enum": ["none", "left", "center", "right"]}}}
    },
    "tableRowMetadata": {
      "type": "object", "additionalProperties": false, "required": ["header"],
      "properties": {"header": {"type": "boolean"}}
    },
    "tableCellMetadata": {
      "type": "object", "additionalProperties": false, "required": ["alignment"],
      "properties": {"alignment": {"enum": ["none", "left", "center", "right"]}}
    },
    "markdownNode": {
      "type": "object", "additionalProperties": false,
      "required": ["kind", "literal", "source", "metadata", "children"],
      "properties": {
        "kind": {"enum": ["document", "block_quote", "list", "list_item", "paragraph", "heading", "thematic_break", "code_block", "html_block", "table", "table_row", "table_cell", "custom_block", "text", "soft_break", "hard_break", "code_span", "emphasis", "strong", "strikethrough", "link", "image", "html_inline", "custom_inline", "semantic_link", "admonition"]}, "literal": {"type": "string"},
        "source": {"anyOf": [{"$ref": "#/$defs/sourceRange"}, {"type": "null"}]},
        "metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/admonitionMetadata"}, {"$ref": "#/$defs/headingMetadata"}, {"$ref": "#/$defs/listMetadata"}, {"$ref": "#/$defs/listItemMetadata"}, {"$ref": "#/$defs/codeBlockMetadata"}, {"$ref": "#/$defs/tableMetadata"}, {"$ref": "#/$defs/tableRowMetadata"}, {"$ref": "#/$defs/tableCellMetadata"}, {"$ref": "#/$defs/semanticLinkMetadata"}]},
        "children": {"type": "array", "maxItems": 32767}
      },
      "allOf": [
        {"if": {"properties": {"kind": {"const": "document"}}},
          "then": {"properties": {"children": {"items": {"$ref": "#/$defs/markdownChildNode"}}}},
          "else": {"properties": {"children": {"items": {"$ref": "#/$defs/markdownNonAdmonitionNode"}}}}},
        {"if": {"properties": {"kind": {"const": "admonition"}}},
          "then": {"properties": {"literal": {"const": ""}, "metadata": {"$ref": "#/$defs/admonitionMetadata"},
            "children": {"minItems": 1, "items": {"properties": {"kind": {"enum": [
              "block_quote", "list", "paragraph", "heading", "thematic_break", "code_block",
              "html_block", "table", "custom_block"]}}}}}}},
        {"if": {"properties": {"kind": {"const": "heading"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/headingMetadata"}]}}}},
        {"if": {"properties": {"kind": {"const": "list"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/listMetadata"}]}}}},
        {"if": {"properties": {"kind": {"const": "list_item"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/listItemMetadata"}]}}}},
        {"if": {"properties": {"kind": {"const": "code_block"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/codeBlockMetadata"}]}}}},
        {"if": {"properties": {"kind": {"const": "table"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/tableMetadata"}]}}}},
        {"if": {"properties": {"kind": {"const": "table_row"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/tableRowMetadata"}]}}}},
        {"if": {"properties": {"kind": {"const": "table_cell"}}},
          "then": {"properties": {"metadata": {"anyOf": [{"type": "null"}, {"$ref": "#/$defs/tableCellMetadata"}]}}}},
        {"if": {"properties": {"kind": {"enum": ["document", "block_quote", "paragraph",
          "thematic_break", "html_block", "custom_block", "text", "soft_break", "hard_break",
          "code_span", "emphasis", "strong", "strikethrough", "link", "image", "html_inline",
          "custom_inline"]}}}, "then": {"properties": {"metadata": {"type": "null"}}}},
        {"if": {"properties": {"kind": {"const": "semantic_link"}}}, "then": {"properties": {"metadata": {"$ref": "#/$defs/semanticLinkMetadata"}}}}
      ]
    },
    "comment": {
      "type": "object", "additionalProperties": false,
      "required": ["rawText", "summary", "description", "markdown", "tags", "localizationScope"],
      "properties": {
        "rawText": {"type": "string"}, "summary": {"type": "string"}, "description": {"type": "string"},
        "markdown": {"$ref": "#/$defs/markdownDocument"}, "tags": {"type": "array", "items": {"$ref": "#/$defs/tag"}},
        "localizationScope": {"enum": ["all", "admonitions"]},
        "defaultLanguage": {"enum": ["zh-CN", "en", null]},
        "localizedTexts": {"type": "array", "items": {"$ref": "#/$defs/documentationText"}}
      },
      "allOf": [{"if": {"properties": {"localizationScope": {"const": "admonitions"}}},
        "then": {"properties": {"defaultLanguage": {"type": "null"},
          "localizedTexts": {"items": {"properties": {"kind": {"enum": ["note", "warning", "danger"]}}}}}}}]
    },
"""
