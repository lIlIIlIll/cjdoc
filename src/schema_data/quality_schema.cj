package cjdoc.schema_data

public let DOCUMENTATION_QUALITY_SCHEMA = """
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-quality.schema.json",
  "title": "cjdoc documentation placeholder quality v1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "audience",
    "assessment",
    "symbols",
    "parameters",
    "findings"
  ],
  "properties": {
    "schemaVersion": {
      "const": "cjdoc.documentation-quality/1"
    },
    "audience": {
      "enum": [
        "external",
        "package",
        "all"
      ]
    },
    "assessment": {
      "const": "conservative-placeholder-heuristic"
    },
    "symbols": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "total",
        "meaningful",
        "percent"
      ],
      "properties": {
        "total": {
          "type": "integer",
          "minimum": 0
        },
        "meaningful": {
          "type": "integer",
          "minimum": 0
        },
        "percent": {
          "type": "integer",
          "minimum": 0,
          "maximum": 100
        }
      }
    },
    "parameters": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "total",
        "meaningful",
        "percent"
      ],
      "properties": {
        "total": {
          "type": "integer",
          "minimum": 0
        },
        "meaningful": {
          "type": "integer",
          "minimum": 0
        },
        "percent": {
          "type": "integer",
          "minimum": 0,
          "maximum": 100
        }
      }
    },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": [
          "symbolId",
          "code",
          "message"
        ],
        "properties": {
          "symbolId": {
            "type": "string"
          },
          "code": {
            "enum": [
              "CJDOC3040",
              "CJDOC3041",
              "CJDOC3042"
            ]
          },
          "message": {
            "type": "string"
          }
        }
      }
    }
  }
}
"""
