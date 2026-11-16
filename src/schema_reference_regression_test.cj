package cjdoc

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_algorithms.*

@Test
class SchemaReferenceRegressionTest {
    @TestCase
    func sharedLocalTargetsRemainDetachedAndInstanceIndependent(): Unit {
        let source = JsonNode.parse("{\"$defs\":{\"limit\":{\"type\":\"integer\",\"minimum\":2}}," +
            "\"type\":\"object\",\"properties\":{\"left\":{\"$ref\":\"#/$defs/limit\"}," +
            "\"right\":{\"$ref\":\"#/$defs/limit\"}},\"required\":[\"left\",\"right\"]}")
        let schema = JsonSchema(source)
        source.asObject().get("$defs").getOrThrow().asObject().get("limit").getOrThrow()
            .asObject().put("minimum", JsonNode.int64(100))
        schema.document.asObject().get("$defs").getOrThrow().asObject().get("limit").getOrThrow()
            .asObject().put("type", JsonNode.string("string"))
        let validator = schema.validator()
        @Expect(validator.isValid(JsonNode.parse("{\"left\":2,\"right\":3}")), true)
        @Expect(validator.isValid(JsonNode.parse("{\"left\":1,\"right\":3}")), false)
        @Expect(validator.isValid(JsonNode.parse("{\"left\":2,\"right\":\"3\"}")), false)
        @Expect(validator.isValid(JsonNode.parse("{\"left\":2,\"right\":3}")), true)
    }

    @TestCase
    func pointerIntoNestedResourceRetainsItsLocalReferenceBase(): Unit {
        let schema = JsonSchema.parse("{\"$defs\":{\"resource\":{\"$id\":\"https://example.test/limits/\"," +
            "\"$defs\":{\"bound\":{\"type\":\"integer\",\"minimum\":2}}," +
            "\"$ref\":\"#/$defs/bound\"}},\"$ref\":\"#/$defs/resource\"}")
        @Expect(schema.isValid(JsonNode.int64(2)), true)
        @Expect(schema.isValid(JsonNode.int64(1)), false)
    }

    @TestCase
    func externalPointerTargetsRemainBoundToCompiledRegistrySnapshot(): Unit {
        let uri = "https://example.test/schema/limits"
        let registry = JsonSchemaRegistry()
        registry.register(uri, "{\"$defs\":{\"bound\":{\"type\":\"integer\",\"minimum\":2}}}")
        let schema = JsonSchema.parse("{\"$ref\":\"" + uri + "#/$defs/bound\"}",
            config: JsonSchemaConfig(resolver: Some<UriResolver>(registry)))
        registry.register(uri, "{\"$defs\":{\"bound\":{\"type\":\"integer\",\"minimum\":100}}}")
        @Expect(schema.isValid(JsonNode.int64(2)), true)
        @Expect(schema.isValid(JsonNode.int64(1)), false)
    }

    @TestCase
    func referenceBudgetStillChargesEveryUseAndResetsForEachValidation(): Unit {
        let schema = JsonSchema.parse("{\"$defs\":{\"integer\":{\"type\":\"integer\"}}," +
            "\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/integer\"}}",
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxRefResolutions: 2)))
        let validator = schema.validator()
        let two = JsonNode.parse("[1,2]")
        let three = JsonNode.parse("[1,2,3]")
        @Expect(validator.isValid(two), true)
        var errorCode = ""
        try {
            let _ = validator.validate(three)
        } catch (error: JsonException) {
            errorCode = error.code
        }
        @Expect(errorCode, "work_limit_exceeded")
        @Expect(validator.isValid(two), true)
    }
}
