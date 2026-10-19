package cjdoc.schema_data

private let FLAT_TYPE_SEMANTIC_FIELDS = """
        "semanticState": {"$ref": "#/$defs/semanticState"},
        "semanticCanonical": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1, "pattern": "\\\\S"}]},
        "semanticProvider": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 1}]},
        "navigation": {"anyOf": [{"$ref": "#/$defs/typeNavigation"}, {"type": "null"}]}
      },
      "allOf": [
        {"if": {"properties": {"semanticState": {"const": "unavailable"}}},
          "then": {"properties": {"semanticCanonical": {"type": "null"}, "semanticProvider": {"type": "null"}}},
          "else": {"properties": {"semanticProvider": {"type": "string", "minLength": 1}}}},
        {"if": {"properties": {"semanticState": {"const": "resolved"}}},
          "then": {"properties": {"semanticCanonical": {"type": "string", "minLength": 1}}}}
      ]
"""

public let DEPENDENCY_IDENTITY_DEFINITIONS = """
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

public let DOC_IR_V15_SCHEMA = DOC_IR_V14_SCHEMA
    .replace("doc-ir-v14.schema.json", "doc-ir-v15.schema.json")
    .replace("cjdoc Doc IR v14", "cjdoc Doc IR v15")
    .replace("cjdoc.doc-ir/14", "cjdoc.doc-ir/15")
    .replace("\"apiCollectionState\", \"project\"", "\"apiCollectionState\", \"documentationRevision\", \"project\"")
    .replace("    \"project\": {\"$ref\": \"#/$defs/project\"},", "    \"documentationRevision\": {\"type\": \"string\"},\n    \"project\": {\"$ref\": \"#/$defs/project\"},")
    .replace("\"unboundSemanticDeclarations\", \"diagnostics\"]", "\"unboundSemanticDeclarations\", \"diagnostics\", \"dependencies\", \"documentSets\"]")
    .replace("    \"providers\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/provider\"}},", "    \"dependencies\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/dependencyInstance\"}},\n    \"documentSets\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/documentSetIdentity\"}},\n    \"providers\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/$defs/provider\"}},")
    .replace("[\"kind\", \"spelling\", \"nullable\", \"arguments\", \"semantic\"]", "[\"kind\", \"spelling\", \"nullable\", \"arguments\", \"semanticState\", \"semanticCanonical\", \"semanticProvider\", \"navigation\"]")
    .replace("        \"semantic\": {\"$ref\": \"#/$defs/semanticType\"}\n      }", FLAT_TYPE_SEMANTIC_FIELDS)
    .replace("\n    \"semanticState\":", "\n" + DEPENDENCY_IDENTITY_DEFINITIONS + "    \"semanticState\":")
    .replace("[\"name\", \"subject\", \"description\", \"referenceState\", \"targetSymbolId\"]",
        "[\"name\", \"subject\", \"description\", \"referenceState\", \"targetSymbolId\", \"navigation\"]")
    .replace("        \"evidenceKey\": {\"type\": \"string\"}",
        "        \"evidenceKey\": {\"type\": \"string\"},\n        \"navigation\": {\"anyOf\": [{\"$ref\": \"#/$defs/typeNavigation\"}, {\"type\": \"null\"}]}")

    .replace("\"referenceState\", \"targetSymbolId\", \"directives\"]", "\"referenceState\", \"targetSymbolId\", \"directives\", \"navigation\"]")
    .replace("\"targetSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"}, \"directives\": {\"type\": \"string\"}", "\"targetSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"}, \"directives\": {\"type\": \"string\"},\n        \"navigation\": {\"anyOf\": [{\"$ref\": \"#/$defs/typeNavigation\"}, {\"type\": \"null\"}]}")
    .replace("[\"target\", \"state\", \"targetSymbolId\", \"externalUrl\"]", "[\"target\", \"state\", \"targetSymbolId\", \"externalUrl\", \"semanticNavigation\"]")
    .replace("\"externalUrl\": {\"$ref\": \"#/$defs/nullableString\"}", "\"externalUrl\": {\"$ref\": \"#/$defs/nullableString\"},\n        \"semanticNavigation\": {\"anyOf\": [{\"$ref\": \"#/$defs/typeNavigation\"}, {\"type\": \"null\"}]}")

    .replace("[\"target\", \"selector\", \"provenance\", \"version\", \"sourceLine\", \"language\", \"state\", \"targetSymbolId\"]",
        "[\"target\", \"selector\", \"provenance\", \"version\", \"sourceLine\", \"language\", \"state\", \"targetSymbolId\", \"navigation\"]")
    .replace("            \"targetSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"}",
        "            \"targetSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"},\n            \"navigation\": {\"anyOf\": [{\"$ref\": \"#/$defs/typeNavigation\"}, {\"type\": \"null\"}]}")
    .replace("[\"name\", \"version\"]", "[\"name\", \"version\", \"toolchain\"]")
    .replace("\"properties\": {\"name\": {\"const\": \"cjdoc\"}, \"version\": {\"type\": \"string\", \"minLength\": 1}}", "\"properties\": {\"name\": {\"const\": \"cjdoc\"}, \"version\": {\"type\": \"string\", \"minLength\": 1}, \"toolchain\": {\"type\": \"string\"}}")

public let DOC_IR_SCHEMA = DOC_IR_V15_SCHEMA.replace("doc-ir-v15.schema.json", "doc-ir.schema.json")
