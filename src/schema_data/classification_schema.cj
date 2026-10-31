package cjdoc.schema_data

import yjson.*

private let DOCUMENTATION_CLASSIFICATION_DEFINITIONS = """
{
  "classificationId": {
    "type": "string", "minLength": 1, "maxLength": 64,
    "pattern": "^[A-Za-z0-9_-]+$"
  },
  "classificationTitle": {
    "type": "string", "minLength": 1, "maxLength": 256, "x-maxUtf8Bytes": 256,
    "description": "Serialized titles are limited to 1–256 UTF-8 bytes by the producer; maxLength limits Unicode code points and does not enforce that byte bound.",
    "pattern": "^[^\\\\u0000-\\\\u001f\\\\u007f]+$",
    "not": {"pattern": "^[ \\\\t\\\\n\\\\r\\\\f\\\\u000b]*$"}
  },
  "documentationClassificationTag": {
    "type": "object", "additionalProperties": false,
    "required": ["id", "title"],
    "properties": {
      "id": {"$ref": "#/$defs/classificationId"},
      "title": {"$ref": "#/$defs/classificationTitle"}
    }
  },
  "documentationClassificationGroup": {
    "type": "object", "additionalProperties": false,
    "required": ["id", "packageName", "ownerId", "title", "order"],
    "properties": {
      "id": {"$ref": "#/$defs/classificationId"},
      "packageName": {"type": "string", "minLength": 1},
      "ownerId": {"anyOf": [{"type": "string", "minLength": 1}, {"type": "null"}]},
      "title": {"$ref": "#/$defs/classificationTitle"},
      "order": {"anyOf": [{"type": "integer", "minimum": 0, "maximum": 999999}, {"type": "null"}]}
    }
  },
  "documentationClassification": {
    "type": "object", "additionalProperties": false,
    "required": ["group", "tags"],
    "properties": {
      "group": {"anyOf": [{"$ref": "#/$defs/documentationClassificationGroup"}, {"type": "null"}]},
      "tags": {"type": "array", "items": {"$ref": "#/$defs/documentationClassificationTag"}}
    }
  }
}
"""

internal func addDocumentationClassificationDefinitions(definitions: JsonObject): Unit {
    let shared = JsonNode.parse(DOCUMENTATION_CLASSIFICATION_DEFINITIONS).asObject()
    for (index in 0..shared.size()) {
        let name = shared.nameAt(index)
        if (definitions.contains(name)) {
            throw IllegalArgumentException("schema redefines documentation classification definition '${name}'")
        }
        definitions.put(name, shared.valueAt(index))
    }
}

internal func documentationSchemaWithClassification(template: String): String {
    let schema = JsonNode.parse(template).asObject()
    let definitions = match (schema.get("$defs")) {
        case Some(node) => node.asObject()
        case None => throw IllegalArgumentException("schema template has no $defs")
    }
    addDocumentationClassificationDefinitions(definitions)
    schema.toJson()
}
