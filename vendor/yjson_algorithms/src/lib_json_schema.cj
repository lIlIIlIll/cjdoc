package yjson_algorithms

import yjson.*

import std.collection.*
import std.convert.Parsable
import std.math.numeric.*

public class JsonSchemaViolation {
    public let instancePath: String
    public let schemaPath: String
    public let code: String
    public let message: String

    public init(instancePath: String, schemaPath: String, message: String,
        code!: String = "schema_validation") {
        this.instancePath = instancePath
        this.schemaPath = schemaPath
        this.code = code
        this.message = message
    }
}

/**
 * Immutable result of one JSON Schema validation.
 */
public class JsonSchemaResult {
    private let items: Array<JsonSchemaViolation>

    init(items: Array<JsonSchemaViolation>) { this.items = items }

    public prop valid: Bool { get() { items.isEmpty() } }
    public prop size: Int64 { get() { items.size } }
    public func isEmpty(): Bool { items.isEmpty() }
    public operator func [](index: Int64): JsonSchemaViolation { items[index] }

    public func violations(): Array<JsonSchemaViolation> {
        let copy = ArrayList<JsonSchemaViolation>(items.size)
        for (item in items) { copy.add(item) }
        copy.toArray()
    }
}

private class JsonSchemaMismatchSignal <: Exception {}

/**
 * A named JSON Schema format assertion.
 *
 * Implementations must be immutable or synchronize their own state: a single
 * validator instance can be shared across threads, and the same format
 * instance may be invoked concurrently without yjson-side locking.
 */
public interface JsonSchemaFormat {
    func validate(value: String): Bool
}

/**
 * Installs a coherent group of format assertions into a registry.
 */
public interface JsonSchemaFormatProvider {
    func installInto(registry: JsonSchemaFormatRegistry): Unit
}

/**
 * Explicit format registry used by Assertion mode.
 */
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
    /**
     * Resolves an absolute or application-defined schema resource URI.
     * Implementations may load from memory, disk, or an application cache;
     * yjson itself never performs network I/O.
     */
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

    public func register(uri: String, schemaText: String): Unit { register(uri, JsonNode.parse(schemaText)) }

    public func resolve(uri: String): Option<JsonNode> {
        match (resources.get(uri)) {
            case Some(value) => Some(value.deepCopy())
            case None => None<JsonNode>
        }
    }
}

public enum JsonSchemaFormatMode { Annotation | Assertion }

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
    private let compiledResources: HashMap<String, JsonNode>
    private let compiledRegexes: HashMap<String, LinearRegex>
    public let draft: String
    public let config: JsonSchemaConfig
    let validationVocabulary: Bool

    /**
     * Returns a detached copy so callers cannot mutate the compiled schema.
     */
    public prop document: JsonNode {
        get() { documentValue.deepCopy() }
    }

    public init(document: JsonValueView, draft!: String = "https://json-schema.org/draft/2020-12/schema",
        config!: JsonSchemaConfig = JsonSchemaConfig.defaults) {
        if (draft != "https://json-schema.org/draft/2020-12/schema" &&
            draft != "https://json-schema.org/draft/2020-12/schema#") {
            throw JsonException("Unsupported JSON Schema dialect ${draft}",
                code: "unsupported_schema_dialect")
        }
        let frozenDocument = document.materialize()
        let resources = compileJsonSchemaResourceGraph(frozenDocument,
            config.resolver, config.limits)
        let regexes = compileJsonSchemaRegexes(frozenDocument, resources, config.limits)
        this.documentValue = frozenDocument
        this.compiledResources = resources
        this.compiledRegexes = regexes
        this.draft = draft
        // Validation retains no resolver reference. All external resources are
        // detached above, so later registry mutation or I/O cannot affect it.
        this.config = JsonSchemaConfig(resolver: None<UriResolver>, formatMode: config.formatMode,
            formats: config.formats.frozenCopy(), limits: config.limits)
        var usesValidationVocabulary = true
        match (frozenDocument) {
            case objectValue: JsonObject => match (objectValue.get("$schema")) {
                case Some(value) =>
                    let declared = value.asString()
                    if (declared != "https://json-schema.org/draft/2020-12/schema" &&
                        declared != "https://json-schema.org/draft/2020-12/schema#") {
                        match (compiledResources.get(stripJsonSchemaFragment(declared))) {
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
                    }
                case None => ()
            }
            case _ => ()
        }
        this.validationVocabulary = usesValidationVocabulary
        validateJsonSchemaDocument(frozenDocument, "#")
    }

    public static func parse(text: String, config!: JsonSchemaConfig = JsonSchemaConfig.defaults): JsonSchema {
        JsonSchema(JsonNode.parse(text), config: config)
    }

    public static func fromValue(value: JsonValueView,
        config!: JsonSchemaConfig = JsonSchemaConfig.defaults): JsonSchema {
        JsonSchema(value, config: config)
    }

    public func validator(): JsonSchemaValidator {
        JsonSchemaValidator(this)
    }

    public func validate(instance: JsonValueView): JsonSchemaResult {
        validator().validate(instance)
    }

    public func validate(document: JsonDocument): JsonSchemaResult {
        validator().validate(document.root())
    }

    public func isValid(instance: JsonValueView): Bool { validator().isValid(instance) }

    public func isValid(document: JsonDocument): Bool { validator().isValid(document.root()) }

    func internalDocument(): JsonNode { documentValue }

    func compiledResource(uri: String): Option<JsonNode> {
        compiledResources.get(uri)
    }

    func compiledRegex(pattern: String): Option<LinearRegex> { compiledRegexes.get(pattern) }
}

private class ValidationContext {
    let baseUriStack = ArrayList<String>()
    let resourceStack = ArrayList<JsonNode>()
    var evaluationCount: Int64 = 0
    var refResolutionCount: Int64 = 0
    var validationDepth: Int64 = 0
    var stopAtFirst: Bool = false
    var probeDepth: Int64 = 0
    let regexBudget: LinearRegexBudget

    init(limits: JsonSchemaLimits) {
        this.regexBudget = LinearRegexBudget(limits.maxRegexSteps, "JSON Schema regex steps")
    }
}

public class JsonSchemaValidator {
    private let schema: JsonSchema

    public init(schema: JsonSchema) {
        this.schema = schema
    }

    public func validate(instance: JsonValueView): JsonSchemaResult {
        JsonSchemaResult(runValidation(instance, false).toArray())
    }

    private func runValidation(instance: JsonValueView, firstOnly: Bool): ArrayList<JsonSchemaViolation> {
        let context = ValidationContext(schema.config.limits)
        let errors = ArrayList<JsonSchemaViolation>()
        context.stopAtFirst = firstOnly
        context.baseUriStack.add("")
        let document = schema.internalDocument()
        context.resourceStack.add(document)
        try {
            validateSchemaValue(context, document, instance, "", "#", errors, ArrayList<String>())
        } finally {
            context.baseUriStack.clear()
            context.resourceStack.clear()
        }
        errors
    }

    public func isValid(instance: JsonValueView): Bool {
        try {
            let _ = runValidation(instance, true)
            true
        } catch (_: JsonSchemaMismatchSignal) {
            false
        }
    }

    public func validate(document: JsonDocument): JsonSchemaResult {
        validate(document.root())
    }

    public func isValid(document: JsonDocument): Bool { isValid(document.root()) }
    private func validateSchemaValue(context: ValidationContext,
        schemaValue: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        consumeEvaluation(context)
        enforceWorkLimit(context.validationDepth, schema.config.limits.maxDepth, "schema depth")
        context.validationDepth++
        try {
            match (schemaValue.kind()) {
                case JsonKind.Boolean =>
                    if (!schemaValue.asBool()) {
                        addError(context, errors, jsonPath, schemaPath, "boolean schema false rejects every value")
                    }
                    return
                case JsonKind.Object =>
                    validateObjectSchema(context, schemaValue.asObject(), instance, jsonPath, schemaPath, errors, refStack)
                case _ =>
                    addError(context, errors, jsonPath, schemaPath, "schema must be a boolean or object")
            }
        } finally {
            context.validationDepth--
        }
    }

    private func validateObjectSchema(context: ValidationContext,
        objectSchema: JsonObject,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        let inheritedBase = context.baseUriStack[context.baseUriStack.size - 1]
        let inheritedResource = context.resourceStack[context.resourceStack.size - 1]
        var effectiveBase = inheritedBase
        var effectiveResource = inheritedResource
        match (objectSchema.get("$id")) {
            case Some(idValue) =>
                let idText = idValue.asString()
                let idWithoutFragment = stripJsonSchemaFragment(idText)
                effectiveBase = if (objectSchema.equivalentTo(inheritedResource) &&
                    !idWithoutFragment.isEmpty() && stripJsonSchemaFragment(inheritedBase).endsWith(idWithoutFragment)) {
                    inheritedBase
                } else { resolveJsonSchemaUri(inheritedBase, idText) }
                if (!idValue.asString().contains("#")) { effectiveResource = objectSchema }
            case None => ()
        }
        context.baseUriStack.add(effectiveBase)
        context.resourceStack.add(effectiveResource)
        match (objectSchema.get("$ref")) {
            case Some(refValue) =>
                let refText = refValue.asString()
                let refKey = refText + "|" + jsonPath
                if (containsText(refStack, refKey)) {
                    addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "$ref"), "cyclic $ref ${refText}")
                } else if (refText == "https://json-schema.org/draft/2020-12/schema" ||
                    refText == "https://json-schema.org/draft/2020-12/schema#") {
                    try { validateJsonSchemaDocument(instance.materialize(), "#") }
                    catch (error: Exception) { addError(context, errors, jsonPath,
                        appendSchemaPath(schemaPath, "$ref"), error.message) }
                } else {
                    refStack.add(refKey)
                    match (resolveRef(context, refText)) {
                        case Some(target) =>
                            context.baseUriStack.add(target.baseUri)
                            context.resourceStack.add(target.resource)
                            validateSchemaValue(context, target.value, instance, jsonPath, target.schemaPath, errors, refStack)
                            context.baseUriStack.remove(at: context.baseUriStack.size - 1)
                            context.resourceStack.remove(at: context.resourceStack.size - 1)
                        case None =>
                            let description = if (refText.startsWith("#")) { "unresolved local $ref" } else { "unresolved $ref" }
                            addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "$ref"), "${description} ${refText}")
                    }
                    refStack.remove(at: refStack.size - 1)
                }
            case None => ()
        }

        match (objectSchema.get("$dynamicRef")) {
            case Some(refValue) =>
                let refText = refValue.asString()
                let refKey = "$dynamicRef:" + refText + "|" + jsonPath
                if (!containsText(refStack, refKey)) {
                    refStack.add(refKey)
                    match (resolveDynamicRef(context, refText)) {
                        case Some(target) =>
                            context.baseUriStack.add(target.baseUri)
                            context.resourceStack.add(target.resource)
                            validateSchemaValue(context, target.value, instance, jsonPath, target.schemaPath, errors, refStack)
                            context.baseUriStack.remove(at: context.baseUriStack.size - 1)
                            context.resourceStack.remove(at: context.resourceStack.size - 1)
                        case None => addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "$dynamicRef"),
                            "unresolved $dynamicRef ${refText}")
                    }
                    refStack.remove(at: refStack.size - 1)
                }
            case None => ()
        }

        if (schema.validationVocabulary) { match (objectSchema.get("type")) {
            case Some(typeSchema) => validateType(context, typeSchema, instance, jsonPath, appendSchemaPath(schemaPath, "type"), errors)
            case None => ()
        } }

        match (objectSchema.get("enum")) {
            case Some(enumSchema) => validateEnum(context, enumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "enum"), errors)
            case None => ()
        }

        match (objectSchema.get("const")) {
            case Some(constSchema) =>
                if (!jsonNodesEquivalent(constSchema, instance)) {
                    addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "const"), "value must equal const")
                }
            case None => ()
        }

        if (schema.validationVocabulary) { match (objectSchema.get("minimum")) {
            case Some(minimumSchema) => validateNumericLimit(context, minimumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "minimum"), true, errors)
            case None => ()
        } }

        if (schema.validationVocabulary) { match (objectSchema.get("maximum")) {
            case Some(maximumSchema) => validateNumericLimit(context, maximumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "maximum"), false, errors)
            case None => ()
        } }

        if (schema.validationVocabulary) {
            validateExtendedNumericKeywords(context, objectSchema, instance, jsonPath, schemaPath, errors)
        }

        match (objectSchema.get("minLength")) {
            case Some(minLengthSchema) => validateStringLength(context, minLengthSchema, instance, jsonPath, appendSchemaPath(schemaPath, "minLength"), true, errors)
            case None => ()
        }

        match (objectSchema.get("maxLength")) {
            case Some(maxLengthSchema) => validateStringLength(context, maxLengthSchema, instance, jsonPath, appendSchemaPath(schemaPath, "maxLength"), false, errors)
            case None => ()
        }

        validateStringKeywords(context, objectSchema, instance, jsonPath, schemaPath, errors)

        match (objectSchema.get("format")) {
            case Some(formatValue) => validateFormat(context, formatValue.asString(), instance, jsonPath,
                appendSchemaPath(schemaPath, "format"), errors)
            case None => ()
        }

        match (objectSchema.get("required")) {
            case Some(requiredSchema) => validateRequired(context, requiredSchema, instance, jsonPath, appendSchemaPath(schemaPath, "required"), errors)
            case None => ()
        }

        match (objectSchema.get("properties")) {
            case Some(propertiesSchema) => validateProperties(context, propertiesSchema, instance, jsonPath, appendSchemaPath(schemaPath, "properties"), errors, refStack)
            case None => ()
        }

        validateObjectKeywords(context, objectSchema, instance, jsonPath, schemaPath, errors, refStack)

        if (objectSchema.get("prefixItems").isNone()) {
            match (objectSchema.get("items")) {
                case Some(itemsSchema) => validateItems(context, itemsSchema, instance, jsonPath, appendSchemaPath(schemaPath, "items"), errors, refStack)
                case None => ()
            }
        }

        validateArrayKeywords(context, objectSchema, instance, jsonPath, schemaPath, errors, refStack)

        match (objectSchema.get("allOf")) {
            case Some(combinatorSchema) => validateAllOf(context, combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "allOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("anyOf")) {
            case Some(combinatorSchema) => validateAnyOf(context, combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "anyOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("oneOf")) {
            case Some(combinatorSchema) => validateOneOf(context, combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "oneOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("not")) {
            case Some(notSchema) => validateNot(context, notSchema, instance, jsonPath, appendSchemaPath(schemaPath, "not"), errors, refStack)
            case None => ()
        }


        match (objectSchema.get("if")) {
            case Some(ifSchema) =>
                let conditionMatches = probeSchemaValue(context, ifSchema, instance, jsonPath,
                    appendSchemaPath(schemaPath, "if"), refStack)
                let branch = if (conditionMatches) { "then" } else { "else" }
                match (objectSchema.get(branch)) {
                    case Some(branchSchema) => validateSchemaValue(context, branchSchema, instance, jsonPath,
                        appendSchemaPath(schemaPath, branch), errors, refStack)
                    case None => ()
                }
            case None => ()
        }
        context.baseUriStack.remove(at: context.baseUriStack.size - 1)
        context.resourceStack.remove(at: context.resourceStack.size - 1)
    }

    private func validateExtendedNumericKeywords(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonSchemaViolation>): Unit {
        match (jsonNodeAsDecimal(instance)) {
            case Some(number) =>
                match (objectSchema.get("exclusiveMinimum")) {
                    case Some(limitValue) =>
                        let limit = requireSchemaDecimal(limitValue, appendSchemaPath(schemaPath, "exclusiveMinimum"))
                        if (number <= limit) { addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "exclusiveMinimum"),
                            "number must be > ${limit}") }
                    case None => ()
                }
                match (objectSchema.get("exclusiveMaximum")) {
                    case Some(limitValue) =>
                        let limit = requireSchemaDecimal(limitValue, appendSchemaPath(schemaPath, "exclusiveMaximum"))
                        if (number >= limit) { addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "exclusiveMaximum"),
                            "number must be < ${limit}") }
                    case None => ()
                }
                match (objectSchema.get("multipleOf")) {
                    case Some(divisorValue) =>
                        let divisor = requireSchemaDecimal(divisorValue, appendSchemaPath(schemaPath, "multipleOf"))
                        if (divisor <= Decimal(0)) { throw JsonException("${appendSchemaPath(schemaPath, "multipleOf")}: expected a positive number") }
                        let (_, remainder) = number.divAndMod(divisor)
                        if (remainder != Decimal(0)) { addError(context, errors, jsonPath,
                            appendSchemaPath(schemaPath, "multipleOf"), "number must be a multiple of ${divisor}") }
                    case None => ()
                }
            case None => ()
        }
    }

    private func validateStringKeywords(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonSchemaViolation>): Unit {
        if (instance.kind() == JsonKind.String) {
            match (objectSchema.get("pattern")) {
                case Some(patternValue) =>
                    let pattern = patternValue.asString()
                    if (!regexFind(context, pattern, instance.asString())) {
                        addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "pattern"),
                            "string must match pattern ${pattern}")
                    }
                case None => ()
            }
        }
    }

    private func schemaObjectContains(value: JsonValueView, name: String): Bool {
        value.member(name).isSome()
    }

    private func validateObjectKeywords(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>): Unit {
        if (instance.kind() != JsonKind.Object) { return }
        let objectValue = instance
        validateObjectSizeKeyword(context, objectSchema, objectValue, jsonPath, schemaPath, "minProperties", true, errors)
        validateObjectSizeKeyword(context, objectSchema, objectValue, jsonPath, schemaPath, "maxProperties", false, errors)
        let matched = HashSet<String>()
        match (objectSchema.get("properties")) {
            case Some(value) =>
                let properties = value.asObject()
                for (index in 0..properties.size()) {
                    let name = properties.nameAt(index)
                    if (schemaObjectContains(objectValue, name)) { matched.add(name) }
                }
            case None => ()
        }
        match (objectSchema.get("patternProperties")) {
            case Some(value) =>
                let patterns = value.asObject()
                for (patternIndex in 0..patterns.size()) {
                    let pattern = patterns.nameAt(patternIndex)
                    let childSchema = patterns.valueAt(patternIndex)
                    for (memberIndex in 0..objectValue.size()) {
                        let name = objectValue.memberName(memberIndex)
                        let child = objectValue.memberValue(memberIndex)
                            if (regexFind(context, pattern, name)) {
                                matched.add(name)
                                validateSchemaValue(context, childSchema, child, appendJsonPath(jsonPath, name),
                                    appendSchemaPath(appendSchemaPath(schemaPath, "patternProperties"), pattern), errors, refStack)
                            }
                    }
                }
            case None => ()
        }
        match (objectSchema.get("propertyNames")) {
            case Some(nameSchema) => for (index in 0..objectValue.size()) {
                        let name = objectValue.memberName(index)
                        validateSchemaValue(context, nameSchema, JsonNode.string(name), appendJsonPath(jsonPath, name),
                            appendSchemaPath(schemaPath, "propertyNames"), errors, refStack)
                    }
            case None => ()
        }
        match (objectSchema.get("dependentRequired")) {
            case Some(value) =>
                let dependencies = value.asObject()
                for (dependencyIndex in 0..dependencies.size()) {
                    let trigger = dependencies.nameAt(dependencyIndex)
                    let requiredValue = dependencies.valueAt(dependencyIndex)
                        if (schemaObjectContains(objectValue, trigger)) {
                            for (index in 0..requiredValue.asArray().size()) {
                                let requiredName = requiredValue.asArray()[index].asString()
                                if (!schemaObjectContains(objectValue, requiredName)) { addError(context, errors, jsonPath,
                                    appendSchemaPath(appendSchemaPath(schemaPath, "dependentRequired"), trigger),
                                    "property ${trigger} requires property ${requiredName}") }
                            }
                        }
                }
            case None => ()
        }
        match (objectSchema.get("dependentSchemas")) {
            case Some(value) =>
                let dependencies = value.asObject()
                for (index in 0..dependencies.size()) {
                    let trigger = dependencies.nameAt(index)
                    let childSchema = dependencies.valueAt(index)
                        if (schemaObjectContains(objectValue, trigger)) { validateSchemaValue(context, childSchema, instance, jsonPath,
                            appendSchemaPath(appendSchemaPath(schemaPath, "dependentSchemas"), trigger), errors, refStack) }
                }
            case None => ()
        }
        let extraSchema = match (objectSchema.get("additionalProperties")) {
            case Some(value) => Some(value)
            case None => None<JsonNode>
        }
        match (extraSchema) {
            case Some(childSchema) => for (index in 0..objectValue.size()) {
                        let name = objectValue.memberName(index)
                        let child = objectValue.memberValue(index)
                        if (!matched.contains(name)) { validateSchemaValue(context, childSchema, child, appendJsonPath(jsonPath, name),
                            appendSchemaPath(schemaPath, "additionalProperties"), errors, refStack) }
                    }
            case None => match (objectSchema.get("unevaluatedProperties")) {
                case Some(childSchema) =>
                    let evaluated = collectEvaluatedProperties(context, objectSchema, objectValue, refStack, true)
                    for (index in 0..objectValue.size()) {
                        let name = objectValue.memberName(index)
                        let child = objectValue.memberValue(index)
                                if (!evaluated.contains(name)) { validateSchemaValue(context, childSchema, child,
                                    appendJsonPath(jsonPath, name), appendSchemaPath(schemaPath, "unevaluatedProperties"),
                                    errors, refStack) }
                    }
                case None => ()
            }
        }
    }

    private func schemaValueIsValid(context: ValidationContext, value: JsonNode, instance: JsonValueView,
        refStack: ArrayList<String>): Bool {
        probeSchemaValue(context, value, instance, "", "#", refStack)
    }

    private func probeSchemaValue(context: ValidationContext, value: JsonNode, instance: JsonValueView,
        jsonPath: String, schemaPath: String, refStack: ArrayList<String>): Bool {
        let nested = ArrayList<JsonSchemaViolation>()
        context.probeDepth++
        try {
            validateSchemaValue(context, value, instance, jsonPath, schemaPath, nested, refStack)
            nested.isEmpty()
        } finally {
            context.probeDepth--
        }
    }

    private func addEvaluatedPropertiesFromSchema(context: ValidationContext, result: HashSet<String>, value: JsonNode,
        instance: JsonValueView, refStack: ArrayList<String>): Unit {
        if (value.kind() == JsonKind.Object) {
                let nested = collectEvaluatedProperties(context, value.asObject(), instance, refStack, false)
                for (name in nested) { result.add(name) }
        }
    }

    private func collectEvaluatedProperties(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        refStack: ArrayList<String>, ignoreOwnUnevaluated: Bool): HashSet<String> {
        let result = HashSet<String>()
        match (objectSchema.get("properties")) {
            case Some(value) =>
                let properties = value.asObject()
                for (index in 0..properties.size()) {
                    let name = properties.nameAt(index)
                    if (schemaObjectContains(instance, name)) { result.add(name) }
                }
            case None => ()
        }
        match (objectSchema.get("patternProperties")) {
            case Some(value) =>
                let patterns = value.asObject()
                for (patternIndex in 0..patterns.size()) {
                    let pattern = patterns.nameAt(patternIndex)
                    for (index in 0..instance.size()) {
                        let name = instance.memberName(index)
                        if (regexFind(context, pattern, name)) { result.add(name) }
                    }
                }
            case None => ()
        }
        match (objectSchema.get("additionalProperties")) {
            case Some(value) => for (index in 0..instance.size()) {
                let name = instance.memberName(index)
                let child = instance.memberValue(index)
                if (!result.contains(name) && schemaValueIsValid(context, value, child, refStack)) { result.add(name) }
            }
            case None => ()
        }
        match (objectSchema.get("dependentSchemas")) {
            case Some(value) =>
                let dependencies = value.asObject()
                for (index in 0..dependencies.size()) {
                    let trigger = dependencies.nameAt(index)
                    let childSchema = dependencies.valueAt(index)
                if (schemaObjectContains(instance, trigger) && schemaValueIsValid(context, childSchema, instance, refStack)) {
                    addEvaluatedPropertiesFromSchema(context, result, childSchema, instance, refStack)
                }
            }
            case None => ()
        }
        for (keyword in ["allOf", "anyOf", "oneOf"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => for (index in 0..value.asArray().size()) {
                    let childSchema = value.asArray()[index]
                    if (schemaValueIsValid(context, childSchema, instance, refStack)) {
                        addEvaluatedPropertiesFromSchema(context, result, childSchema, instance, refStack)
                    }
                }
                case None => ()
            }
        }
        match (objectSchema.get("if")) {
            case Some(condition) =>
                let conditionMatches = schemaValueIsValid(context, condition, instance, refStack)
                if (conditionMatches) { addEvaluatedPropertiesFromSchema(context, result, condition, instance, refStack) }
                let branch = if (conditionMatches) { "then" } else { "else" }
                match (objectSchema.get(branch)) {
                    case Some(value) => if (schemaValueIsValid(context, value, instance, refStack)) {
                        addEvaluatedPropertiesFromSchema(context, result, value, instance, refStack)
                    }
                    case None => ()
                }
            case None => ()
        }
        for (keyword in ["$ref", "$dynamicRef"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => match (if (keyword == "$dynamicRef") {
                    resolveDynamicRef(context, value.asString())
                } else { resolveRef(context, value.asString()) }) {
                    case Some(target) =>
                        context.baseUriStack.add(target.baseUri); context.resourceStack.add(target.resource)
                        if (schemaValueIsValid(context, target.value, instance, refStack)) {
                            addEvaluatedPropertiesFromSchema(context, result, target.value, instance, refStack)
                        }
                        context.resourceStack.remove(at: context.resourceStack.size - 1); context.baseUriStack.remove(at: context.baseUriStack.size - 1)
                    case None => ()
                }
                case None => ()
            }
        }
        if (!ignoreOwnUnevaluated) {
            match (objectSchema.get("unevaluatedProperties")) {
                case Some(value) => for (index in 0..instance.size()) {
                    let name = instance.memberName(index)
                    let child = instance.memberValue(index)
                    if (!result.contains(name) && schemaValueIsValid(context, value, child, refStack)) { result.add(name) }
                }
                case None => ()
            }
        }
        result
    }

    private func validateObjectSizeKeyword(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        jsonPath: String, schemaPath: String, keyword: String, minimum: Bool,
        errors: ArrayList<JsonSchemaViolation>): Unit {
        match (objectSchema.get(keyword)) {
            case Some(value) =>
                let limit = requireSchemaNonNegativeInt(value, appendSchemaPath(schemaPath, keyword))
                if ((minimum && instance.size() < limit) || (!minimum && instance.size() > limit)) {
                    addError(context, errors, jsonPath, appendSchemaPath(schemaPath, keyword),
                        "object property count must be ${if (minimum) { ">=" } else { "<=" }} ${limit}")
                }
            case None => ()
        }
    }

    private func validateArrayKeywords(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        jsonPath: String, schemaPath: String, errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>): Unit {
        if (instance.kind() == JsonKind.Array) {
                let arrayValue = instance
                validateArraySizeKeyword(context, objectSchema, arrayValue, jsonPath, schemaPath, "minItems", true, errors)
                validateArraySizeKeyword(context, objectSchema, arrayValue, jsonPath, schemaPath, "maxItems", false, errors)
                match (objectSchema.get("uniqueItems")) {
                    case Some(value) => if (value.asBool()) {
                        for (i in 0..arrayValue.size()) { for (j in i + 1..arrayValue.size()) {
                            consumeEvaluation(context)
                            if (jsonNodesEquivalent(arrayValue.element(i).getOrThrow(),
                                arrayValue.element(j).getOrThrow())) { addError(context, errors, jsonPath,
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
                        for (index in 0..limit) { validateSchemaValue(context, schemas[index], arrayValue.element(index).getOrThrow(),
                            appendJsonPath(jsonPath, index.toString()),
                            appendSchemaPath(appendSchemaPath(schemaPath, "prefixItems"), index.toString()),
                            errors, refStack) }
                    case None => ()
                }
                match (objectSchema.get("items")) {
                    case Some(itemSchema) => if (objectSchema.get("prefixItems").isSome()) {
                        for (index in prefixCount..arrayValue.size()) { validateSchemaValue(context, itemSchema,
                            arrayValue.element(index).getOrThrow(),
                            appendJsonPath(jsonPath, index.toString()),
                            appendSchemaPath(schemaPath, "items"), errors, refStack) }
                    }
                    case None => ()
                }
                if (objectSchema.get("items").isNone()) {
                    match (objectSchema.get("unevaluatedItems")) {
                        case Some(childSchema) =>
                            let evaluated = collectEvaluatedItems(context, objectSchema, arrayValue, refStack, true)
                            for (index in 0..arrayValue.size()) {
                                if (!evaluated.contains(index)) { validateSchemaValue(context, childSchema,
                                    arrayValue.element(index).getOrThrow(),
                                    appendJsonPath(jsonPath, index.toString()),
                                    appendSchemaPath(schemaPath, "unevaluatedItems"),
                                    errors, refStack) }
                            }
                        case None => ()
                    }
                }
                match (objectSchema.get("contains")) {
                    case Some(containsSchema) =>
                        var count: Int64 = 0
                        for (index in 0..arrayValue.size()) {
                            if (probeSchemaValue(context, containsSchema, arrayValue.element(index).getOrThrow(),
                                appendJsonPath(jsonPath, index.toString()),
                                appendSchemaPath(schemaPath, "contains"), refStack)) { count++ }
                        }
                        let minimum = match (objectSchema.get("minContains")) { case Some(v) => requireSchemaNonNegativeInt(v,
                            appendSchemaPath(schemaPath, "minContains")); case None => 1 }
                        let maximum = match (objectSchema.get("maxContains")) { case Some(v) => Some(requireSchemaNonNegativeInt(v,
                            appendSchemaPath(schemaPath, "maxContains"))); case None => None<Int64> }
                        if (count < minimum || (maximum.isSome() && count > maximum.getOrThrow())) {
                            addError(context, errors, jsonPath, appendSchemaPath(schemaPath, "contains"),
                                "array contains match count ${count} is outside configured bounds")
                        }
                    case None => ()
                }
        }
    }

    private func addEvaluatedItemsFromSchema(context: ValidationContext, result: HashSet<Int64>, value: JsonNode,
        instance: JsonValueView, refStack: ArrayList<String>): Unit {
        if (value.kind() == JsonKind.Object) {
                let nested = collectEvaluatedItems(context, value.asObject(), instance, refStack, false)
                for (index in nested) { result.add(index) }
        }
    }

    private func collectEvaluatedItems(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
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
                if (schemaValueIsValid(context, value, instance.element(index).getOrThrow(), refStack)) { result.add(index) }
            }
            case None => ()
        }
        for (keyword in ["allOf", "anyOf", "oneOf"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => for (index in 0..value.asArray().size()) {
                    let childSchema = value.asArray()[index]
                    if (schemaValueIsValid(context, childSchema, instance, refStack)) {
                        addEvaluatedItemsFromSchema(context, result, childSchema, instance, refStack)
                    }
                }
                case None => ()
            }
        }
        match (objectSchema.get("if")) {
            case Some(condition) =>
                let conditionMatches = schemaValueIsValid(context, condition, instance, refStack)
                if (conditionMatches) { addEvaluatedItemsFromSchema(context, result, condition, instance, refStack) }
                let branch = if (conditionMatches) { "then" } else { "else" }
                match (objectSchema.get(branch)) {
                    case Some(value) => if (schemaValueIsValid(context, value, instance, refStack)) {
                        addEvaluatedItemsFromSchema(context, result, value, instance, refStack)
                    }
                    case None => ()
                }
            case None => ()
        }
        for (keyword in ["$ref", "$dynamicRef"]) {
            match (objectSchema.get(keyword)) {
                case Some(value) => match (if (keyword == "$dynamicRef") {
                    resolveDynamicRef(context, value.asString())
                } else { resolveRef(context, value.asString()) }) {
                    case Some(target) =>
                        context.baseUriStack.add(target.baseUri); context.resourceStack.add(target.resource)
                        if (schemaValueIsValid(context, target.value, instance, refStack)) {
                            addEvaluatedItemsFromSchema(context, result, target.value, instance, refStack)
                        }
                        context.resourceStack.remove(at: context.resourceStack.size - 1); context.baseUriStack.remove(at: context.baseUriStack.size - 1)
                    case None => ()
                }
                case None => ()
            }
        }
        if (!ignoreOwnUnevaluated) {
            match (objectSchema.get("unevaluatedItems")) {
                case Some(value) => for (index in 0..instance.size()) {
                    if (!result.contains(index) && schemaValueIsValid(context, value,
                        instance.element(index).getOrThrow(), refStack)) { result.add(index) }
                }
                case None => ()
            }
        }
        result
    }

    private func validateArraySizeKeyword(context: ValidationContext, objectSchema: JsonObject, instance: JsonValueView,
        jsonPath: String, schemaPath: String, keyword: String, minimum: Bool,
        errors: ArrayList<JsonSchemaViolation>): Unit {
        match (objectSchema.get(keyword)) {
            case Some(value) =>
                let limit = requireSchemaNonNegativeInt(value, appendSchemaPath(schemaPath, keyword))
                if ((minimum && instance.size() < limit) || (!minimum && instance.size() > limit)) {
                    addError(context, errors, jsonPath, appendSchemaPath(schemaPath, keyword),
                        "array length must be ${if (minimum) { ">=" } else { "<=" }} ${limit}")
                }
            case None => ()
        }
    }

    private func resolveRef(context: ValidationContext, refText: String): Option<JsonSchemaResolvedRef> {
        context.refResolutionCount++
        enforceWorkLimit(context.refResolutionCount, schema.config.limits.maxRefResolutions, "reference resolutions")
        let base = context.baseUriStack[context.baseUriStack.size - 1]
        let absolute = resolveJsonSchemaUri(base, refText)
        let hashIndex = absolute.indexOf("#")
        let resourceUri = match (hashIndex) { case Some(index) => absolute[0..index]; case None => absolute }
        let fragment = match (hashIndex) { case Some(index) => absolute[index..absolute.size]; case None => "#" }
        let currentBase = stripJsonSchemaFragment(base)
        if (resourceUri == currentBase || (resourceUri.isEmpty() && currentBase.isEmpty())) {
            let resource = context.resourceStack[context.resourceStack.size - 1]
            return attachJsonSchemaResolutionContext(resolveSchemaFragment(resource, fragment, absolute),
                currentBase, resource, adoptPointerResource: fragment.startsWith("#/"))
        }
        let currentResource = context.resourceStack[context.resourceStack.size - 1]
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
        match (schema.compiledResource(resourceUri)) {
            case Some(resource) => attachJsonSchemaResolutionContext(
                resolveSchemaFragment(resource, fragment, absolute), resourceUri, resource,
                adoptPointerResource: fragment.startsWith("#/"))
            case None => None<JsonSchemaResolvedRef>
        }
    }

    private func resolveDynamicRef(context: ValidationContext, refText: String): Option<JsonSchemaResolvedRef> {
        let staticallyResolved = resolveRef(context, refText)
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
        for (index in 0..context.resourceStack.size) {
            let resource = context.resourceStack[index]
            let base = stripJsonSchemaFragment(context.baseUriStack[index])
            if (visited.contains(base)) { continue }
            visited.add(base)
            match (findJsonSchemaDynamicAnchor(resource, anchor, base)) {
                case Some(found) => return Some(found)
                case None => ()
            }
        }
        staticallyResolved
    }

    private func validateFormat(context: ValidationContext, format: String, instance: JsonValueView, jsonPath: String,
        schemaPath: String, errors: ArrayList<JsonSchemaViolation>): Unit {
        if (let Annotation <- schema.config.formatMode) { return }
        if (instance.kind() == JsonKind.String) {
                match (schema.config.formats.resolve(format)) {
                    case Some(assertion: CoreJsonSchemaFormat) =>
                        if (!assertion.validateWithBudget(instance.asString(), context.regexBudget)) {
                            addError(context, errors, jsonPath, schemaPath, "string does not satisfy format ${format}")
                        }
                    case Some(assertion) => if (!assertion.validate(instance.asString())) {
                        addError(context, errors, jsonPath, schemaPath, "string does not satisfy format ${format}")
                    }
                    case None => ()
                }
        }
    }

    private func regexFind(context: ValidationContext, pattern: String, value: String): Bool {
        match (schema.compiledRegex(pattern)) {
            case Some(regex) => regex.find(value, context.regexBudget)
            case None => throw JsonException("Schema regex was not compiled: ${pattern}",
                code: "invalid_regex")
        }
    }

    private func validateType(context: ValidationContext,
        typeSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>
    ): Unit {
        match (typeSchema.kind()) {
            case JsonKind.String =>
                let typeName = typeSchema.asString()
                if (!jsonSchemaMatchesType(instance, typeName)) {
                    addError(context, errors, jsonPath, schemaPath, "expected type ${typeName}, got ${jsonSchemaInstanceType(instance)}")
                }
            case JsonKind.Array =>
                let typeNames = typeSchema.asArray()
                var matched = false
                let expected = ArrayList<String>()
                for (index in 0..typeNames.size()) {
                    let name = typeNames[index].asString()
                    expected.add(name)
                    if (jsonSchemaMatchesType(instance, name)) {
                        matched = true
                    }
                }
                if (!matched) {
                    addError(context, errors, jsonPath, schemaPath, "expected one of ${joinStrings(expected, ", ")}, got ${jsonSchemaInstanceType(instance)}")
                }
            case _ => throw JsonException("${schemaPath}: type must be a string or string array")
        }
    }

    private func validateEnum(context: ValidationContext,
        enumSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>
    ): Unit {
        let values = enumSchema.asArray()
        for (index in 0..values.size()) {
            if (jsonNodesEquivalent(values[index], instance)) {
                return
            }
        }
        addError(context, errors, jsonPath, schemaPath, "value must match one enum entry")
    }

    private func validateNumericLimit(context: ValidationContext,
        limitSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        minimum: Bool,
        errors: ArrayList<JsonSchemaViolation>
    ): Unit {
        match (jsonNodeAsDecimal(instance)) {
            case Some(instanceNumber) =>
                let limit = requireSchemaDecimal(limitSchema, schemaPath)
                if (minimum && instanceNumber < limit) {
                    addError(context, errors, jsonPath, schemaPath, "number must be >= ${limit}")
                }
                if (!minimum && instanceNumber > limit) {
                    addError(context, errors, jsonPath, schemaPath, "number must be <= ${limit}")
                }
            case None => ()
        }
    }

    private func validateStringLength(context: ValidationContext,
        lengthSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        minimum: Bool,
        errors: ArrayList<JsonSchemaViolation>
    ): Unit {
        if (instance.kind() == JsonKind.String) {
                let limit = requireSchemaNonNegativeInt(lengthSchema, schemaPath)
                var actual: Int64 = 0
                for (byte in unsafe { instance.asString().rawData() }) {
                    if (byte < 0x80u8 || byte >= 0xC0u8) { actual++ }
                }
                if (minimum && actual < limit) {
                    addError(context, errors, jsonPath, schemaPath, "string length must be >= ${limit}")
                }
                if (!minimum && actual > limit) {
                    addError(context, errors, jsonPath, schemaPath, "string length must be <= ${limit}")
                }
        }
    }

    private func validateRequired(context: ValidationContext,
        requiredSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>
    ): Unit {
        if (instance.kind() == JsonKind.Object) {
                let required = requiredSchema.asArray()
                for (index in 0..required.size()) {
                    let field = required[index].asString()
                    if (instance.member(field).isNone()) {
                        addError(context, errors, jsonPath, appendSchemaPath(schemaPath, index.toString()), "missing required property ${field}")
                    }
                }
        }
    }

    private func validateProperties(context: ValidationContext,
        propertiesSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        let properties = propertiesSchema.asObject()
        if (instance.kind() == JsonKind.Object) {
                for (index in 0..properties.size()) {
                    let field = properties.nameAt(index)
                    let childSchema = properties.valueAt(index)
                    match (instance.member(field)) {
                        case Some(child) =>
                            validateSchemaValue(context,
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
        }
    }

    private func validateItems(context: ValidationContext,
        itemsSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        if (instance.kind() == JsonKind.Array) {
                for (index in 0..instance.size()) {
                    validateSchemaValue(context, itemsSchema, instance.element(index).getOrThrow(),
                        appendJsonPath(jsonPath, index.toString()), schemaPath, errors, refStack)
                }
        }
    }

    private func validateAllOf(context: ValidationContext,
        combinatorSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        for (index in 0..schemas.size()) {
            validateSchemaValue(context, schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), errors, refStack)
        }
    }

    private func validateAnyOf(context: ValidationContext,
        combinatorSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        for (index in 0..schemas.size()) {
            if (probeSchemaValue(context, schemas[index], instance, jsonPath,
                appendSchemaPath(schemaPath, index.toString()), refStack)) {
                return
            }
        }
        addError(context, errors, jsonPath, schemaPath, "value must match at least one anyOf schema")
    }

    private func validateOneOf(context: ValidationContext,
        combinatorSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        var matches = 0
        for (index in 0..schemas.size()) {
            if (probeSchemaValue(context, schemas[index], instance, jsonPath,
                appendSchemaPath(schemaPath, index.toString()), refStack)) {
                matches++
            }
        }
        if (matches != 1) {
            addError(context, errors, jsonPath, schemaPath, "value must match exactly one oneOf schema, matched ${matches}")
        }
    }

    private func validateNot(context: ValidationContext,
        notSchema: JsonNode,
        instance: JsonValueView,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonSchemaViolation>,
        refStack: ArrayList<String>
    ): Unit {
        if (probeSchemaValue(context, notSchema, instance, jsonPath, schemaPath, refStack)) {
            addError(context, errors, jsonPath, schemaPath, "value must not match this schema")
        }
    }

    private func consumeEvaluation(context: ValidationContext): Unit {
        context.evaluationCount++
        enforceWorkLimit(context.evaluationCount, schema.config.limits.maxEvaluations, "schema evaluations")
    }

    private func addError(context: ValidationContext, errors: ArrayList<JsonSchemaViolation>, jsonPath: String,
        schemaPath: String, message: String, code!: String = "schema_validation"): Unit {
        if (context.stopAtFirst && context.probeDepth == 0) { throw JsonSchemaMismatchSignal() }
        enforceWorkLimit(errors.size + 1, schema.config.limits.maxErrors, "schema errors")
        errors.add(JsonSchemaViolation(jsonPath, schemaPath, message, code: code))
    }
}

private class JsonSchemaResolvedRef {
    public let value: JsonNode
    public let schemaPath: String
    public let baseUri: String
    public let resource: JsonNode

    public init(value: JsonNode, schemaPath: String, baseUri!: String = "",
        resource!: JsonNode = JsonNode.nullValue) {
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
                case objectValue: JsonObject => match (objectValue.get("$id")) {
                    case Some(idValue) =>
                        let nestedBase = stripJsonSchemaFragment(resolveJsonSchemaUri(baseUri,
                            idValue.asString()))
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
        case objectValue: JsonObject =>
            var base = inheritedBase
            match (objectValue.get("$id")) {
                case Some(idValue) =>
                    base = stripJsonSchemaFragment(resolveJsonSchemaUri(inheritedBase, idValue.asString()))
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

private func compileJsonSchemaResourceGraph(root: JsonNode,
    resolver: Option<UriResolver>, limits: JsonSchemaLimits): HashMap<String, JsonNode> {
    let resources = HashMap<String, JsonNode>()
    let pending = ArrayList<String>()
    let scheduled = HashSet<String>()
    collectJsonSchemaResourceDependencies(root, "", root, resources, pending, scheduled)
    var cursor: Int64 = 0
    var resolutions: Int64 = 0
    while (cursor < pending.size) {
        let uri = pending[cursor]
        cursor++
        if (jsonSchemaResourceIsAvailable(root, resources, uri)) { continue }
        match (resolver) {
            case Some(source) =>
                resolutions++
                enforceWorkLimit(resolutions, limits.maxRefResolutions,
                    "compile-time reference resolutions")
                match (source.resolve(uri)) {
                    case Some(resolved) =>
                        let detached = resolved.deepCopy()
                        validateJsonSchemaDocument(detached, "#")
                        resources[uri] = detached
                        indexJsonSchemaCompiledResources(detached, uri, resources)
                        collectJsonSchemaResourceDependencies(detached, uri, root,
                            resources, pending, scheduled)
                    case None => ()
                }
            case None => ()
        }
    }
    resources
}

private func collectJsonSchemaResourceDependencies(node: JsonNode,
    inheritedBase: String, root: JsonNode, resources: HashMap<String, JsonNode>,
    pending: ArrayList<String>, scheduled: HashSet<String>): Unit {
    match (node) {
        case objectValue: JsonObject =>
            var base = inheritedBase
            match (objectValue.get("$id")) {
                case Some(idValue) => base = stripJsonSchemaFragment(
                    resolveJsonSchemaUri(inheritedBase, idValue.asString()))
                case None => ()
            }
            for (keyword in ["$ref", "$dynamicRef", "$schema"]) {
                match (objectValue.get(keyword)) {
                    case Some(referenceValue) => if (referenceValue.kind() == JsonKind.String) {
                        let absolute = resolveJsonSchemaUri(base, referenceValue.asString())
                        let uri = stripJsonSchemaFragment(absolute)
                        if (!uri.isEmpty() && uri != stripJsonSchemaFragment(base) &&
                            !jsonSchemaKnownMetaResource(uri) &&
                            !jsonSchemaResourceIsAvailable(root, resources, uri) &&
                            !scheduled.contains(uri)) {
                            scheduled.add(uri)
                            pending.add(uri)
                        }
                    }
                    case None => ()
                }
            }
            for (child in jsonSchemaChildSchemas(objectValue)) {
                collectJsonSchemaResourceDependencies(child, base, root,
                    resources, pending, scheduled)
            }
        case _ => ()
    }
}

private func indexJsonSchemaCompiledResources(node: JsonNode,
    inheritedBase: String, resources: HashMap<String, JsonNode>): Unit {
    match (node) {
        case objectValue: JsonObject =>
            var base = inheritedBase
            match (objectValue.get("$id")) {
                case Some(idValue) =>
                    base = stripJsonSchemaFragment(resolveJsonSchemaUri(
                        inheritedBase, idValue.asString()))
                    if (!base.isEmpty() && resources.get(base).isNone()) {
                        resources[base] = node
                    }
                case None => ()
            }
            for (child in jsonSchemaChildSchemas(objectValue)) {
                indexJsonSchemaCompiledResources(child, base, resources)
            }
        case _ => ()
    }
}

private func jsonSchemaResourceIsAvailable(root: JsonNode,
    resources: HashMap<String, JsonNode>, uri: String): Bool {
    if (resources.get(uri).isSome()) { return true }
    findJsonSchemaResource(root, "", uri).isSome()
}

private func jsonSchemaKnownMetaResource(uri: String): Bool {
    uri == "https://json-schema.org/draft/2020-12/schema"
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
            return Some(JsonSchemaResolvedRef(
                JsonPointer.parseUriFragment(fragment).evaluate(resource).materialize(), displayPath))
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
        case objectValue: JsonObject =>
            if (!resourceRoot && objectValue.contains("$id")) { return None<JsonSchemaResolvedRef> }
            for (keyword in ["$anchor", "$dynamicAnchor"]) {
                match (objectValue.get(keyword)) {
                    case Some(value) => if (value.asString() == anchor) {
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
        validateWithBudget(value, LinearRegexBudget(JsonSchemaLimits.defaults.maxRegexSteps,
            "JSON Schema format regex steps"))
    }

    func validateWithBudget(value: String, budget: LinearRegexBudget): Bool {
        match (name) {
            case "date" => jsonSchemaIsDate(value)
            case "time" => jsonSchemaIsTime(value)
            case "date-time" => jsonSchemaIsDateTime(value)
            case "duration" => jsonSchemaIsDuration(value)
            case "email" => jsonSchemaIsEmail(value, false)
            case "ipv4" => jsonSchemaIsIpv4(value)
            case "ipv6" => jsonSchemaIsIpv6(value)
            case "uuid" => jsonSchemaIsUuid(value)
            case "regex" => jsonSchemaIsEcmaRegex(value, budget)
            case "json-pointer" => try { let _ = JsonPointer.parse(value); true } catch (_: Exception) { false }
            case "relative-json-pointer" => jsonSchemaIsRelativePointer(value)
            case _ => false
        }
    }
}

private func jsonSchemaIsUuid(value: String): Bool {
    if (value.size != 36) { return false }
    for (index in 0..value.size) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != b'-') { return false }
        } else {
            let byte = value[index]
            if (!((byte >= b'0' && byte <= b'9') || (byte >= b'A' && byte <= b'F') ||
                (byte >= b'a' && byte <= b'f'))) { return false }
        }
    }
    true
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
        case objectValue: JsonObject => match (objectValue.get("$dynamicAnchor")) {
            case Some(value) => value.asString() == anchor
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
        case objectValue: JsonObject =>
            if (!resourceRoot && objectValue.contains("$id")) { return None<JsonSchemaResolvedRef> }
            match (objectValue.get("$dynamicAnchor")) {
                case Some(value) => if (value.asString() == anchor) {
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

private func jsonSchemaChildSchemas(objectValue: JsonObject): ArrayList<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (keyword in ["additionalProperties", "contains", "contentSchema", "else", "if", "items",
        "not", "propertyNames", "then", "unevaluatedItems", "unevaluatedProperties"]) {
        match (objectValue.get(keyword)) { case Some(child) => result.add(child); case None => () }
    }
    for (keyword in ["allOf", "anyOf", "oneOf", "prefixItems"]) {
        match (objectValue.get(keyword)) {
            case Some(children) =>
                let array = children.asArray()
                for (index in 0..array.size()) { result.add(array[index]) }
            case None => ()
        }
    }
    for (keyword in ["$defs", "definitions", "dependentSchemas", "patternProperties", "properties"]) {
        match (objectValue.get(keyword)) {
            case Some(children) =>
                let object = children.asObject()
                for (index in 0..object.size()) { result.add(object.valueAt(index)) }
            case None => ()
        }
    }
    result
}

private func compileJsonSchemaRegexes(document: JsonNode,
    resources: HashMap<String, JsonNode>, limits: JsonSchemaLimits): HashMap<String, LinearRegex> {
    let result = HashMap<String, LinearRegex>()
    let budget = LinearRegexBudget(limits.maxRegexSteps, "JSON Schema regex compilation steps")
    collectJsonSchemaRegexes(document, result, budget)
    for ((_, resource) in resources) { collectJsonSchemaRegexes(resource, result, budget) }
    result
}

private func collectJsonSchemaRegexes(node: JsonNode,
    result: HashMap<String, LinearRegex>, budget: LinearRegexBudget): Unit {
    match (node) {
        case objectValue: JsonObject =>
            match (objectValue.get("pattern")) {
                case Some(patternValue) => compileJsonSchemaRegex(patternValue.asString(), result, budget)
                case None => ()
            }
            match (objectValue.get("patternProperties")) {
                case Some(patternProperties) =>
                    let patterns = patternProperties.asObject()
                    for (index in 0..patterns.size()) {
                        compileJsonSchemaRegex(patterns.nameAt(index), result, budget)
                    }
                case None => ()
            }
            for (child in jsonSchemaChildSchemas(objectValue)) {
                collectJsonSchemaRegexes(child, result, budget)
            }
        case _ => ()
    }
}

private func compileJsonSchemaRegex(pattern: String,
    result: HashMap<String, LinearRegex>, budget: LinearRegexBudget): Unit {
    if (result.get(pattern).isNone()) { result[pattern] = LinearRegex.compile(pattern, budget) }
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

private func jsonSchemaIsEcmaRegex(value: String, budget: LinearRegexBudget): Bool {
    LinearRegex.validateEcmaSyntax(value, budget)
}

private func validateJsonSchemaDocument(schemaValue: JsonNode, schemaPath: String): Unit {
    match (schemaValue.kind()) {
        case JsonKind.Boolean => ()
        case JsonKind.Object =>
            let objectValue = schemaValue.asObject()
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
                    for (index in 0..properties.size()) {
                        let field = properties.nameAt(index)
                        let childSchema = properties.valueAt(index)
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
                    for (index in 0..defs.size()) {
                        let name = defs.nameAt(index)
                        let defSchema = defs.valueAt(index)
                        validateJsonSchemaDocument(defSchema, appendSchemaPath(appendSchemaPath(schemaPath, "$defs"), name))
                    }
                case None => ()
            }
            match (objectValue.get("definitions")) {
                case Some(defsSchema) =>
                    let defs = defsSchema.asObject()
                    for (index in 0..defs.size()) {
                        let name = defs.nameAt(index)
                        let defSchema = defs.valueAt(index)
                        validateJsonSchemaDocument(defSchema, appendSchemaPath(appendSchemaPath(schemaPath, "definitions"), name))
                    }
                case None => ()
            }
        case _ => throw JsonException("${schemaPath}: schema must be a boolean or object")
    }
}

private func validateJsonSchemaDocumentArray(objectValue: JsonObject, keyword: String, schemaPath: String): Unit {
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
    match (typeSchema.kind()) {
        case JsonKind.String => validateJsonSchemaTypeName(typeSchema.asString(), schemaPath)
        case JsonKind.Array =>
            let typeNames = typeSchema.asArray()
            for (index in 0..typeNames.size()) {
                let childPath = appendSchemaPath(schemaPath, index.toString())
                validateJsonSchemaTypeName(typeNames[index].asString(), childPath)
            }
        case _ => throw JsonException("${schemaPath}: type must be a string or string array")
    }
}

private func validateJsonSchemaStringArray(value: JsonNode, schemaPath: String): Unit {
    let array = value.asArray()
    for (index in 0..array.size()) {
        if (array[index].kind() != JsonKind.String) {
            throw JsonException("${appendSchemaPath(schemaPath, index.toString())}: expected string")
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

private func jsonSchemaMatchesType(value: JsonValueView, typeName: String): Bool {
    match (typeName) {
        case "null" => value.kind() == JsonKind.Null
        case "boolean" => value.kind() == JsonKind.Boolean
        case "object" => value.kind() == JsonKind.Object
        case "array" => value.kind() == JsonKind.Array
        case "string" => value.kind() == JsonKind.String
        case "number" => jsonSchemaNumberAsFloat(value).isSome()
        case "integer" => jsonSchemaIsInteger(value)
        case _ => false
    }
}

private func jsonSchemaInstanceType(value: JsonValueView): String {
    match (value.kind()) {
        case JsonKind.Null => "null"
        case JsonKind.Boolean => "boolean"
        case JsonKind.Object => "object"
        case JsonKind.Array => "array"
        case JsonKind.String => "string"
        case JsonKind.Number =>
            if (jsonSchemaIsInteger(value)) {
                "integer"
            } else {
                "number"
            }
    }
}

private func jsonSchemaNumberAsFloat(value: JsonValueView): Option<Float64> {
    if (value.kind() != JsonKind.Number) { return None<Float64> }
    try { Some(Float64.parse(value.asNumberText())) } catch (_: Exception) { None<Float64> }
}

private func jsonSchemaIsInteger(value: JsonValueView): Bool {
    match (jsonNodeAsDecimal(value)) { case Some(number) => number.isInteger(); case None => false }
}

private func requireSchemaDecimal(value: JsonNode, schemaPath: String): Decimal {
    match (jsonNodeAsDecimal(value)) {
        case Some(number) => number
        case None => throw JsonException("${schemaPath}: expected numeric schema value")
    }
}

private func requireSchemaNonNegativeInt(value: JsonNode, schemaPath: String): Int64 {
    let decimal = requireSchemaDecimal(value, schemaPath)
    if (!decimal.isInteger()) {
        throw JsonException("${schemaPath}: expected non-negative integer schema value")
    }
    let decoded = try {
        Int64(Float64.parse(value.asNumberText()))
    } catch (_: Exception) {
        throw JsonException("${schemaPath}: integer schema value is outside Int64 range")
    }
    if (Decimal(decoded) != decimal) {
        throw JsonException("${schemaPath}: integer schema value is outside Int64 range")
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
    "${base}/${jsonPointerEscape(field)}"
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
