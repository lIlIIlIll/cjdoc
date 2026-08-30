package cjdoc.schema_data

private let DOC_IR_V8_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v8.schema.json"
private let DOC_IR_CURRENT_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"

private func buildDocIrV8Schema(id: String): String {
    var schema = DOC_IR_V7_SCHEMA
        .replace("https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json", id)
        .replace("cjdoc Doc IR v7", "cjdoc Doc IR v8")
        .replace("\"schemaVersion\": {\"const\": \"cjdoc.doc-ir/7\"}",
            "\"schemaVersion\": {\"const\": \"cjdoc.doc-ir/8\"}")
        .replace("\"portablePath\": {\"type\": \"string\", \"minLength\": 1, " +
            "\"pattern\": \"^(?!/)(?![A-Za-z]:)(?!.*\\\\\\\\).+$\"}",
            "\"portablePath\": {\"type\": \"string\", \"minLength\": 1, " +
            "\"pattern\": \"^(?![A-Za-z]:)(?!.*\\\\\\\\)(?!\\\\.{1,2}(?:/|$))" +
            "(?!.*/\\\\.{1,2}(?:/|$))[^/]+(?:/[^/]+)*$\"}")
        .replace("\"sourcePrefix\": {\"type\": \"string\"}",
            "\"sourcePrefix\": {\"anyOf\": [{\"const\": \"\"}, " +
            "{\"$ref\": \"#/$defs/portablePath\"}]}")
        .replace("\"line\": {\"type\": \"integer\", \"minimum\": 1}",
            "\"line\": {\"type\": \"integer\", \"minimum\": 1, \"maximum\": 9223372036854775807}")
        .replace("\"column\": {\"type\": \"integer\", \"minimum\": 1}",
            "\"column\": {\"type\": \"integer\", \"minimum\": 1, \"maximum\": 9223372036854775807}")
        .replace("\"byteOffset\": {\"type\": \"integer\", \"minimum\": 0}",
            "\"byteOffset\": {\"type\": \"integer\", \"minimum\": 0, \"maximum\": 9223372036854775807}")
        .replace("\"required\": [\"kind\", \"literal\", \"source\", \"children\"]",
            "\"required\": [\"kind\", \"literal\", \"source\", \"metadata\", \"children\"]")
        .replace("        \"source\": {\"anyOf\": [{\"$ref\": \"#/$defs/sourceRange\"}, {\"type\": \"null\"}]},\n" +
            "        \"children\": {\"type\": \"array\", \"maxItems\": 100000, \"items\": {\"$ref\": \"#/$defs/markdownNode\"}}",
            "        \"source\": {\"anyOf\": [{\"$ref\": \"#/$defs/sourceRange\"}, {\"type\": \"null\"}]},\n" +
            "        \"metadata\": {\"anyOf\": [{\"type\": \"null\"}, {\"$ref\": \"#/$defs/headingMetadata\"}, {\"$ref\": \"#/$defs/listMetadata\"}, {\"$ref\": \"#/$defs/listItemMetadata\"}, {\"$ref\": \"#/$defs/codeBlockMetadata\"}, {\"$ref\": \"#/$defs/tableMetadata\"}, {\"$ref\": \"#/$defs/tableRowMetadata\"}, {\"$ref\": \"#/$defs/tableCellMetadata\"}]},\n" +
            "        \"children\": {\"type\": \"array\", \"maxItems\": 32767, \"items\": {\"$ref\": \"#/$defs/markdownNode\"}}")
        .replace("\"macroSymbolId\": {\"$ref\": \"#/$defs/nullableString\"}",
            "\"macroSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"}")
        .replace("\"semantic\", \"origin\"]",
            "\"semantic\", \"origin\", \"enumNonExhaustive\"]")
        .replace("\"semantic\": {\"$ref\": \"#/$defs/semanticInfo\"}, \"origin\": {\"$ref\": \"#/$defs/origin\"}",
            "\"semantic\": {\"$ref\": \"#/$defs/semanticInfo\"}, \"origin\": {\"$ref\": \"#/$defs/origin\"},\n" +
            "        \"enumNonExhaustive\": {\"type\": [\"boolean\", \"null\"]}")
        .replace("\"id\": {\"type\": \"string\", \"minLength\": 1},\n        \"mediaType\":",
            "\"id\": {\"type\": \"string\", \"pattern\": \"^sha256-[0-9a-f]{64}$\"},\n        \"mediaType\":")
        .replace("\"name\": {\"type\": \"string\", \"minLength\": 1}, " +
            "\"version\": {\"type\": \"string\", \"minLength\": 1},\n        \"moduleId\":",
            "\"name\": {\"type\": \"string\", \"minLength\": 1, \"maxLength\": 1024, " +
            "\"pattern\": \"\\\\S\"}, \"version\": {\"type\": \"string\", \"minLength\": 1, " +
            "\"maxLength\": 1024, \"pattern\": \"\\\\S\"},\n        \"moduleId\":")
        .replace("\"canonicalSignature\": {\"$ref\": \"#/$defs/nullableString\"}",
            "\"canonicalSignature\": {\"anyOf\": [{\"type\": \"null\"}, " +
            "{\"type\": \"string\", \"minLength\": 1, \"pattern\": \"\\\\S\"}]}")
        .replace("\"base64\": {\"type\": \"string\", \"minLength\": 4, \"pattern\":",
            "\"base64\": {\"type\": \"string\", \"minLength\": 4, " +
            "\"maxLength\": 22369624, \"pattern\":")
        .replace("\"state\": {\"$ref\": \"#/$defs/semanticState\"}, \"canonical\": {\"$ref\": \"#/$defs/nullableString\"},\n" +
            "        \"provider\": {\"$ref\": \"#/$defs/nullableString\"}",
            "\"state\": {\"$ref\": \"#/$defs/semanticState\"}, \"canonical\": {\"anyOf\": " +
            "[{\"type\": \"null\"}, {\"type\": \"string\", \"minLength\": 1, " +
            "\"pattern\": \"\\\\S\"}]},\n" +
            "        \"provider\": {\"anyOf\": [{\"type\": \"null\"}, " +
            "{\"type\": \"string\", \"minLength\": 1}]}")
        .replace("      \"allOf\": [{\"if\": {\"properties\": {\"state\": {\"const\": \"resolved\"}}}, " +
            "\"then\": {\"properties\": {\"canonical\": {\"type\": \"string\", \"minLength\": 1}}}}]",
            "      \"allOf\": [\n" +
            "        {\"if\": {\"properties\": {\"state\": {\"const\": \"unavailable\"}}},\n" +
            "          \"then\": {\"properties\": {\"canonical\": {\"type\": \"null\"}, " +
            "\"provider\": {\"type\": \"null\"}}},\n" +
            "          \"else\": {\"properties\": {\"provider\": {\"type\": \"string\", " +
            "\"minLength\": 1}}}},\n" +
            "        {\"if\": {\"properties\": {\"state\": {\"const\": \"resolved\"}}},\n" +
            "          \"then\": {\"properties\": {\"canonical\": {\"type\": \"string\", " +
            "\"minLength\": 1}}}}\n" +
            "      ]")

    let metadataDefinitions = """
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
        "attributesRaw": {"type": "string"}
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
    """
    let metadataConditions = """
      "allOf": [
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
          "custom_inline"]}}}, "then": {"properties": {"metadata": {"type": "null"}}}}
      ]
"""
    schema = schema.replace("    \"markdownNode\": {", metadataDefinitions + "\"markdownNode\": {")
    schema = schema.replace(
        "        \"children\": {\"type\": \"array\", \"maxItems\": 32767, \"items\": {\"$ref\": \"#/$defs/markdownNode\"}}\n" +
            "      }\n    },\n    \"comment\": {",
        "        \"children\": {\"type\": \"array\", \"maxItems\": 32767, \"items\": {\"$ref\": \"#/$defs/markdownNode\"}}\n" +
            "      },\n" + metadataConditions + "    },\n    \"comment\": {")
    schema
}

public let DOC_IR_V8_SCHEMA = buildDocIrV8Schema(DOC_IR_V8_ID)
public let DOC_IR_SCHEMA = buildDocIrV8Schema(DOC_IR_CURRENT_ID)
