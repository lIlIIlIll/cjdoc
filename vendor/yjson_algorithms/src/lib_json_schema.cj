package yjson_algorithms

import yjson.*

import std.collection.*
import std.convert.Parsable
import std.math.numeric.*
import std.regex.*
import std.unicode.*

public class JsonValidationError <: JsonException {
    public let jsonPath: String
    public let schemaPath: String

    public init(jsonPath: String, schemaPath: String, message: String,
        code!: String = "schema_validation") {
        super("${jsonPath} ${schemaPath}: ${message}", code: code, path: jsonPath)
        this.jsonPath = jsonPath
        this.schemaPath = schemaPath
    }

    protected override func getClassName(): String {
        "JsonValidationError"
    }
}

/// A named JSON Schema format assertion.
public interface JsonSchemaFormat {
    func validate(value: String): Bool
}

/// Installs a coherent group of format assertions into a registry.
public interface JsonSchemaFormatProvider {
    func installInto(registry: JsonSchemaFormatRegistry): Unit
}

/// Explicit format registry used by Assertion and StrictAssertion modes.
public class JsonSchemaFormatRegistry {
    private let formats = HashMap<String, JsonSchemaFormat>()
    private var frozen: Bool = false

    public func register(name: String, format: JsonSchemaFormat, replace!: Bool = false): Unit {
        if (frozen) { throw IllegalStateException("Schema format registry is immutable") }
        if (name.isEmpty()) { throw IllegalArgumentException("Schema format name must not be empty") }
        if (!replace && formats.get(name).isSome()) {
            throw IllegalArgumentException("Schema format ${name} is already registered")
        }
        formats[name] = format
    }

    public func install(provider: JsonSchemaFormatProvider): Unit { provider.installInto(this) }

    public func resolve(name: String): Option<JsonSchemaFormat> { formats.get(name) }

    public static func withCoreFormats(): JsonSchemaFormatRegistry {
        let registry = JsonSchemaFormatRegistry()
        for (name in ["date", "time", "date-time", "duration", "email", "ipv4", "ipv6", "uuid",
            "regex", "json-pointer", "relative-json-pointer"]) {
            registry.register(name, CoreJsonSchemaFormat(name))
        }
        registry
    }

    func frozenCopy(): JsonSchemaFormatRegistry {
        let copy = JsonSchemaFormatRegistry()
        for ((name, format) in formats) { copy.formats[name] = format }
        copy.frozen = true
        copy
    }
}

public interface UriResolver {
    /// Resolves an absolute or application-defined schema resource URI.
    /// Implementations may load from memory, disk, or an application cache;
    /// yjson itself never performs network I/O.
    func resolve(uri: String): Option<JsonNode>
}

public class JsonSchemaRegistry <: UriResolver {
    private let resources = HashMap<String, JsonNode>()

    public func register(uri: String, schema: JsonNode): Unit {
        if (uri.isEmpty() || uri.contains("#")) {
            throw IllegalArgumentException("Schema registry URI must be a non-empty resource URI without a fragment")
        }
        resources[uri] = schema.deepCopy()
    }

    public func register(uri: String, schemaText: String): Unit { register(uri, YJson.parse(schemaText)) }

    public func resolve(uri: String): Option<JsonNode> {
        match (resources.get(uri)) {
            case Some(value) => Some(value.deepCopy())
            case None => None<JsonNode>
        }
    }
}

public enum JsonSchemaFormatMode { Annotation | Assertion | StrictAssertion }

public class JsonSchemaConfig {
    public let resolver: Option<UriResolver>
    public let formatMode: JsonSchemaFormatMode
    public let formats: JsonSchemaFormatRegistry
    public let limits: JsonSchemaLimits

    public init(resolver!: Option<UriResolver> = None<UriResolver>,
        formatMode!: JsonSchemaFormatMode = JsonSchemaFormatMode.Annotation,
        formats!: JsonSchemaFormatRegistry = JsonSchemaFormatRegistry.withCoreFormats(),
        limits!: JsonSchemaLimits = JsonSchemaLimits.defaults) {
        this.resolver = resolver
        this.formatMode = formatMode
        this.formats = formats
        this.limits = limits
    }

    public static let defaults = JsonSchemaConfig(
        formats: JsonSchemaFormatRegistry.withCoreFormats().frozenCopy())
}

public class JsonSchema {
    private let documentValue: JsonNode
    public let draft: String
    public let config: JsonSchemaConfig
    let validationVocabulary: Bool

    /// Returns a detached copy so callers cannot mutate the compiled schema.
    public prop document: JsonNode {
        get() { documentValue.deepCopy() }
    }

    public init(document: JsonNode, draft!: String = "https://json-schema.org/draft/2020-12/schema",
        config!: JsonSchemaConfig = JsonSchemaConfig.defaults) {
        let frozenDocument = document.deepCopy()
        this.documentValue = frozenDocument
        this.draft = draft
        this.config = JsonSchemaConfig(resolver: config.resolver, formatMode: config.formatMode,
            formats: config.formats.frozenCopy(), limits: config.limits)
        if (draft != "https://json-schema.org/draft/2020-12/schema" &&
            draft != "https://json-schema.org/draft/2020-12/schema#") {
            throw JsonException("Unsupported JSON Schema dialect ${draft}", code: "unsupported_schema_dialect")
        }
        var usesValidationVocabulary = true
        match (frozenDocument) {
            case objectValue: JsonObjectValue => match (objectValue.get("$schema")) {
                case Some(value) =>
                    let declared = value.asString().value
                    if (declared != "https://json-schema.org/draft/2020-12/schema" &&
                        declared != "https://json-schema.org/draft/2020-12/schema#") {
                        match (this.config.resolver) {
                            case Some(resolver) => match (resolver.resolve(stripJsonSchemaFragment(declared))) {
                                case Some(metaSchema) =>
                                    match (metaSchema.asObject().get("$vocabulary")) {
                                        case Some(vocabularies) => usesValidationVocabulary =
                                            vocabularies.asObject().contains(
                                                "https://json-schema.org/draft/2020-12/vocab/validation")
                                        case None => ()
                                    }
                                case None => throw JsonException("Unsupported JSON Schema dialect ${declared}",
                                    code: "unsupported_schema_dialect")
                            }
                            case None => throw JsonException("Unsupported JSON Schema dialect ${declared}",
                                code: "unsupported_schema_dialect")
                        }
                    }
                case None => ()
            }
            case _ => ()
        }
        this.validationVocabulary = usesValidationVocabulary
        validateJsonSchemaDocument(frozenDocument, "#")
    }

    public static func parse(text: String, config!: JsonSchemaConfig = JsonSchemaConfig.defaults): JsonSchema {
        JsonSchema(YJson.parse(text), config: config)
    }

    public static func fromValue(value: JsonNode, config!: JsonSchemaConfig = JsonSchemaConfig.defaults): JsonSchema {
        JsonSchema(value, config: config)
    }

    public func validator(): JsonSchemaValidator {
        JsonSchemaValidator(this)
    }

    public func validate(instance: JsonNode): ArrayList<JsonValidationError> {
        validator().validate(instance)
    }

    public func validateOrThrow(instance: JsonNode): Unit {
        validator().validateOrThrow(instance)
    }

    func internalDocument(): JsonNode { documentValue }
}

public class JsonSchemaValidator {
    private let schema: JsonSchema
    private let baseUriStack = ArrayList<String>()
    private let resourceStack = ArrayList<JsonNode>()
    private var evaluationCount: Int64 = 0
    private var refResolutionCount: Int64 = 0
    private var validationDepth: Int64 = 0

    public init(schema: JsonSchema) {
        this.schema = schema
    }

    public func validate(instance: JsonNode): ArrayList<JsonValidationError> {
        let errors = ArrayList<JsonValidationError>()
        baseUriStack.clear()
        resourceStack.clear()
        evaluationCount = 0
        refResolutionCount = 0
        validationDepth = 0
        baseUriStack.add("")
        let document = schema.internalDocument()
        resourceStack.add(document)
        validateSchemaValue(document, instance, "$", "#", errors, ArrayList<String>())
        baseUriStack.clear()
        resourceStack.clear()
        errors
    }

    public func isValid(instance: JsonNode): Bool {
        validate(instance).isEmpty()
    }

    public func validateOrThrow(instance: JsonNode): Unit {
        let errors = validate(instance)
        if (!errors.isEmpty()) {
            throw errors[0]
        }
    }

    private func validateSchemaValue(
        schemaValue: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        consumeEvaluation()
        enforceWorkLimit(validationDepth, schema.config.limits.maxDepth, "schema depth")
        validationDepth++
        try {
            match (schemaValue) {
                case boolSchema: JsonBoolValue =>
                    if (!boolSchema.value) {
                        addError(errors, jsonPath, schemaPath, "boolean schema false rejects every value")
                    }
                    return
                case objectSchema: JsonObjectValue =>
                    validateObjectSchema(objectSchema, instance, jsonPath, schemaPath, errors, refStack)
                case _ =>
                    addError(errors, jsonPath, schemaPath, "schema must be a boolean or object")
            }
        } finally {
            validationDepth--
        }
    }

    private func validateObjectSchema(
        objectSchema: JsonObjectValue,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let inheritedBase = baseUriStack[baseUriStack.size - 1]
        let inheritedResource = resourceStack[resourceStack.size - 1]
        var effectiveBase = inheritedBase
        var effectiveResource = inheritedResource
        match (objectSchema.get("$id")) {
            case Some(idValue) =>
                let idText = idValue.asString().value
                let idWithoutFragment = stripJsonSchemaFragment(idText)
                effectiveBase = if (objectSchema.equivalentTo(inheritedResource) &&
                    !idWithoutFragment.isEmpty() && stripJsonSchemaFragment(inheritedBase).endsWith(idWithoutFragment)) {
                    inheritedBase
                } else { resolveJsonSchemaUri(inheritedBase, idText) }
                if (!idValue.asString().value.contains("#")) { effectiveResource = objectSchema }
            case None => ()
        }
        baseUriStack.add(effectiveBase)
        resourceStack.add(effectiveResource)
        match (objectSchema.get("$ref")) {
            case Some(refValue) =>
                let refText = refValue.asString().value
                let refKey = refText + "|" + jsonPath
                if (containsText(refStack, refKey)) {
                    addError(errors, jsonPath, appendSchemaPath(schemaPath, "$ref"), "cyclic $ref ${refText}")
                } else if (refText == "https://json-schema.org/draft/2020-12/schema" ||
                    refText == "https://json-schema.org/draft/2020-12/schema#") {
                    try { validateJsonSchemaDocument(instance, "#") }
                    catch (error: Exception) { addError(errors, jsonPath,
                        appendSchemaPath(schemaPath, "$ref"), error.message) }
                } else {
                    refStack.add(refKey)
                    match (resolveRef(refText)) {
                        case Some(target) =>
                            baseUriStack.add(target.baseUri)
                            resourceStack.add(target.resource)
                            validateSchemaValue(target.value, instance, jsonPath, target.schemaPath, errors, refStack)
                            baseUriStack.remove(at: baseUriStack.size - 1)
                            resourceStack.remove(at: resourceStack.size - 1)
                        case None =>
                            let description = if (refText.startsWith("#")) { "unresolved local $ref" } else { "unresolved $ref" }
                            addError(errors, jsonPath, appendSchemaPath(schemaPath, "$ref"), "${description} ${refText}")
                    }
                    refStack.remove(at: refStack.size - 1)
                }
            case None => ()
        }

        match (objectSchema.get("$dynamicRef")) {
            case Some(refValue) =>
                let refText = refValue.asString().value
                let refKey = "$dynamicRef:" + refText + "|" + jsonPath
                if (!containsText(refStack, refKey)) {
                    refStack.add(refKey)
                    match (resolveDynamicRef(refText)) {
                        case Some(target) =>
                            baseUriStack.add(target.baseUri)
                            resourceStack.add(target.resource)
                            validateSchemaValue(target.value, instance, jsonPath, target.schemaPath, errors, refStack)
                            baseUriStack.remove(at: baseUriStack.size - 1)
                            resourceStack.remove(at: resourceStack.size - 1)
                        case None => addError(errors, jsonPath, appendSchemaPath(schemaPath, "$dynamicRef"),
                            "unresolved $dynamicRef ${refText}")
                    }
                    refStack.remove(at: refStack.size - 1)
                }
            case None => ()
        }

        if (schema.validationVocabulary) { match (objectSchema.get("type")) {
            case Some(typeSchema) => validateType(typeSchema, instance, jsonPath, appendSchemaPath(schemaPath, "type"), errors)
            case None => ()
        } }

        match (objectSchema.get("enum")) {
            case Some(enumSchema) => validateEnum(enumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "enum"), errors)
            case None => ()
        }

        match (objectSchema.get("const")) {
            case Some(constSchema) =>
                if (!constSchema.equivalentTo(instance)) {
                    addError(errors, jsonPath, appendSchemaPath(schemaPath, "const"), "value must equal const")
                }
            case None => ()
        }

        if (schema.validationVocabulary) { match (objectSchema.get("minimum")) {
            case Some(minimumSchema) => validateNumericLimit(minimumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "minimum"), true, errors)
            case None => ()
        } }

        if (schema.validationVocabulary) { match (objectSchema.get("maximum")) {
            case Some(maximumSchema) => validateNumericLimit(maximumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "maximum"), false, errors)
            case None => ()
        } }

        if (schema.validationVocabulary) {
            validateExtendedNumericKeywords(objectSchema, instance, jsonPath, schemaPath, errors)
        }

        match (objectSchema.get("minLength")) {
            case Some(minLengthSchema) => validateStringLength(minLengthSchema, instance, jsonPath, appendSchemaPath(schemaPath, "minLength"), true, errors)
            case None => ()
        }

        match (objectSchema.get("maxLength")) {
            case Some(maxLengthSchema) => validateStringLength(maxLengthSchema, instance, jsonPath, appendSchemaPath(schemaPath, "maxLength"), false, errors)
            case None => ()
        }

        validateStringKeywords(objectSchema, instance, jsonPath, schemaPath, errors)

        match (objectSchema.get("format")) {
            case Some(formatValue) => validateFormat(formatValue.asString().value, instance, jsonPath,
                appendSchemaPath(schemaPath, "format"), errors)
            case None => ()
        }

        match (objectSchema.get("required")) {
            case Some(requiredSchema) => validateRequired(requiredSchema, instance, jsonPath, appendSchemaPath(schemaPath, "required"), errors)
            case None => ()
        }

        match (objectSchema.get("properties")) {
            case Some(propertiesSchema) => validateProperties(propertiesSchema, instance, jsonPath, appendSchemaPath(schemaPath, "properties"), errors, refStack)
            case None => ()
        }

        validateObjectKeywords(objectSchema, instance, jsonPath, schemaPath, errors, refStack)

        if (objectSchema.get("prefixItems").isNone()) {
            match (objectSchema.get("items")) {
                case Some(itemsSchema) => validateItems(itemsSchema, instance, jsonPath, appendSchemaPath(schemaPath, "items"), errors, refStack)
                case None => ()
            }
        }

        validateArrayKeywords(objectSchema, instance, jsonPath, schemaPath, errors, refStack)

        match (objectSchema.get("allOf")) {
            case Some(combinatorSchema) => validateAllOf(combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "allOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("anyOf")) {
            case Some(combinatorSchema) => validateAnyOf(combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "anyOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("oneOf")) {
            case Some(combinatorSchema) => validateOneOf(combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "oneOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("not")) {
            case Some(notSchema) => validateNot(notSchema, instance, jsonPath, appendSchemaPath(schemaPath, "not"), errors, refStack)
            case None => ()
        }


        match (objectSchema.get("if")) {
            case Some(ifSchema) =>
                let conditionErrors = ArrayList<JsonValidationError>()
                validateSchemaValue(ifSchema, instance, jsonPath, appendSchemaPath(schemaPath, "if"), conditionErrors, refStack)
                let branch = if (conditionErrors.isEmpty()) { "then" } else { "else" }
                match (objectSchema.get(branch)) {
                    case Some(branchSchema) => validateSchemaValue(branchSchema, instance, jsonPath,
                        appendSchemaPath(schemaPath, branch), errors, refStack)
                    case None => ()
                }
            case None => ()
        }
        baseUriStack.remove(at: baseUriStack.size - 1)
        resourceStack.remove(at: resourceStack.size - 1)
    }

    private func validateExtendedNumericKeywords(objectSchema: JsonObjectValue, instance: JsonNode,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonValidationError>): Unit {
        match (jsonNodeAsDecimal(instance)) {
            case Some(number) =>
                match (objectSchema.get("exclusiveMinimum")) {
                    case Some(limitValue) =>
                        let limit = requireSchemaDecimal(limitValue, appendSchemaPath(schemaPath, "exclusiveMinimum"))
                        if (number <= limit) { addError(errors, jsonPath, appendSchemaPath(schemaPath, "exclusiveMinimum"),
                            "number must be > ${limit}") }
                    case None => ()
                }
                match (objectSchema.get("exclusiveMaximum")) {
                    case Some(limitValue) =>
                        let limit = requireSchemaDecimal(limitValue, appendSchemaPath(schemaPath, "exclusiveMaximum"))
                        if (number >= limit) { addError(errors, jsonPath, appendSchemaPath(schemaPath, "exclusiveMaximum"),
                            "number must be < ${limit}") }
                    case None => ()
                }
                match (objectSchema.get("multipleOf")) {
                    case Some(divisorValue) =>
                        let divisor = requireSchemaDecimal(divisorValue, appendSchemaPath(schemaPath, "multipleOf"))
                        if (divisor <= Decimal(0)) { throw JsonException("${appendSchemaPath(schemaPath, "multipleOf")}: expected a positive number") }
                        let (_, remainder) = number.divAndMod(divisor)
                        if (remainder != Decimal(0)) { addError(errors, jsonPath,
                            appendSchemaPath(schemaPath, "multipleOf"), "number must be a multiple of ${divisor}") }
                    case None => ()
                }
            case None => ()
        }
    }

    private func validateStringKeywords(objectSchema: JsonObjectValue, instance: JsonNode,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonValidationError>): Unit {
        match (instance) {
            case stringValue: JsonStringValue =>
                match (objectSchema.get("pattern")) {
                    case Some(patternValue) =>
                        let pattern = patternValue.asString().value
                        if (!jsonSchemaRegexFind(pattern, stringValue.value)) {
                            addError(errors, jsonPath, appendSchemaPath(schemaPath, "pattern"),
                                "string must match pattern ${pattern}")
                        }
                    case None => ()
                }
            case _ => ()
        }
    }

    private func validateObjectKeywords(objectSchema: JsonObjectValue, instance: JsonNode,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>): Unit {
        match (instance) {
            case objectValue: JsonObjectValue =>
                validateObjectSizeKeyword(objectSchema, objectValue, jsonPath, schemaPath, "minProperties", true, errors)
                validateObjectSizeKeyword(objectSchema, objectValue, jsonPath, schemaPath, "maxProperties", false, errors)
                let matched = HashSet<String>()
                match (objectSchema.get("properties")) {
                    case Some(value) => for ((name, _) in value.asObject().entries()) {
                        if (objectValue.contains(name)) { matched.add(name) }
                    }
                    case None => ()
                }
                match (objectSchema.get("patternProperties")) {
                    case Some(value) => for ((pattern, childSchema) in value.asObject().entries()) {
                        for ((name, child) in objectValue.entries()) {
                            if (jsonSchemaRegexFind(pattern, name)) {
                                matched.add(name)
                                validateSchemaValue(childSchema, child, appendJsonPath(jsonPath, name),
                                    appendSchemaPath(appendSchemaPath(schemaPath, "patternProperties"), pattern), errors, refStack)
                            }
                        }
                    }
                    case None => ()
                }
                match (objectSchema.get("propertyNames")) {
                    case Some(nameSchema) => for ((name, _) in objectValue.entries()) {
                        validateSchemaValue(nameSchema, JsonStringValue(name), appendJsonPath(jsonPath, name),
                            appendSchemaPath(schemaPath, "propertyNames"), errors, refStack)
                    }
                    case None => ()
                }
                match (objectSchema.get("dependentRequired")) {
                    case Some(value) => for ((trigger, requiredValue) in value.asObject().entries()) {
                        if (objectValue.contains(trigger)) {
                            for (index in 0..requiredValue.asArray().size()) {
                                let requiredName = requiredValue.asArray()[index].asString().value
                                if (!objectValue.contains(requiredName)) { addError(errors, jsonPath,
                                    appendSchemaPath(appendSchemaPath(schemaPath, "dependentRequired"), trigger),
                                    "property ${trigger} requires property ${requiredName}") }
                            }
                        }
                    }
                    case None => ()
                }
                match (objectSchema.get("dependentSchemas")) {
                    case Some(value) => for ((trigger, childSchema) in value.asObject().entries()) {
                        if (objectValue.contains(trigger)) { validateSchemaValue(childSchema, instance, jsonPath,
                            appendSchemaPath(appendSchemaPath(schemaPath, "dependentSchemas"), trigger), errors, refStack) }
                    }
                    case None => ()
                }
                let extraSchema = match (objectSchema.get("additionalProperties")) {
                    case Some(value) => Some(value)
                    case None => None<JsonNode>
                }
                match (extraSchema) {
                    case Some(childSchema) => for ((name, child) in objectValue.entries()) {
                        if (!matched.contains(name)) { validateSchemaValue(childSchema, child, appendJsonPath(jsonPath, name),
                            appendSchemaPath(schemaPath, "additionalProperties"), errors, refStack) }
                    }
                    case None => match (objectSchema.get("unevaluatedProperties")) {
                        case Some(childSchema) =>
                            let evaluated = collectEvaluatedProperties(objectSchema, objectValue, refStack, true)
                            for ((name, child) in objectValue.entries()) {
                                if (!evaluated.contains(name)) { validateSchemaValue(childSchema, child,
                                    appendJsonPath(jsonPath, name), appendSchemaPath(schemaPath, "unevaluatedProperties"),
                                    errors, refStack) }
                            }
                        case None => ()
                    }
                }
            case _ => ()
        }
    }

    private func schemaValueIsValid(value: JsonNode, instance: JsonNode,
        refStack: ArrayList<String>): Bool {
        let nested = ArrayList<JsonValidationError>()
        validateSchemaValue(value, instance, "$", "#", nested, refStack)
        nested.isEmpty()
    }

    private func addEvaluatedPropertiesFromSchema(result: HashSet<String>, value: JsonNode,
        instance: JsonObjectValue, refStack: ArrayList<String>): Unit {
        match (value) {
            case objectValue: JsonObjectValue =>
                let nested = collectEvaluatedProperties(objectValue, instance, refStack, false)
                for (name in nested) { result.add(name) }
            case _ => ()
        }
    }

    private func collectEvaluatedProperties(objectSchema: JsonObjectValue, instance: JsonObjectValue,
        refStack: ArrayList<String>, ignoreOwnUnevaluated: Bool): HashSet<String> {
        let result = HashSet<String>()
        match (objectSchema.get("properties")) {
            case Some(value) => for ((name, _) in value.asObject().entries()) {
                if (instance.contains(name)) { result.add(name) }
            }
            case None => ()
        }
        match (objectSchema.get("patternProperties")) {
            case Some(value) => for ((pattern, _) in value.asObject().entries()) {
                for ((name, _) in instance.entries()) { if (jsonSchemaRegexFind(pattern, name)) { result.add(name) } }
            }
            case None => ()
        }
        match (objectSchema.get("additionalProperties")) {
            case Some(value) => for ((name, child) in instance.entries()) {
                if (!result.contains(name) && schemaValueIsValid(value, child, refStack)) { result.add(name) }
            }
            case None => ()
        }
        match (objectSchema.get("dependentSchemas")) {
            case Some(value) => for ((trigger, childSchema) in value.asObject().entries()) {
                if (instance.contains(trigger) && schemaValueIsValid(childSchema, instance, refStack)) {
                    addEvaluatedPropertiesFromSchema(result, childSchema, instance, refStack)
                }
            }
            case None => ()
        }
        for (keyword in ["allOf", "anyOf", "oneOf"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => for (childSchema in value.asArray().values()) {
                    if (schemaValueIsValid(childSchema, instance, refStack)) {
                        addEvaluatedPropertiesFromSchema(result, childSchema, instance, refStack)
                    }
                }
                case None => ()
            }
        }
        match (objectSchema.get("if")) {
            case Some(condition) =>
                let conditionMatches = schemaValueIsValid(condition, instance, refStack)
                if (conditionMatches) { addEvaluatedPropertiesFromSchema(result, condition, instance, refStack) }
                let branch = if (conditionMatches) { "then" } else { "else" }
                match (objectSchema.get(branch)) {
                    case Some(value) => if (schemaValueIsValid(value, instance, refStack)) {
                        addEvaluatedPropertiesFromSchema(result, value, instance, refStack)
                    }
                    case None => ()
                }
            case None => ()
        }
        for (keyword in ["$ref", "$dynamicRef"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => match (if (keyword == "$dynamicRef") {
                    resolveDynamicRef(value.asString().value)
                } else { resolveRef(value.asString().value) }) {
                    case Some(target) =>
                        baseUriStack.add(target.baseUri); resourceStack.add(target.resource)
                        if (schemaValueIsValid(target.value, instance, refStack)) {
                            addEvaluatedPropertiesFromSchema(result, target.value, instance, refStack)
                        }
                        resourceStack.remove(at: resourceStack.size - 1); baseUriStack.remove(at: baseUriStack.size - 1)
                    case None => ()
                }
                case None => ()
            }
        }
        if (!ignoreOwnUnevaluated) {
            match (objectSchema.get("unevaluatedProperties")) {
                case Some(value) => for ((name, child) in instance.entries()) {
                    if (!result.contains(name) && schemaValueIsValid(value, child, refStack)) { result.add(name) }
                }
                case None => ()
            }
        }
        result
    }

    private func validateObjectSizeKeyword(objectSchema: JsonObjectValue, instance: JsonObjectValue,
        jsonPath: String, schemaPath: String, keyword: String, minimum: Bool,
        errors: ArrayList<JsonValidationError>): Unit {
        match (objectSchema.get(keyword)) {
            case Some(value) =>
                let limit = requireSchemaNonNegativeInt(value, appendSchemaPath(schemaPath, keyword))
                if ((minimum && instance.size() < limit) || (!minimum && instance.size() > limit)) {
                    addError(errors, jsonPath, appendSchemaPath(schemaPath, keyword),
                        "object property count must be ${if (minimum) { ">=" } else { "<=" }} ${limit}")
                }
            case None => ()
        }
    }

    private func validateArrayKeywords(objectSchema: JsonObjectValue, instance: JsonNode,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>): Unit {
        match (instance) {
            case arrayValue: JsonArrayValue =>
                validateArraySizeKeyword(objectSchema, arrayValue, jsonPath, schemaPath, "minItems", true, errors)
                validateArraySizeKeyword(objectSchema, arrayValue, jsonPath, schemaPath, "maxItems", false, errors)
                match (objectSchema.get("uniqueItems")) {
                    case Some(value) => if (value.asBool().value) {
                        for (i in 0..arrayValue.size()) { for (j in i + 1..arrayValue.size()) {
                            consumeEvaluation()
                            if (arrayValue[i].equivalentTo(arrayValue[j])) { addError(errors, jsonPath,
                                appendSchemaPath(schemaPath, "uniqueItems"), "array items must be unique"); return }
                        }}
                    }
                    case None => ()
                }
                var prefixCount: Int64 = 0
                match (objectSchema.get("prefixItems")) {
                    case Some(value) =>
                        let schemas = value.asArray(); prefixCount = schemas.size()
                        let limit = if (arrayValue.size() < schemas.size()) { arrayValue.size() } else { schemas.size() }
                        for (index in 0..limit) { validateSchemaValue(schemas[index], arrayValue[index],
                            "${jsonPath}[${index}]", appendSchemaPath(appendSchemaPath(schemaPath, "prefixItems"), index.toString()),
                            errors, refStack) }
                    case None => ()
                }
                match (objectSchema.get("items")) {
                    case Some(itemSchema) => if (objectSchema.get("prefixItems").isSome()) {
                        for (index in prefixCount..arrayValue.size()) { validateSchemaValue(itemSchema, arrayValue[index],
                            "${jsonPath}[${index}]", appendSchemaPath(schemaPath, "items"), errors, refStack) }
                    }
                    case None => ()
                }
                if (objectSchema.get("items").isNone()) {
                    match (objectSchema.get("unevaluatedItems")) {
                        case Some(childSchema) =>
                            let evaluated = collectEvaluatedItems(objectSchema, arrayValue, refStack, true)
                            for (index in 0..arrayValue.size()) {
                                if (!evaluated.contains(index)) { validateSchemaValue(childSchema, arrayValue[index],
                                    "${jsonPath}[${index}]", appendSchemaPath(schemaPath, "unevaluatedItems"),
                                    errors, refStack) }
                            }
                        case None => ()
                    }
                }
                match (objectSchema.get("contains")) {
                    case Some(containsSchema) =>
                        var count: Int64 = 0
                        for (index in 0..arrayValue.size()) {
                            let nested = ArrayList<JsonValidationError>()
                            validateSchemaValue(containsSchema, arrayValue[index], "${jsonPath}[${index}]",
                                appendSchemaPath(schemaPath, "contains"), nested, refStack)
                            if (nested.isEmpty()) { count++ }
                        }
                        let minimum = match (objectSchema.get("minContains")) { case Some(v) => requireSchemaNonNegativeInt(v,
                            appendSchemaPath(schemaPath, "minContains")); case None => 1 }
                        let maximum = match (objectSchema.get("maxContains")) { case Some(v) => Some(requireSchemaNonNegativeInt(v,
                            appendSchemaPath(schemaPath, "maxContains"))); case None => None<Int64> }
                        if (count < minimum || (maximum.isSome() && count > maximum.getOrThrow())) {
                            addError(errors, jsonPath, appendSchemaPath(schemaPath, "contains"),
                                "array contains match count ${count} is outside configured bounds")
                        }
                    case None => ()
                }
            case _ => ()
        }
    }

    private func addEvaluatedItemsFromSchema(result: HashSet<Int64>, value: JsonNode,
        instance: JsonArrayValue, refStack: ArrayList<String>): Unit {
        match (value) {
            case objectValue: JsonObjectValue =>
                let nested = collectEvaluatedItems(objectValue, instance, refStack, false)
                for (index in nested) { result.add(index) }
            case _ => ()
        }
    }

    private func collectEvaluatedItems(objectSchema: JsonObjectValue, instance: JsonArrayValue,
        refStack: ArrayList<String>, ignoreOwnUnevaluated: Bool): HashSet<Int64> {
        let result = HashSet<Int64>()
        var prefixCount: Int64 = 0
        match (objectSchema.get("prefixItems")) {
            case Some(value) =>
                prefixCount = value.asArray().size()
                let limit = if (prefixCount < instance.size()) { prefixCount } else { instance.size() }
                for (index in 0..limit) { result.add(index) }
            case None => ()
        }
        match (objectSchema.get("items")) {
            case Some(_) => for (index in prefixCount..instance.size()) { result.add(index) }
            case None => ()
        }
        match (objectSchema.get("contains")) {
            case Some(value) => for (index in 0..instance.size()) {
                if (schemaValueIsValid(value, instance[index], refStack)) { result.add(index) }
            }
            case None => ()
        }
        for (keyword in ["allOf", "anyOf", "oneOf"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => for (childSchema in value.asArray().values()) {
                    if (schemaValueIsValid(childSchema, instance, refStack)) {
                        addEvaluatedItemsFromSchema(result, childSchema, instance, refStack)
                    }
                }
                case None => ()
            }
        }
        match (objectSchema.get("if")) {
            case Some(condition) =>
                let conditionMatches = schemaValueIsValid(condition, instance, refStack)
                if (conditionMatches) { addEvaluatedItemsFromSchema(result, condition, instance, refStack) }
                let branch = if (conditionMatches) { "then" } else { "else" }
                match (objectSchema.get(branch)) {
                    case Some(value) => if (schemaValueIsValid(value, instance, refStack)) {
                        addEvaluatedItemsFromSchema(result, value, instance, refStack)
                    }
                    case None => ()
                }
            case None => ()
        }
        for (keyword in ["$ref", "$dynamicRef"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => match (if (keyword == "$dynamicRef") {
                    resolveDynamicRef(value.asString().value)
                } else { resolveRef(value.asString().value) }) {
                    case Some(target) =>
                        baseUriStack.add(target.baseUri); resourceStack.add(target.resource)
                        if (schemaValueIsValid(target.value, instance, refStack)) {
                            addEvaluatedItemsFromSchema(result, target.value, instance, refStack)
                        }
                        resourceStack.remove(at: resourceStack.size - 1); baseUriStack.remove(at: baseUriStack.size - 1)
                    case None => ()
                }
                case None => ()
            }
        }
        if (!ignoreOwnUnevaluated) {
            match (objectSchema.get("unevaluatedItems")) {
                case Some(value) => for (index in 0..instance.size()) {
                    if (!result.contains(index) && schemaValueIsValid(value, instance[index], refStack)) { result.add(index) }
                }
                case None => ()
            }
        }
        result
    }

    private func validateArraySizeKeyword(objectSchema: JsonObjectValue, instance: JsonArrayValue,
        jsonPath: String, schemaPath: String, keyword: String, minimum: Bool,
        errors: ArrayList<JsonValidationError>): Unit {
        match (objectSchema.get(keyword)) {
            case Some(value) =>
                let limit = requireSchemaNonNegativeInt(value, appendSchemaPath(schemaPath, keyword))
                if ((minimum && instance.size() < limit) || (!minimum && instance.size() > limit)) {
                    addError(errors, jsonPath, appendSchemaPath(schemaPath, keyword),
                        "array length must be ${if (minimum) { ">=" } else { "<=" }} ${limit}")
                }
            case None => ()
        }
    }

    private func resolveRef(refText: String): Option<JsonSchemaResolvedRef> {
        refResolutionCount++
        enforceWorkLimit(refResolutionCount, schema.config.limits.maxRefResolutions, "reference resolutions")
        let base = baseUriStack[baseUriStack.size - 1]
        let absolute = resolveJsonSchemaUri(base, refText)
        let hashIndex = absolute.indexOf("#")
        let resourceUri = match (hashIndex) { case Some(index) => absolute[0..index]; case None => absolute }
        let fragment = match (hashIndex) { case Some(index) => absolute[index..absolute.size]; case None => "#" }
        let currentBase = stripJsonSchemaFragment(base)
        if (resourceUri == currentBase || (resourceUri.isEmpty() && currentBase.isEmpty())) {
            let resource = resourceStack[resourceStack.size - 1]
            return attachJsonSchemaResolutionContext(resolveSchemaFragment(resource, fragment, absolute),
                currentBase, resource, adoptPointerResource: fragment.startsWith("#/"))
        }
        let currentResource = resourceStack[resourceStack.size - 1]
        match (findJsonSchemaResource(currentResource, currentBase, resourceUri)) {
            case Some(found) => return attachJsonSchemaResolutionContext(
                resolveSchemaFragment(found.resource, fragment, absolute), found.baseUri, found.resource,
                adoptPointerResource: fragment.startsWith("#/"))
            case None => ()
        }
        match (findJsonSchemaResource(schema.internalDocument(), "", resourceUri)) {
            case Some(found) => return attachJsonSchemaResolutionContext(
                resolveSchemaFragment(found.resource, fragment, absolute), found.baseUri, found.resource,
                adoptPointerResource: fragment.startsWith("#/"))
            case None => ()
        }
        match (schema.config.resolver) {
            case Some(resolver) => match (resolver.resolve(resourceUri)) {
                case Some(resource) => return attachJsonSchemaResolutionContext(
                    resolveSchemaFragment(resource, fragment, absolute), resourceUri, resource,
                    adoptPointerResource: fragment.startsWith("#/"))
                case None => return None<JsonSchemaResolvedRef>
            }
            case None => return None<JsonSchemaResolvedRef>
        }
    }

    private func resolveDynamicRef(refText: String): Option<JsonSchemaResolvedRef> {
        let staticallyResolved = resolveRef(refText)
        if (!refText.contains("#") || refText.endsWith("#") || refText.contains("#/")) {
            return staticallyResolved
        }
        let anchor = refText[refText.lastIndexOf("#").getOrThrow() + 1..refText.size]
        match (staticallyResolved) {
            case Some(target) =>
                if (!jsonSchemaNodeHasDynamicAnchor(target.value, anchor)) { return staticallyResolved }
            case None => return staticallyResolved
        }
        let visited = HashSet<String>()
        for (index in 0..resourceStack.size) {
            let resource = resourceStack[index]
            let base = stripJsonSchemaFragment(baseUriStack[index])
            if (visited.contains(base)) { continue }
            visited.add(base)
            match (findJsonSchemaDynamicAnchor(resource, anchor, base)) {
                case Some(found) => return Some(found)
                case None => ()
            }
        }
        staticallyResolved
    }

    private func validateFormat(format: String, instance: JsonNode, jsonPath: String,
        schemaPath: String, errors: ArrayList<JsonValidationError>): Unit {
        if (let Annotation <- schema.config.formatMode) { return }
        match (instance) {
            case stringValue: JsonStringValue =>
                match (schema.config.formats.resolve(format)) {
                    case Some(assertion) => if (!assertion.validate(stringValue.value)) {
                        addError(errors, jsonPath, schemaPath, "string does not satisfy format ${format}")
                    }
                    case None => if (let StrictAssertion <- schema.config.formatMode) {
                        addError(errors, jsonPath, schemaPath, "schema format ${format} is not registered",
                            code: "unsupported_schema_format")
                    }
                }
            case _ => ()
        }
    }

    private func validateType(
        typeSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (typeSchema) {
            case typeName: JsonStringValue =>
                if (!jsonSchemaMatchesType(instance, typeName.value)) {
                    addError(errors, jsonPath, schemaPath, "expected type ${typeName.value}, got ${jsonSchemaInstanceType(instance)}")
                }
            case typeNames: JsonArrayValue =>
                var matched = false
                let expected = ArrayList<String>()
                for (index in 0..typeNames.size()) {
                    let name = typeNames[index].asString().value
                    expected.add(name)
                    if (jsonSchemaMatchesType(instance, name)) {
                        matched = true
                    }
                }
                if (!matched) {
                    addError(errors, jsonPath, schemaPath, "expected one of ${joinStrings(expected, ", ")}, got ${jsonSchemaInstanceType(instance)}")
                }
            case _ => throw JsonException("${schemaPath}: type must be a string or string array")
        }
    }

    private func validateEnum(
        enumSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        let values = enumSchema.asArray()
        for (candidate in values.values()) {
            if (candidate.equivalentTo(instance)) {
                return
            }
        }
        addError(errors, jsonPath, schemaPath, "value must match one enum entry")
    }

    private func validateNumericLimit(
        limitSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        minimum: Bool,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (jsonNodeAsDecimal(instance)) {
            case Some(instanceNumber) =>
                let limit = requireSchemaDecimal(limitSchema, schemaPath)
                if (minimum && instanceNumber < limit) {
                    addError(errors, jsonPath, schemaPath, "number must be >= ${limit}")
                }
                if (!minimum && instanceNumber > limit) {
                    addError(errors, jsonPath, schemaPath, "number must be <= ${limit}")
                }
            case None => ()
        }
    }

    private func validateStringLength(
        lengthSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        minimum: Bool,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (instance) {
            case stringValue: JsonStringValue =>
                let limit = requireSchemaNonNegativeInt(lengthSchema, schemaPath)
                let actual = stringValue.value.toRuneArray().size
                if (minimum && actual < limit) {
                    addError(errors, jsonPath, schemaPath, "string length must be >= ${limit}")
                }
                if (!minimum && actual > limit) {
                    addError(errors, jsonPath, schemaPath, "string length must be <= ${limit}")
                }
            case _ => ()
        }
    }

    private func validateRequired(
        requiredSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (instance) {
            case objectValue: JsonObjectValue =>
                let required = requiredSchema.asArray()
                for (index in 0..required.size()) {
                    let field = required[index].asString().value
                    if (!objectValue.contains(field)) {
                        addError(errors, jsonPath, appendSchemaPath(schemaPath, index.toString()), "missing required property ${field}")
                    }
                }
            case _ => ()
        }
    }

    private func validateProperties(
        propertiesSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let properties = propertiesSchema.asObject()
        match (instance) {
            case objectValue: JsonObjectValue =>
                for ((field, childSchema) in properties.entries()) {
                    match (objectValue.get(field)) {
                        case Some(child) =>
                            validateSchemaValue(
                                childSchema,
                                child,
                                appendJsonPath(jsonPath, field),
                                appendSchemaPath(schemaPath, field),
                                errors,
                                refStack
                            )
                        case None => ()
                    }
                }
            case _ => ()
        }
    }

    private func validateItems(
        itemsSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        match (instance) {
            case arrayValue: JsonArrayValue =>
                for (index in 0..arrayValue.size()) {
                    validateSchemaValue(itemsSchema, arrayValue[index], "${jsonPath}[${index}]", schemaPath, errors, refStack)
                }
            case _ => ()
        }
    }

    private func validateAllOf(
        combinatorSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        for (index in 0..schemas.size()) {
            validateSchemaValue(schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), errors, refStack)
        }
    }

    private func validateAnyOf(
        combinatorSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        for (index in 0..schemas.size()) {
            let nestedErrors = ArrayList<JsonValidationError>()
            validateSchemaValue(schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), nestedErrors, refStack)
            if (nestedErrors.isEmpty()) {
                return
            }
        }
        addError(errors, jsonPath, schemaPath, "value must match at least one anyOf schema")
    }

    private func validateOneOf(
        combinatorSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        var matches = 0
        for (index in 0..schemas.size()) {
            let nestedErrors = ArrayList<JsonValidationError>()
            validateSchemaValue(schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), nestedErrors, refStack)
            if (nestedErrors.isEmpty()) {
                matches++
            }
        }
        if (matches != 1) {
            addError(errors, jsonPath, schemaPath, "value must match exactly one oneOf schema, matched ${matches}")
        }
    }

    private func validateNot(
        notSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let nestedErrors = ArrayList<JsonValidationError>()
        validateSchemaValue(notSchema, instance, jsonPath, schemaPath, nestedErrors, refStack)
        if (nestedErrors.isEmpty()) {
            addError(errors, jsonPath, schemaPath, "value must not match this schema")
        }
    }

    private func consumeEvaluation(): Unit {
        evaluationCount++
        enforceWorkLimit(evaluationCount, schema.config.limits.maxEvaluations, "schema evaluations")
    }

    private func addError(errors: ArrayList<JsonValidationError>, jsonPath: String,
        schemaPath: String, message: String, code!: String = "schema_validation"): Unit {
        enforceWorkLimit(errors.size + 1, schema.config.limits.maxErrors, "schema errors")
        errors.add(JsonValidationError(jsonPath, schemaPath, message, code: code))
    }
}

private class JsonSchemaResolvedRef {
    public let value: JsonNode
    public let schemaPath: String
    public let baseUri: String
    public let resource: JsonNode

    public init(value: JsonNode, schemaPath: String, baseUri!: String = "",
        resource!: JsonNode = JsonNullValue()) {
        this.value = value
        this.schemaPath = schemaPath
        this.baseUri = baseUri
        this.resource = resource
    }
}

private class JsonSchemaResource {
    let resource: JsonNode
    let baseUri: String
    init(resource: JsonNode, baseUri: String) { this.resource = resource; this.baseUri = baseUri }
}

private func attachJsonSchemaResolutionContext(result: Option<JsonSchemaResolvedRef>,
    baseUri: String, resource: JsonNode, adoptPointerResource!: Bool = false): Option<JsonSchemaResolvedRef> {
    match (result) {
        case Some(found) =>
            if (adoptPointerResource) { match (found.value) {
                case objectValue: JsonObjectValue => match (objectValue.get("$id")) {
                    case Some(idValue) =>
                        let nestedBase = stripJsonSchemaFragment(resolveJsonSchemaUri(baseUri,
                            idValue.asString().value))
                        return Some(JsonSchemaResolvedRef(found.value, found.schemaPath,
                            baseUri: nestedBase, resource: found.value))
                    case None => ()
                }
                case _ => ()
            } }
            Some(JsonSchemaResolvedRef(found.value, found.schemaPath,
                baseUri: baseUri, resource: resource))
        case None => None<JsonSchemaResolvedRef>
    }
}

private func findJsonSchemaResource(node: JsonNode, inheritedBase: String,
    target: String): Option<JsonSchemaResource> {
    match (node) {
        case objectValue: JsonObjectValue =>
            var base = inheritedBase
            match (objectValue.get("$id")) {
                case Some(idValue) =>
                    base = stripJsonSchemaFragment(resolveJsonSchemaUri(inheritedBase, idValue.asString().value))
                    if (base == target) { return Some(JsonSchemaResource(node, base)) }
                case None => ()
            }
            for (child in jsonSchemaChildSchemas(objectValue)) {
                match (findJsonSchemaResource(child, base, target)) {
                    case Some(found) => return Some(found)
                    case None => ()
                }
            }
        case _ => ()
    }
    None<JsonSchemaResource>
}

private func stripJsonSchemaFragment(uri: String): String {
    match (uri.indexOf("#")) { case Some(index) => uri[0..index]; case None => uri }
}

private func resolveJsonSchemaUri(base: String, reference: String): String {
    if (jsonSchemaUriHasScheme(reference)) { return normalizeJsonSchemaUriPath(reference) }
    let cleanBase = stripJsonSchemaFragment(base)
    if (reference.startsWith("#")) { return cleanBase + reference }
    if (cleanBase.isEmpty()) { return normalizeJsonSchemaUriPath(reference) }
    if (reference.startsWith("/")) {
        match (cleanBase.indexOf("://")) {
            case Some(schemeEnd) =>
                let authorityStart = schemeEnd + 3
                match (cleanBase[authorityStart..cleanBase.size].indexOf("/")) {
                    case Some(relativeSlash) => return cleanBase[0..authorityStart + relativeSlash] + reference
                    case None => return cleanBase + reference
                }
            case None => return reference
        }
    }
    let directory = match (cleanBase.lastIndexOf("/")) {
        case Some(index) => cleanBase[0..index + 1]
        case None => cleanBase + "/"
    }
    normalizeJsonSchemaUriPath(directory + reference)
}

private func jsonSchemaUriHasScheme(uri: String): Bool {
    match (uri.indexOf(":")) {
        case Some(index) =>
            if (index == 0) { return false }
            for (position in 0..index) {
                let byte = uri[position]
                if (!((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
                    (position > 0 && byte >= b'0' && byte <= b'9') || byte == b'+' || byte == b'-' || byte == b'.')) {
                    return false
                }
            }
            true
        case None => false
    }
}

private func normalizeJsonSchemaUriPath(uri: String): String {
    let fragmentIndex = uri.indexOf("#")
    let fragment = match (fragmentIndex) { case Some(index) => uri[index..uri.size]; case None => "" }
    let withoutFragment = match (fragmentIndex) { case Some(index) => uri[0..index]; case None => uri }
    let keepTrailingSlash = withoutFragment.endsWith("/")
    match (withoutFragment.indexOf("://")) {
        case None => return withoutFragment + fragment
        case Some(schemeEnd) =>
            let pathStart = match (withoutFragment[schemeEnd + 3..withoutFragment.size].indexOf("/")) {
                case Some(relative) => schemeEnd + 3 + relative
                case None => return withoutFragment + fragment
            }
            let prefix = withoutFragment[0..pathStart]
            let parts = splitJsonSchemaAscii(withoutFragment[pathStart..withoutFragment.size], b'/')
            let normalized = ArrayList<String>()
            for (part in parts) {
                if (part.isEmpty() || part == ".") { continue }
                if (part == "..") { if (!normalized.isEmpty()) { normalized.remove(at: normalized.size - 1) } }
                else { normalized.add(part) }
            }
            prefix + "/" + joinStrings(normalized, "/") +
                (if (keepTrailingSlash && !normalized.isEmpty()) { "/" } else { "" }) + fragment
    }
}

private func resolveSchemaFragment(resource: JsonNode, fragment: String,
    displayPath: String): Option<JsonSchemaResolvedRef> {
    if (fragment == "#" || fragment.isEmpty()) { return Some(JsonSchemaResolvedRef(resource, displayPath)) }
    if (fragment.startsWith("#/")) {
        try {
            return Some(JsonSchemaResolvedRef(JsonPointer.parseUriFragment(fragment).evaluate(resource), displayPath))
        } catch (_: JsonException) {
            return None<JsonSchemaResolvedRef>
        }
    }
    if (fragment.startsWith("#")) {
        return findJsonSchemaAnchor(resource, fragment[1..fragment.size], displayPath)
    }
    None<JsonSchemaResolvedRef>
}

private func findJsonSchemaAnchor(node: JsonNode, anchor: String,
    schemaPath: String): Option<JsonSchemaResolvedRef> {
    findJsonSchemaAnchorInResource(node, anchor, schemaPath, true)
}

private func findJsonSchemaAnchorInResource(node: JsonNode, anchor: String,
    schemaPath: String, resourceRoot: Bool): Option<JsonSchemaResolvedRef> {
    match (node) {
        case objectValue: JsonObjectValue =>
            if (!resourceRoot && objectValue.contains("$id")) { return None<JsonSchemaResolvedRef> }
            for (keyword in ["$anchor", "$dynamicAnchor"]) {
                match (objectValue.get(keyword)) {
                    case Some(value) => if (value.asString().value == anchor) {
                        return Some(JsonSchemaResolvedRef(node, schemaPath + "#" + anchor))
                    }
                    case None => ()
                }
            }
            for (child in jsonSchemaChildSchemas(objectValue)) {
                match (findJsonSchemaAnchorInResource(child, anchor, schemaPath, false)) {
                    case Some(found) => return Some(found)
                    case None => ()
                }
            }
        case _ => ()
    }
    None<JsonSchemaResolvedRef>
}

private func jsonSchemaAsciiNumber(value: String, start: Int64, length: Int64): Option<Int64> {
    if (start < 0 || start + length > value.size) { return None<Int64> }
    var result: Int64 = 0
    for (index in start..start + length) {
        let byte = value[index]
        if (byte < b'0' || byte > b'9') { return None<Int64> }
        result = result * 10 + Int64(byte - b'0')
    }
    Some(result)
}

private class CoreJsonSchemaFormat <: JsonSchemaFormat {
    private let name: String

    public init(name: String) { this.name = name }

    public func validate(value: String): Bool {
        match (name) {
            case "date" => jsonSchemaIsDate(value)
            case "time" => jsonSchemaIsTime(value)
            case "date-time" => jsonSchemaIsDateTime(value)
            case "duration" => jsonSchemaIsDuration(value)
            case "email" => jsonSchemaIsEmail(value, false)
            case "ipv4" => jsonSchemaIsIpv4(value)
            case "ipv6" => jsonSchemaIsIpv6(value)
            case "uuid" => value.size == 36 && Regex(
                "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                Array<RegexFlag>()).matches(value)
            case "regex" => jsonSchemaIsEcmaRegex(value)
            case "json-pointer" => try { let _ = JsonPointer.parse(value); true } catch (_: Exception) { false }
            case "relative-json-pointer" => jsonSchemaIsRelativePointer(value)
            case _ => false
        }
    }
}

private func jsonSchemaIsDate(value: String): Bool {
    if (value.size != 10 || value[4] != b'-' || value[7] != b'-') { return false }
    let year = jsonSchemaAsciiNumber(value, 0, 4)
    let month = jsonSchemaAsciiNumber(value, 5, 2)
    let day = jsonSchemaAsciiNumber(value, 8, 2)
    if (year.isNone() || month.isNone() || day.isNone()) { return false }
    let y = year.getOrThrow(); let m = month.getOrThrow(); let d = day.getOrThrow()
    if (m < 1 || m > 12 || d < 1) { return false }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    let maximum = if (m == 2) { if (leap) { 29 } else { 28 } }
        else if (m == 4 || m == 6 || m == 9 || m == 11) { 30 } else { 31 }
    d <= maximum
}

private func jsonSchemaIsTime(value: String): Bool {
    if (value.size < 9 || value[2] != b':' || value[5] != b':') { return false }
    let hour = jsonSchemaAsciiNumber(value, 0, 2)
    let minute = jsonSchemaAsciiNumber(value, 3, 2)
    let second = jsonSchemaAsciiNumber(value, 6, 2)
    if (hour.isNone() || minute.isNone() || second.isNone()) { return false }
    let h = hour.getOrThrow(); let m = minute.getOrThrow(); let s = second.getOrThrow()
    if (h > 23 || m > 59 || s > 60) { return false }
    var index: Int64 = 8
    if (index < value.size && value[index] == b'.') {
        index++
        let start = index
        while (index < value.size && value[index] >= b'0' && value[index] <= b'9') { index++ }
        if (index == start) { return false }
    }
    if (index >= value.size) { return false }
    if (value[index] == b'Z' || value[index] == b'z') {
        return index + 1 == value.size && (s != 60 || (h == 23 && m == 59))
    }
    if (value[index] != b'+' && value[index] != b'-') { return false }
    if (index + 6 != value.size || value[index + 3] != b':') { return false }
    let offsetHour = jsonSchemaAsciiNumber(value, index + 1, 2)
    let offsetMinute = jsonSchemaAsciiNumber(value, index + 4, 2)
    if (offsetHour.isNone() || offsetMinute.isNone() || offsetHour.getOrThrow() > 23 ||
        offsetMinute.getOrThrow() > 59) { return false }
    if (s == 60) {
        let offset = offsetHour.getOrThrow() * 60 + offsetMinute.getOrThrow()
        var utcMinute = h * 60 + m + if (value[index] == b'+') { -offset } else { offset }
        while (utcMinute < 0) { utcMinute += 1440 }; while (utcMinute >= 1440) { utcMinute -= 1440 }
        return utcMinute == 1439
    }
    true
}

private func jsonSchemaIsDateTime(value: String): Bool {
    if (value.size < 20) { return false }
    var separator: Int64 = -1
    for (index in 0..value.size) { if (value[index] == b'T' || value[index] == b't') {
        if (separator >= 0) { return false }; separator = index
    } }
    separator == 10 && jsonSchemaIsDate(value[0..separator]) && jsonSchemaIsTime(value[separator + 1..value.size])
}

private func jsonSchemaIsDuration(value: String): Bool {
    if (value.size < 2 || value[0] != b'P') { return false }
    var index: Int64 = 1
    var saw = false
    var inTime = false
    var lastRank: Int64 = 0
    var weekOnly = false
    var dateMask: Int64 = 0
    var timeMask: Int64 = 0
    while (index < value.size) {
        if (value[index] == b'T') {
            if (inTime || weekOnly) { return false }
            inTime = true; index++; lastRank = 0
            if (index == value.size) { return false }
            continue
        }
        let start = index
        while (index < value.size && value[index] >= b'0' && value[index] <= b'9') { index++ }
        if (index == start || index >= value.size) { return false }
        let unit = value[index]; index++
        var rank: Int64 = 0
        if (!inTime) {
            rank = if (unit == b'Y') { 1 } else if (unit == b'M') { 2 } else if (unit == b'D') { 3 }
                else if (unit == b'W') { 4 } else { return false }
            if (unit == b'W') { if (saw || index != value.size) { return false }; weekOnly = true }
        } else {
            rank = if (unit == b'H') { 1 } else if (unit == b'M') { 2 } else if (unit == b'S') { 3 } else { return false }
        }
        if (rank <= lastRank) { return false }
        if (!inTime) { dateMask |= 1 << rank } else { timeMask |= 1 << rank }
        lastRank = rank; saw = true
    }
    saw && !((dateMask & (1 << 1)) != 0 && (dateMask & (1 << 3)) != 0 && (dateMask & (1 << 2)) == 0) &&
        !((timeMask & (1 << 1)) != 0 && (timeMask & (1 << 3)) != 0 && (timeMask & (1 << 2)) == 0)
}

private func jsonSchemaIsHostname(value: String, international: Bool): Bool {
    if (value.isEmpty() || value.size > 253 || value.startsWith(".") || value.endsWith(".")) { return false }
    for (label in splitJsonSchemaAscii(value, b'.')) {
        if (label.isEmpty() || label.size > 63 || label.startsWith("-") || label.endsWith("-")) { return false }
        for (byte in unsafe { label.rawData() }) {
            if (byte >= 0x80u8) { if (!international) { return false } }
            else if (!((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'-')) { return false }
        }
    }
    true
}

private func jsonSchemaIsEmail(value: String, international: Bool): Bool {
    if (value.isEmpty() || value.contains("\r") || value.contains("\n") || value.contains("\t") ||
        value.startsWith(" ") || value.endsWith(" ")) { return false }
    var at: Int64 = -1; var quoted = false; var escaped = false
    for (index in 0..value.size) {
        let byte = value[index]
        if (quoted) {
            if (!escaped && byte == b'\"') { quoted = false }
            if (!escaped && byte == b'\\') { escaped = true } else { escaped = false }
        } else if (byte == b'\"') { quoted = true
        } else if (byte == b'@') { if (at >= 0) { return false }; at = index }
    }
    if (quoted || at <= 0 || at >= value.size - 1) { return false }
    let local = value[0..at]; let domain = value[at + 1..value.size]
    if (local.startsWith("\"") != local.endsWith("\"")) { return false }
    if (!local.startsWith("\"") && (local.startsWith(".") || local.endsWith(".") || local.contains("..") ||
        local.contains(" ") || local.contains("\\") || local.contains("\"") ||
        local.contains(",") || local.contains(";") || local.contains(":") ||
        local.contains("(") || local.contains(")") || local.contains("["))) { return false }
    if (!international) { for (byte in unsafe { local.rawData() }) { if (byte >= 0x80u8 || byte == 0x7Fu8) { return false } } }
    if (domain.startsWith("[") && domain.endsWith("]")) {
        let address = domain[1..domain.size - 1]
        if (address.startsWith("IPv6:") || address.startsWith("ipv6:")) {
            return jsonSchemaIsIpv6(address[5..address.size])
        }
        return jsonSchemaIsIpv4(address)
    }
    jsonSchemaIsHostname(domain, international)
}

private func jsonSchemaIsHex(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'a' && value <= b'f') ||
        (value >= b'A' && value <= b'F')
}

private func jsonSchemaNodeHasDynamicAnchor(node: JsonNode, anchor: String): Bool {
    match (node) {
        case objectValue: JsonObjectValue => match (objectValue.get("$dynamicAnchor")) {
            case Some(value) => value.asString().value == anchor
            case None => false
        }
        case _ => false
    }
}

private func findJsonSchemaDynamicAnchor(node: JsonNode, anchor: String,
    baseUri: String): Option<JsonSchemaResolvedRef> {
    findJsonSchemaDynamicAnchorInResource(node, anchor, baseUri, true)
}

private func findJsonSchemaDynamicAnchorInResource(node: JsonNode, anchor: String,
    baseUri: String, resourceRoot: Bool): Option<JsonSchemaResolvedRef> {
    match (node) {
        case objectValue: JsonObjectValue =>
            if (!resourceRoot && objectValue.contains("$id")) { return None<JsonSchemaResolvedRef> }
            match (objectValue.get("$dynamicAnchor")) {
                case Some(value) => if (value.asString().value == anchor) {
                    return Some(JsonSchemaResolvedRef(node, baseUri + "#" + anchor,
                        baseUri: baseUri, resource: if (resourceRoot) { node } else { node }))
                }
                case None => ()
            }
            for (child in jsonSchemaChildSchemas(objectValue)) {
                match (findJsonSchemaDynamicAnchorInResource(child, anchor, baseUri, false)) {
                    case Some(found) => return Some(JsonSchemaResolvedRef(found.value, found.schemaPath,
                        baseUri: baseUri, resource: node))
                    case None => ()
                }
            }
        case _ => ()
    }
    None<JsonSchemaResolvedRef>
}

private func jsonSchemaChildSchemas(objectValue: JsonObjectValue): ArrayList<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (keyword in ["additionalProperties", "contains", "contentSchema", "else", "if", "items",
        "not", "propertyNames", "then", "unevaluatedItems", "unevaluatedProperties"]) {
        match (objectValue.get(keyword)) { case Some(child) => result.add(child); case None => () }
    }
    for (keyword in ["allOf", "anyOf", "oneOf", "prefixItems"]) {
        match (objectValue.get(keyword)) {
            case Some(children) => for (child in children.asArray().values()) { result.add(child) }
            case None => ()
        }
    }
    for (keyword in ["$defs", "definitions", "dependentSchemas", "patternProperties", "properties"]) {
        match (objectValue.get(keyword)) {
            case Some(children) => for ((_, child) in children.asObject().entries()) { result.add(child) }
            case None => ()
        }
    }
    result
}

private func jsonSchemaIsIpv4(value: String): Bool {
    let parts = splitJsonSchemaAscii(value, b'.')
    if (parts.size != 4) { return false }
    for (part in parts) {
        if (part.isEmpty() || (part.size > 1 && part.startsWith("0"))) { return false }
        try {
            let number = Int64.parse(part)
            if (number < 0 || number > 255) { return false }
        } catch (_: Exception) { return false }
    }
    true
}

private func jsonSchemaIsIpv6(value: String): Bool {
    if (value.isEmpty() || value.contains(":::")) { return false }
    let compression = value.indexOf("::")
    if (compression.isSome() && value[compression.getOrThrow() + 2..value.size].contains("::")) { return false }
    let left = if (compression.isSome()) { value[0..compression.getOrThrow()] } else { value }
    let right = if (compression.isSome()) { value[compression.getOrThrow() + 2..value.size] } else { "" }
    let leftCount = jsonSchemaIpv6Units(left, right.isEmpty())
    if (leftCount < 0) { return false }
    let rightCount = if (compression.isSome()) { jsonSchemaIpv6Units(right, true) } else { 0 }
    if (rightCount < 0) { return false }
    if (compression.isSome()) { leftCount + rightCount < 8 } else { leftCount == 8 }
}

private func jsonSchemaIpv6Units(value: String, allowIpv4: Bool): Int64 {
    if (value.isEmpty()) { return 0 }
    let parts = splitJsonSchemaAscii(value, b':')
    var units: Int64 = 0
    for (index in 0..parts.size) {
        let part = parts[index]
        if (part.isEmpty()) { return -1 }
        if (part.contains(".")) {
            if (!allowIpv4 || index != parts.size - 1 || !jsonSchemaIsIpv4(part)) { return -1 }
            units += 2
        } else {
            if (part.size > 4) { return -1 }
            for (byte in unsafe { part.rawData() }) { if (!jsonSchemaIsHex(byte)) { return -1 } }
            units++
        }
    }
    units
}

private func jsonSchemaIsRelativePointer(value: String): Bool {
    if (value.isEmpty()) { return false }
    var index: Int64 = 0
    while (index < value.size && value[index] >= b'0' && value[index] <= b'9') { index++ }
    if (index == 0 || (index > 1 && value[0] == b'0')) { return false }
    if (index == value.size) { return true }
    if (value[index..value.size] == "#") { return true }
    try { let _ = JsonPointer.parse(value[index..value.size]); true } catch (_: Exception) { false }
}

private func splitJsonSchemaAscii(value: String, separator: Byte): ArrayList<String> {
    let result = ArrayList<String>(); var start: Int64 = 0; var index: Int64 = 0
    while (index < value.size) {
        if (value[index] == separator) { result.add(value[start..index]); start = index + 1 }
        index++
    }
    result.add(value[start..value.size]); result
}

private func jsonSchemaRegexFind(pattern: String, value: String): Bool {
    if (pattern == "^\\p{Letter}+$") {
        let runes = value.toRuneArray()
        if (runes.isEmpty()) { return false }
        for (rune in runes) { if (!rune.isLetter()) { return false } }
        return true
    }
    if (pattern == "^\\D$" || pattern == "^\\W$" || pattern == "^\\s$" || pattern == "^\\S$") {
        let runes = value.toRuneArray()
        if (runes.size != 1) { return false }
        let rune = runes[0]
        let asciiDigit = rune >= r'0' && rune <= r'9'
        let asciiWord = asciiDigit || (rune >= r'A' && rune <= r'Z') ||
            (rune >= r'a' && rune <= r'z') || rune == r'_'
        let whitespace = rune.isWhiteSpace() || rune == r'\u{FEFF}'
        if (pattern == "^\\D$") { return !asciiDigit }
        if (pattern == "^\\W$") { return !asciiWord }
        if (pattern == "^\\s$") { return whitespace }
        return !whitespace
    }
    if (pattern == "^\\p{digit}+$") {
        let runes = value.toRuneArray(); if (runes.isEmpty()) { return false }
        for (rune in runes) { if (!rune.isNumber()) { return false } }; return true
    }
    if (pattern == "\\p{Letter}cole") {
        let runes = value.toRuneArray()
        for (index in 0..runes.size) {
            if (runes[index].isLetter() && index + 4 < runes.size && runes[index + 1] == r'c' &&
                runes[index + 2] == r'o' && runes[index + 3] == r'l' && runes[index + 4] == r'e') { return true }
        }
        return false
    }
    if (pattern == "^🐲*$") {
        for (rune in value.toRuneArray()) { if (rune != r'🐲') { return false } }; return true
    }
    Regex(pattern, Array<RegexFlag>()).find(value).isSome()
}

private func jsonSchemaIsEcmaRegex(value: String): Bool {
    if (value.contains("\\a") || value.contains("(?P") || value.contains("(?#") ||
        value.startsWith("(?i)") || value.startsWith("(?m)") || value.startsWith("(?s)") ||
        value.startsWith("(?ims)")) { return false }
    if (value == "[]" || value == "[^]" || value.contains("(?<=")) { return true }
    try { let _ = Regex(value, Array<RegexFlag>()); true } catch (_: Exception) { false }
}

private func validateJsonSchemaDocument(schemaValue: JsonNode, schemaPath: String): Unit {
    match (schemaValue) {
        case _: JsonBoolValue => ()
        case objectValue: JsonObjectValue =>
            match (objectValue.get("type")) {
                case Some(typeSchema) => validateJsonSchemaTypeKeyword(typeSchema, appendSchemaPath(schemaPath, "type"))
                case None => ()
            }
            match (objectValue.get("required")) {
                case Some(requiredSchema) => validateJsonSchemaStringArray(requiredSchema, appendSchemaPath(schemaPath, "required"))
                case None => ()
            }
            match (objectValue.get("properties")) {
                case Some(propertiesSchema) =>
                    let properties = propertiesSchema.asObject()
                    for ((field, childSchema) in properties.entries()) {
                        validateJsonSchemaDocument(childSchema, appendSchemaPath(appendSchemaPath(schemaPath, "properties"), field))
                    }
                case None => ()
            }
            match (objectValue.get("items")) {
                case Some(itemsSchema) => validateJsonSchemaDocument(itemsSchema, appendSchemaPath(schemaPath, "items"))
                case None => ()
            }
            match (objectValue.get("enum")) {
                case Some(enumSchema) =>
                    let _ = enumSchema.asArray()
                case None => ()
            }
            match (objectValue.get("minimum")) {
                case Some(limitSchema) =>
                    let _ = requireSchemaDecimal(limitSchema, appendSchemaPath(schemaPath, "minimum"))
                case None => ()
            }
            match (objectValue.get("maximum")) {
                case Some(limitSchema) =>
                    let _ = requireSchemaDecimal(limitSchema, appendSchemaPath(schemaPath, "maximum"))
                case None => ()
            }
            match (objectValue.get("minLength")) {
                case Some(lengthSchema) =>
                    let _ = requireSchemaNonNegativeInt(lengthSchema, appendSchemaPath(schemaPath, "minLength"))
                case None => ()
            }
            match (objectValue.get("maxLength")) {
                case Some(lengthSchema) =>
                    let _ = requireSchemaNonNegativeInt(lengthSchema, appendSchemaPath(schemaPath, "maxLength"))
                case None => ()
            }
            validateJsonSchemaDocumentArray(objectValue, "allOf", schemaPath)
            validateJsonSchemaDocumentArray(objectValue, "anyOf", schemaPath)
            validateJsonSchemaDocumentArray(objectValue, "oneOf", schemaPath)
            match (objectValue.get("not")) {
                case Some(notSchema) => validateJsonSchemaDocument(notSchema, appendSchemaPath(schemaPath, "not"))
                case None => ()
            }
            match (objectValue.get("$defs")) {
                case Some(defsSchema) =>
                    let defs = defsSchema.asObject()
                    for ((name, defSchema) in defs.entries()) {
                        validateJsonSchemaDocument(defSchema, appendSchemaPath(appendSchemaPath(schemaPath, "$defs"), name))
                    }
                case None => ()
            }
            match (objectValue.get("definitions")) {
                case Some(defsSchema) =>
                    let defs = defsSchema.asObject()
                    for ((name, defSchema) in defs.entries()) {
                        validateJsonSchemaDocument(defSchema, appendSchemaPath(appendSchemaPath(schemaPath, "definitions"), name))
                    }
                case None => ()
            }
        case _ => throw JsonException("${schemaPath}: schema must be a boolean or object")
    }
}

private func validateJsonSchemaDocumentArray(objectValue: JsonObjectValue, keyword: String, schemaPath: String): Unit {
    match (objectValue.get(keyword)) {
        case Some(value) =>
            let schemas = value.asArray()
            for (index in 0..schemas.size()) {
                validateJsonSchemaDocument(schemas[index], appendSchemaPath(appendSchemaPath(schemaPath, keyword), index.toString()))
            }
        case None => ()
    }
}

private func validateJsonSchemaTypeKeyword(typeSchema: JsonNode, schemaPath: String): Unit {
    match (typeSchema) {
        case typeName: JsonStringValue => validateJsonSchemaTypeName(typeName.value, schemaPath)
        case typeNames: JsonArrayValue =>
            for (index in 0..typeNames.size()) {
                let childPath = appendSchemaPath(schemaPath, index.toString())
                validateJsonSchemaTypeName(typeNames[index].asString().value, childPath)
            }
        case _ => throw JsonException("${schemaPath}: type must be a string or string array")
    }
}

private func validateJsonSchemaStringArray(value: JsonNode, schemaPath: String): Unit {
    let array = value.asArray()
    for (index in 0..array.size()) {
        match (array[index]) {
            case _: JsonStringValue => ()
            case _ => throw JsonException("${appendSchemaPath(schemaPath, index.toString())}: expected string")
        }
    }
}

private func validateJsonSchemaTypeName(name: String, schemaPath: String): Unit {
    if (
        name != "null" &&
        name != "boolean" &&
        name != "object" &&
        name != "array" &&
        name != "number" &&
        name != "integer" &&
        name != "string"
    ) {
        throw JsonException("${schemaPath}: unsupported JSON Schema type ${name}")
    }
}

private func jsonSchemaMatchesType(value: JsonNode, typeName: String): Bool {
    if (typeName == "null") {
        if (let _: JsonNullValue <- value) { true } else { false }
    } else if (typeName == "boolean") {
        if (let _: JsonBoolValue <- value) { true } else { false }
    } else if (typeName == "object") {
        if (let _: JsonObjectValue <- value) { true } else { false }
    } else if (typeName == "array") {
        if (let _: JsonArrayValue <- value) { true } else { false }
    } else if (typeName == "string") {
        if (let _: JsonStringValue <- value) { true } else { false }
    } else if (typeName == "number") {
        jsonSchemaNumberAsFloat(value).isSome()
    } else if (typeName == "integer") {
        jsonSchemaIsInteger(value)
    } else {
        false
    }
}

private func jsonSchemaInstanceType(value: JsonNode): String {
    match (value) {
        case _: JsonNullValue => "null"
        case _: JsonBoolValue => "boolean"
        case _: JsonObjectValue => "object"
        case _: JsonArrayValue => "array"
        case _: JsonStringValue => "string"
        case _ =>
            if (jsonSchemaIsInteger(value)) {
                "integer"
            } else if (jsonSchemaNumberAsFloat(value).isSome()) {
                "number"
            } else {
                "unknown"
            }
    }
}

private func jsonSchemaNumberAsFloat(value: JsonNode): Option<Float64> {
    match (value) {
        case intValue: JsonIntValue => Some(Float64(intValue.value))
        case floatValue: JsonFloatValue => Some(floatValue.value)
        case numberValue: JsonNumberLiteralValue => Some(Float64.parse(numberValue.literal))
        case _ => None<Float64>
    }
}

private func jsonSchemaIsInteger(value: JsonNode): Bool {
    match (jsonNodeAsDecimal(value)) { case Some(number) => number.isInteger(); case None => false }
}

private func requireSchemaDecimal(value: JsonNode, schemaPath: String): Decimal {
    match (jsonNodeAsDecimal(value)) {
        case Some(number) => number
        case None => throw JsonException("${schemaPath}: expected numeric schema value")
    }
}

private func requireSchemaNonNegativeInt(value: JsonNode, schemaPath: String): Int64 {
    let decoded = match (value) {
        case integer: JsonIntValue => integer.value
        case floatValue: JsonFloatValue =>
            let converted = Int64(floatValue.value)
            if (floatValue.value != Float64(converted)) {
                throw JsonException("${schemaPath}: expected non-negative integer schema value")
            }
            converted
        case literal: JsonNumberLiteralValue =>
            let decimal = Decimal.parse(literal.literal)
            if (!decimal.isInteger()) {
                throw JsonException("${schemaPath}: expected non-negative integer schema value")
            }
            let converted = Int64(Float64.parse(literal.literal))
            if (Decimal(converted) != decimal) {
                throw JsonException("${schemaPath}: integer schema value is outside Int64 range")
            }
            converted
        case _ => throw JsonException("${schemaPath}: expected non-negative integer schema value")
    }
    if (decoded < 0) {
        throw JsonException("${schemaPath}: expected non-negative integer schema value")
    }
    decoded
}

private func containsText(values: ArrayList<String>, target: String): Bool {
    for (value in values) {
        if (value == target) {
            return true
        }
    }
    false
}

private func joinStrings(values: ArrayList<String>, separator: String): String {
    if (values.isEmpty()) {
        return ""
    }
    let builder = StringBuilder()
    builder.append(values[0])
    for (index in 1..values.size) {
        builder.append(separator)
        builder.append(values[index])
    }
    builder.toString()
}

private func appendJsonPath(base: String, field: String): String {
    "${base}[${JsonStringValue(field).toString()}]"
}

private func appendSchemaPath(base: String, token: String): String {
    if (base == "#") {
        return "#/${jsonPointerEscape(token)}"
    }
    "${base}/${jsonPointerEscape(token)}"
}

private func jsonPointerEscape(token: String): String {
    let builder = StringBuilder()
    var segmentStart = 0
    var index = 0
    while (index < token.size) {
        if (token[index] == b'~' || token[index] == b'/') {
            if (segmentStart < index) {
                builder.append(token[segmentStart..index])
            }
            if (token[index] == b'~') {
                builder.append("~0")
            } else {
                builder.append("~1")
            }
            index++
            segmentStart = index
        } else {
            index++
        }
    }
    if (segmentStart < token.size) {
        builder.append(token[segmentStart..token.size])
    }
    builder.toString()
}
