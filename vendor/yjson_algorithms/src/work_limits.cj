package yjson_algorithms

import yjson.*

public class JsonPathLimits {
    public let maxVisitedNodes: Int64
    public let maxFilterSteps: Int64
    public let maxRegexSteps: Int64
    public let maxMatches: Int64
    public let maxDepth: Int64
    /**
     * Compile-time byte budget for one filter expression. 0 disables it.
     */
    public let maxFilterExpressionBytes: Int64
    /**
     * Compile-time budget for logical operators (`&&`, `||`, `!`) in one
     * filter expression. 0 disables it.
     */
    public let maxFilterOperators: Int64
    /**
     * Compile-time budget for logical recursion depth in one filter
     * expression. 0 disables it.
     */
    public let maxFilterDepth: Int64
    /**
     * Run-time budget for logical operations evaluated across a whole
     * path execution. 0 disables it.
     */
    public let maxFilterOperations: Int64
    public init(maxVisitedNodes!: Int64 = 100000, maxFilterSteps!: Int64 = 100000,
        maxRegexSteps!: Int64 = 100000, maxMatches!: Int64 = 10000, maxDepth!: Int64 = 256,
        maxFilterExpressionBytes!: Int64 = 4096, maxFilterOperators!: Int64 = 256,
        maxFilterDepth!: Int64 = 64, maxFilterOperations!: Int64 = 200000) {
        requireWorkLimit(maxVisitedNodes, "maxVisitedNodes"); requireWorkLimit(maxFilterSteps, "maxFilterSteps")
        requireWorkLimit(maxRegexSteps, "maxRegexSteps"); requireWorkLimit(maxMatches, "maxMatches")
        requireWorkLimit(maxDepth, "maxDepth")
        requireWorkLimit(maxFilterExpressionBytes, "maxFilterExpressionBytes")
        requireWorkLimit(maxFilterOperators, "maxFilterOperators")
        requireWorkLimit(maxFilterDepth, "maxFilterDepth")
        requireWorkLimit(maxFilterOperations, "maxFilterOperations")
        this.maxVisitedNodes = maxVisitedNodes; this.maxFilterSteps = maxFilterSteps
        this.maxRegexSteps = maxRegexSteps; this.maxMatches = maxMatches; this.maxDepth = maxDepth
        this.maxFilterExpressionBytes = maxFilterExpressionBytes
        this.maxFilterOperators = maxFilterOperators
        this.maxFilterDepth = maxFilterDepth
        this.maxFilterOperations = maxFilterOperations
    }
    public static let defaults = JsonPathLimits()
    public static let unlimited = JsonPathLimits(maxVisitedNodes: 0, maxFilterSteps: 0,
        maxRegexSteps: 0, maxMatches: 0, maxDepth: 0, maxFilterExpressionBytes: 0,
        maxFilterOperators: 0, maxFilterDepth: 0, maxFilterOperations: 0)
}

public class JsonPatchLimits {
    public let maxOperations: Int64
    public let maxPointerSegments: Int64
    public let maxCopiedNodes: Int64
    public init(maxOperations!: Int64 = 10000, maxPointerSegments!: Int64 = 256,
        maxCopiedNodes!: Int64 = 100000) {
        requireWorkLimit(maxOperations, "maxOperations"); requireWorkLimit(maxPointerSegments, "maxPointerSegments")
        requireWorkLimit(maxCopiedNodes, "maxCopiedNodes")
        this.maxOperations = maxOperations; this.maxPointerSegments = maxPointerSegments
        this.maxCopiedNodes = maxCopiedNodes
    }
    public static let defaults = JsonPatchLimits()
    public static let unlimited = JsonPatchLimits(maxOperations: 0, maxPointerSegments: 0, maxCopiedNodes: 0)
}

public class JsonSchemaLimits {
    public let maxEvaluations: Int64
    public let maxRefResolutions: Int64
    public let maxRegexSteps: Int64
    public let maxErrors: Int64
    public let maxDepth: Int64
    public init(maxEvaluations!: Int64 = 100000, maxRefResolutions!: Int64 = 1000,
        maxRegexSteps!: Int64 = 100000, maxErrors!: Int64 = 100, maxDepth!: Int64 = 256) {
        requireWorkLimit(maxEvaluations, "maxEvaluations"); requireWorkLimit(maxRefResolutions, "maxRefResolutions")
        requireWorkLimit(maxRegexSteps, "maxRegexSteps"); requireWorkLimit(maxErrors, "maxErrors")
        requireWorkLimit(maxDepth, "maxDepth")
        this.maxEvaluations = maxEvaluations; this.maxRefResolutions = maxRefResolutions
        this.maxRegexSteps = maxRegexSteps; this.maxErrors = maxErrors; this.maxDepth = maxDepth
    }
    public static let defaults = JsonSchemaLimits()
    public static let unlimited = JsonSchemaLimits(maxEvaluations: 0, maxRefResolutions: 0,
        maxRegexSteps: 0, maxErrors: 0, maxDepth: 0)
}

private func requireWorkLimit(value: Int64, name: String): Unit {
    if (value < 0) { throw IllegalArgumentException("${name} must not be negative") }
}

func enforceWorkLimit(value: Int64, limit: Int64, dimension: String): Unit {
    if (limit > 0 && value > limit) {
        throw JsonException(
            "JSON algorithm ${dimension} budget exceeded: limit=${limit}, consumed=${value}",
            code: "work_limit_exceeded")
    }
}
