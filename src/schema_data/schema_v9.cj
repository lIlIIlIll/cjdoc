package cjdoc.schema_data

private let DOC_IR_V9_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v9.schema.json"

private func buildDocIrV9Schema(source: String): String {
    var schema = source
        .replace("https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v8.schema.json", DOC_IR_V9_ID)
        .replace("cjdoc Doc IR v8", "cjdoc Doc IR v9")
        .replace("cjdoc.doc-ir/8", "cjdoc.doc-ir/9")

    let repositoryDefinition = """
    "repository": {
      "type": "object", "additionalProperties": false,
      "required": ["url", "revision"],
      "properties": {
        "url": {"type": "string", "minLength": 1,
          "pattern": "^https://github.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"},
        "revision": {"type": "string", "minLength": 1}
      }
    },
"""
    schema = schema.replace("  \"$defs\": {\n", "  \"$defs\": {\n" + repositoryDefinition)
    schema = schema
        .replace("\"required\": [\"name\", \"kind\"]",
            "\"required\": [\"name\", \"kind\", \"repository\"]")
        .replace("\"kind\": {\"type\": \"string\", \"minLength\": 1}}",
            "\"kind\": {\"type\": \"string\", \"minLength\": 1}, " +
            "\"repository\": {\"anyOf\": [{\"$ref\": \"#/$defs/repository\"}, {\"type\": \"null\"}]}}")
        .replace("\"required\": [\"id\", \"name\", \"role\", \"sourcePrefix\", \"organization\", \"packageNames\", \"dependencyIds\"]",
            "\"required\": [\"id\", \"name\", \"role\", \"sourcePrefix\", \"organization\", \"repositoryPath\", \"packageNames\", \"dependencyIds\"]")
        .replace("\"dependencyIds\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/moduleId\"}}",
            "\"dependencyIds\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/moduleId\"}}, " +
            "\"repositoryPath\": {\"anyOf\": [{\"type\": \"null\"}, {\"const\": \"\"}, {\"$ref\": \"#/$defs/portablePath\"}]}" )
    schema = schema.replace(            "\"portablePath\": {\"type\": \"string\", \"minLength\": 1, " +
            "\"pattern\": \"^(?![A-Za-z]:)(?!.*\\\\\\\\)(?!\\\\.{1,2}(?:/|$))" +
            "(?!.*/\\\\.{1,2}(?:/|$))[^/]+(?:/[^/]+)*$\"}",
            "\"portablePath\": {\"type\": \"string\", \"minLength\": 1, " +
            "\"pattern\": \"^[^/]+(?:/[^/]+)*$\"}")
    schema
}

private let DOC_IR_CURRENT_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"

public let DOC_IR_V9_SCHEMA = buildDocIrV9Schema(DOC_IR_V8_SCHEMA)
public let DOC_IR_SCHEMA = DOC_IR_V9_SCHEMA.replace(DOC_IR_V9_ID, DOC_IR_CURRENT_ID)
