package yjson_algorithms

import yjson.*

public class JsonWorkLimitException <: JsonException {
    public init(message: String) {
        super(message, code: "work_limit_exceeded", path: "$")
    }
    protected override func getClassName(): String { "JsonWorkLimitException" }
}

public class JsonPathLimits {
    public let maxVisitedNodes: Int64
    public let maxFilterSteps: Int64
    public let maxMatches: Int64
    public let maxDepth: Int64
    public init(maxVisitedNodes!: Int64 = 100000, maxFilterSteps!: Int64 = 100000,
        maxMatches!: Int64 = 10000, maxDepth!: Int64 = 256) {
        requireWorkLimit(maxVisitedNodes, "maxVisitedNodes"); requireWorkLimit(maxFilterSteps, "maxFilterSteps")
        requireWorkLimit(maxMatches, "maxMatches"); requireWorkLimit(maxDepth, "maxDepth")
        this.maxVisitedNodes = maxVisitedNodes; this.maxFilterSteps = maxFilterSteps
        this.maxMatches = maxMatches; this.maxDepth = maxDepth
    }
    public static let defaults = JsonPathLimits()
    public static let unlimited = JsonPathLimits(maxVisitedNodes: 0, maxFilterSteps: 0, maxMatches: 0, maxDepth: 0)
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
    public let maxErrors: Int64
    public let maxDepth: Int64
    public init(maxEvaluations!: Int64 = 100000, maxRefResolutions!: Int64 = 1000,
        maxErrors!: Int64 = 100, maxDepth!: Int64 = 256) {
        requireWorkLimit(maxEvaluations, "maxEvaluations"); requireWorkLimit(maxRefResolutions, "maxRefResolutions")
        requireWorkLimit(maxErrors, "maxErrors"); requireWorkLimit(maxDepth, "maxDepth")
        this.maxEvaluations = maxEvaluations; this.maxRefResolutions = maxRefResolutions
        this.maxErrors = maxErrors; this.maxDepth = maxDepth
    }
    public static let defaults = JsonSchemaLimits()
    public static let unlimited = JsonSchemaLimits(maxEvaluations: 0, maxRefResolutions: 0, maxErrors: 0, maxDepth: 0)
}

private func requireWorkLimit(value: Int64, name: String): Unit {
    if (value < 0) { throw IllegalArgumentException("${name} must not be negative") }
}

func enforceWorkLimit(value: Int64, limit: Int64, dimension: String): Unit {
    if (limit > 0 && value > limit) {
        throw JsonWorkLimitException("JSON algorithm ${dimension} budget exceeded (${limit})")
    }
}
