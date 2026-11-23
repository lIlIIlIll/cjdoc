package cjdoc.schema_data

internal let DOC_IR_V18_EXTERNAL_NAVIGATION = """
    "dependencyInstance": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "moduleId",
        "componentModuleId",
        "name",
        "instanceId",
        "kind",
        "identity",
        "state",
        "evidence",
        "version",
        "revision",
        "target",
        "cfg"
      ],
      "properties": {
        "moduleId": {
          "type": "string",
          "minLength": 1
        },
        "componentModuleId": {"type": "string"},
        "name": {
          "type": "string",
          "minLength": 1
        },
        "instanceId": {
          "type": "string",
          "minLength": 1
        },
        "kind": {
          "enum": [
            "source",
            "binary",
            "std",
            "stdx",
            "toolchain"
          ]
        },
        "identity": {
          "type": "string"
        },
        "state": {
          "enum": [
            "unknown",
            "declared",
            "observed",
            "verified",
            "conflict"
          ]
        },
        "evidence": {
          "type": "string"
        },
        "version": {
          "type": "string"
        },
        "revision": {
          "type": "string"
        },
        "target": {
          "type": "string"
        },
        "cfg": {
          "type": "string"
        }
      }
    },
    "documentSetIdentity": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "moduleId",
        "library",
        "identity",
        "state",
        "source",
        "target",
        "cfg",
        "audience",
        "language",
        "revision",
        "apiVersion",
        "documentationRevision",
        "indexIdentity",
        "baseUrl"
      ],
      "properties": {
        "id": {
          "type": "string",
          "minLength": 1
        },
        "moduleId": {"type": "string"},
        "library": {
          "type": "string",
          "minLength": 1
        },
        "identity": {
          "type": "string"
        },
        "state": {
          "enum": [
            "observed",
            "verified",
            "declared",
            "unknown"
          ]
        },
        "source": {
          "type": "string"
        },
        "target": {
          "type": "string"
        },
        "cfg": {
          "type": "string"
        },
        "audience": {
          "type": "string"
        },
        "language": {
          "type": "string"
        },
        "revision": {
          "type": "string"
        },
        "apiVersion": {"type": "string"},
        "documentationRevision": {"type": "string"},
        "indexIdentity": {
          "type": "string"
        },
        "baseUrl": {
          "type": "string"
        }
      }
    },
    "typeNavigation": {
      "oneOf": [
        {"$ref": "#/$defs/contextFreeNavigationFailure"},
        {"$ref": "#/$defs/contextualTypeNavigation"}
      ]
    },
    "contextFreeNavigationFailure": {
      "type": "array",
      "minItems": 2,
      "maxItems": 2,
      "prefixItems": [
        {"enum": ["unresolved", "ambiguous", "unavailable"]},
        {"type": "string", "minLength": 1}
      ],
      "items": false
    },
    "contextualTypeNavigation": {
      "type": "object",
      "additionalProperties": false,
      "not": {
        "properties": {
          "state": {"enum": ["unresolved", "ambiguous", "unavailable"]},
          "matchLevel": {"const": "none"},
          "dependencyInstanceId": {"const": ""},
          "documentSetId": {"const": ""},
          "indexIdentity": {"const": ""},
          "symbolKey": {"const": ""},
          "url": {"const": ""},
          "apiIdentity": {"const": ""},
          "language": {"const": ""}
        }
      },
      "required": [
        "state",
        "matchLevel",
        "reason",
        "dependencyInstanceId",
        "documentSetId",
        "indexIdentity",
        "symbolKey",
        "url",
        "apiIdentity",
        "language"
      ],
      "properties": {
        "state": {
          "enum": [
            "resolved",
            "unresolved",
            "ambiguous",
            "unavailable"
          ]
        },
        "matchLevel": {
          "enum": [
            "exact",
            "compatible",
            "manual",
            "none"
          ]
        },
        "reason": {
          "type": "string",
          "minLength": 1
        },
        "dependencyInstanceId": {
          "type": "string"
        },
        "documentSetId": {
          "type": "string"
        },
        "indexIdentity": {
          "type": "string"
        },
        "symbolKey": {
          "type": "string"
        },
        "url": {
          "type": "string"
        },
        "apiIdentity": {
          "type": "string"
        },
        "language": {
          "type": "string"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "state": {
                "const": "resolved"
              }
            }
          },
          "then": {
            "properties": {
              "url": {
                "minLength": 1
              },
              "matchLevel": {
                "enum": [
                  "exact",
                  "compatible",
                  "manual"
                ]
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "state": {
                "enum": [
                  "unresolved",
                  "ambiguous",
                  "unavailable"
                ]
              }
            }
          },
          "then": {
            "properties": {
              "url": {
                "const": ""
              }
            }
          }
        }
      ]
    },
"""
