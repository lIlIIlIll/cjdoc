package yjson_algorithms

import yjson.*

import std.collection.*
import std.math.numeric.*

public class JsonPatchException <: JsonException {
    public let operationIndex: Int64

    public init(message: String, operationIndex!: Int64 = -1,
        code!: String = "invalid_json_patch", path!: String = "") {
        super(message, code: code, path: path)
        this.operationIndex = operationIndex
    }

    protected override func getClassName(): String { "JsonPatchException" }
}

public enum JsonPatchOperationKind <: Equatable<JsonPatchOperationKind> & ToString {
    Add | Remove | Replace | Move | Copy | Test

    public operator func ==(other: JsonPatchOperationKind): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: JsonPatchOperationKind): Bool { !(this == other) }

    public func toString(): String {
        match (this) {
            case Add => "add"
            case Remove => "remove"
            case Replace => "replace"
            case Move => "move"
            case Copy => "copy"
            case Test => "test"
        }
    }
}

public class JsonPatchOperation {
    public let kind: JsonPatchOperationKind
    public let path: JsonPointer
    public let source: Option<JsonPointer>
    public let value: Option<JsonNode>

    public init(kind: JsonPatchOperationKind, path: JsonPointer,
        source!: Option<JsonPointer> = None<JsonPointer>,
        value!: Option<JsonNode> = None<JsonNode>) {
        this.kind = kind
        this.path = path
        this.source = source
        this.value = match (value) {
            case Some(node) => Some(node.deepCopy())
            case None => None<JsonNode>
        }
        validateJsonPatchOperation(this, -1)
    }
}

public class JsonPatch {
    private let patchOperations: Array<JsonPatchOperation>

    public init(operations: Array<JsonPatchOperation>) {
        let copied = ArrayList<JsonPatchOperation>(operations.size)
        for (operation in operations) {
            copied.add(JsonPatchOperation(operation.kind, operation.path,
                source: operation.source, value: operation.value))
        }
        patchOperations = copied.toArray()
    }

    public static func parse(text: String,
        config!: JsonReadConfig = JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)): JsonPatch {
        fromValue(YJson.parse(text, config: config))
    }

    public static func fromValue(value: JsonNode): JsonPatch {
        let array = value.asArray()
        let operations = ArrayList<JsonPatchOperation>(array.size())
        for (index in 0..array.size()) {
            operations.add(parseJsonPatchOperation(array[index], index))
        }
        JsonPatch(operations.toArray())
    }

    public func operations(): Array<JsonPatchOperation> {
        let result = ArrayList<JsonPatchOperation>(patchOperations.size)
        for (operation in patchOperations) {
            result.add(JsonPatchOperation(operation.kind, operation.path,
                source: operation.source, value: operation.value))
        }
        result.toArray()
    }

    /// Applies atomically to a detached copy. The input is never changed.
    public func apply(target: JsonNode, limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        enforceWorkLimit(patchOperations.size, limits.maxOperations, "patch operations")
        for (operation in patchOperations) {
            enforceWorkLimit(operation.path.rawTokens().size, limits.maxPointerSegments, "pointer segments")
            if (let Some(source) <- operation.source) {
                enforceWorkLimit(source.rawTokens().size, limits.maxPointerSegments, "pointer segments")
            }
        }
        let copyWork = JsonPatchCopyWork(limits.maxCopiedNodes)
        copyWork.charge(target)
        applyJsonPatchOperations(target.deepCopy(), patchOperations, copyWork)
    }

    /// Applies atomically and commits into the original root container when
    /// its kind is unchanged. Callers must always use the returned root.
    public func applyInPlace(target: JsonNode,
        limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        let result = apply(target, limits: limits)
        commitJsonRoot(target, result)
    }
}

public class JsonMergePatch {
    public static func apply(target: JsonNode, patch: JsonNode,
        limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        enforceWorkLimit(jsonPatchNodeCount(target) + jsonPatchNodeCount(patch),
            limits.maxCopiedNodes, "copied nodes")
        let result = applyJsonMergePatch(target.deepCopy(), patch)
        enforceWorkLimit(jsonPatchNodeCount(result), limits.maxCopiedNodes, "copied nodes")
        result
    }

    public static func applyInPlace(target: JsonNode, patch: JsonNode,
        limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        commitJsonRoot(target, apply(target, patch, limits: limits))
    }
}

private func jsonPatchNodeCount(value: JsonNode): Int64 {
    match (value) {
        case arrayValue: JsonArrayValue =>
            var total: Int64 = 1
            for (item in arrayValue.values()) { total += jsonPatchNodeCount(item) }
            total
        case objectValue: JsonObjectValue =>
            var total: Int64 = 1
            for ((_, item) in objectValue.entries()) { total += jsonPatchNodeCount(item) }
            total
        case _ => 1
    }
}

private class JsonPatchCopyWork {
    private let limit: Int64
    private var copiedNodes: Int64 = 0

    init(limit: Int64) { this.limit = limit }

    func charge(value: JsonNode): Unit {
        let count = jsonPatchNodeCount(value)
        if (limit > 0 && (count > limit || copiedNodes > limit - count)) {
            throw JsonWorkLimitException("JSON algorithm copied nodes budget exceeded (${limit})")
        }
        copiedNodes += count
    }
}

private func parseJsonPatchOperation(value: JsonNode, index: Int64): JsonPatchOperation {
    let objectValue = value.asObject()
    let opText = requireJsonPatchString(objectValue, "op", index)
    let pathText = requireJsonPatchString(objectValue, "path", index)
    let kind = match (opText) {
        case "add" => JsonPatchOperationKind.Add
        case "remove" => JsonPatchOperationKind.Remove
        case "replace" => JsonPatchOperationKind.Replace
        case "move" => JsonPatchOperationKind.Move
        case "copy" => JsonPatchOperationKind.Copy
        case "test" => JsonPatchOperationKind.Test
        case _ => throw JsonPatchException("Unknown JSON Patch operation '${opText}'", operationIndex: index)
    }
    let source = match (objectValue.get("from")) {
        case Some(fromValue) => Some(JsonPointer.parse(fromValue.asString().value))
        case None => None<JsonPointer>
    }
    let patchValue = match (objectValue.get("value")) {
        case Some(node) => Some(node)
        case None => None<JsonNode>
    }
    let operation = JsonPatchOperation(kind, JsonPointer.parse(pathText), source: source, value: patchValue)
    validateJsonPatchOperation(operation, index)
    operation
}

private func requireJsonPatchString(objectValue: JsonObjectValue, name: String, index: Int64): String {
    objectValue.get(name).getOrThrow({ =>
        JsonPatchException("JSON Patch operation ${index} is missing '${name}'", operationIndex: index)
    }).asString().value
}

private func validateJsonPatchOperation(operation: JsonPatchOperation, index: Int64): Unit {
    match (operation.kind) {
        case Add | Replace | Test =>
            if (operation.value.isNone()) {
                throw JsonPatchException("JSON Patch '${operation.kind}' requires 'value'", operationIndex: index)
            }
        case Move | Copy =>
            if (operation.source.isNone()) {
                throw JsonPatchException("JSON Patch '${operation.kind}' requires 'from'", operationIndex: index)
            }
        case Remove => ()
    }
}

private func applyJsonPatchOperations(initial: JsonNode, operations: Array<JsonPatchOperation>,
    copyWork: JsonPatchCopyWork): JsonNode {
    var root = initial
    for (index in 0..operations.size) {
        try {
            root = applyJsonPatchOperation(root, operations[index], copyWork)
        } catch (error: JsonWorkLimitException) {
            throw error
        } catch (error: JsonPatchException) {
            throw JsonPatchException(error.message, operationIndex: index, code: error.code, path: error.path)
        } catch (error: JsonPointerException) {
            throw JsonPatchException(error.message, operationIndex: index,
                code: "json_patch_path", path: error.pointer)
        } catch (error: JsonException) {
            throw JsonPatchException(error.message, operationIndex: index,
                code: "json_patch_path", path: error.path)
        }
    }
    root
}

private func applyJsonPatchOperation(root: JsonNode, operation: JsonPatchOperation,
    copyWork: JsonPatchCopyWork): JsonNode {
    match (operation.kind) {
        case Add =>
            let value = operation.value.getOrThrow()
            copyWork.charge(value)
            jsonPatchAdd(root, operation.path, value.deepCopy())
        case Remove =>
            let (nextRoot, _) = jsonPatchRemove(root, operation.path)
            nextRoot
        case Replace =>
            let value = operation.value.getOrThrow()
            copyWork.charge(value)
            jsonPatchReplace(root, operation.path, value.deepCopy())
        case Copy =>
            let sourceValue = operation.source.getOrThrow().evaluate(root)
            copyWork.charge(sourceValue)
            jsonPatchAdd(root, operation.path, sourceValue.deepCopy())
        case Move => jsonPatchMove(root, operation.source.getOrThrow(), operation.path)
        case Test =>
            let expected = operation.value.getOrThrow()
            copyWork.charge(expected)
            let actual = operation.path.evaluate(root)
            if (!actual.equivalentTo(expected)) {
                throw JsonPatchException("JSON Patch test operation failed", code: "json_patch_test_failed",
                    path: operation.path.toString())
            }
            root
    }
}

private func jsonPatchAdd(root: JsonNode, pointer: JsonPointer, value: JsonNode): JsonNode {
    if (pointer.isRoot()) { return value }
    let (parent, token) = jsonPointerParent(root, pointer)
    match (parent) {
        case objectValue: JsonObjectValue => objectValue.put(token, value); root
        case arrayValue: JsonArrayValue =>
            let index = parseJsonPointerArrayIndex(token, arrayValue.size(), true).getOrThrow({ =>
                JsonPointerException("Invalid JSON Patch add array index '${token}'", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            arrayValue.insert(index, value)
            root
        case _ => throw JsonPointerException("JSON Patch add parent is not a container", pointer.toString(),
            code: "json_pointer_not_found")
    }
}

private func jsonPatchRemove(root: JsonNode, pointer: JsonPointer): (JsonNode, JsonNode) {
    if (pointer.isRoot()) {
        throw JsonPatchException("Removing the complete JSON document has no JsonNode result",
            code: "json_patch_path", path: pointer.toString())
    }
    let (parent, token) = jsonPointerParent(root, pointer)
    match (parent) {
        case objectValue: JsonObjectValue =>
            let removed = objectValue.remove(token).getOrThrow({ =>
                JsonPointerException("JSON Patch remove target does not exist", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            (root, removed)
        case arrayValue: JsonArrayValue =>
            let index = parseJsonPointerArrayIndex(token, arrayValue.size(), false).getOrThrow({ =>
                JsonPointerException("Invalid JSON Patch remove array index '${token}'", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            (root, arrayValue.removeAt(index))
        case _ => throw JsonPointerException("JSON Patch remove parent is not a container", pointer.toString(),
            code: "json_pointer_not_found")
    }
}

private func jsonPatchReplace(root: JsonNode, pointer: JsonPointer, value: JsonNode): JsonNode {
    if (pointer.isRoot()) { return value }
    let _ = pointer.evaluate(root)
    let (parent, token) = jsonPointerParent(root, pointer)
    match (parent) {
        case objectValue: JsonObjectValue => objectValue.put(token, value); root
        case arrayValue: JsonArrayValue =>
            let index = parseJsonPointerArrayIndex(token, arrayValue.size(), false).getOrThrow({ =>
                JsonPointerException("Invalid JSON Patch replace array index '${token}'", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            arrayValue.set(index, value)
            root
        case _ => throw JsonPointerException("JSON Patch replace parent is not a container", pointer.toString(),
            code: "json_pointer_not_found")
    }
}

private func jsonPatchMove(root: JsonNode, source: JsonPointer, destination: JsonPointer): JsonNode {
    if (source.toString() == destination.toString()) { return root }
    if (!source.isRoot() && destination.toString().startsWith(source.toString() + "/")) {
        throw JsonPatchException("JSON Patch move destination is inside the source", code: "json_patch_path",
            path: destination.toString())
    }
    if (source.isRoot()) {
        if (destination.isRoot()) { return root }
        throw JsonPatchException("Cannot move the document root into one of its descendants",
            code: "json_patch_path", path: destination.toString())
    }
    let (withoutSource, moved) = jsonPatchRemove(root, source)
    jsonPatchAdd(withoutSource, destination, moved)
}

private func applyJsonMergePatch(target: JsonNode, patch: JsonNode): JsonNode {
    match (patch) {
        case patchObject: JsonObjectValue =>
            let targetObject = match (target) {
                case objectValue: JsonObjectValue => objectValue
                case _ => JsonObjectValue()
            }
            for ((name, patchValue) in patchObject.entries()) {
                if (patchValue.isNull) {
                    let _ = targetObject.remove(name)
                } else {
                    let current = match (targetObject.get(name)) {
                        case Some(value) => value
                        case None => JsonNullValue()
                    }
                    targetObject.put(name, applyJsonMergePatch(current, patchValue))
                }
            }
            targetObject
        case _ => patch.deepCopy()
    }
}

private func commitJsonRoot(target: JsonNode, result: JsonNode): JsonNode {
    match ((target, result)) {
        case (targetObject: JsonObjectValue, resultObject: JsonObjectValue) =>
            targetObject.entries().clear()
            for ((key, value) in resultObject.entries()) { targetObject.put(key, value) }
            targetObject
        case (targetArray: JsonArrayValue, resultArray: JsonArrayValue) =>
            targetArray.values().clear()
            for (value in resultArray.values()) { targetArray.add(value) }
            targetArray
        case _ => result
    }
}

func deepCopyJsonNode(value: JsonNode): JsonNode {
    match (value) {
        case _: JsonNullValue => JsonNullValue()
        case boolValue: JsonBoolValue => JsonBoolValue(boolValue.value)
        case intValue: JsonIntValue => JsonIntValue(intValue.value)
        case floatValue: JsonFloatValue => JsonFloatValue(floatValue.value)
        case numberValue: JsonNumberLiteralValue => JsonNumberLiteralValue(numberValue.literal)
        case stringValue: JsonStringValue => JsonStringValue(stringValue.value)
        case arrayValue: JsonArrayValue =>
            let result = JsonArrayValue()
            for (item in arrayValue.values()) { result.add(deepCopyJsonNode(item)) }
            result
        case objectValue: JsonObjectValue =>
            let result = JsonObjectValue()
            for ((key, item) in objectValue.entries()) { result.put(key, deepCopyJsonNode(item)) }
            result
        case _ => throw JsonException("Unsupported JsonNode implementation", code: "json_node_type")
    }
}

func jsonNodesEquivalent(left: JsonNode, right: JsonNode): Bool {
    match ((left, right)) {
        case (_: JsonNullValue, _: JsonNullValue) => true
        case (a: JsonBoolValue, b: JsonBoolValue) => a.value == b.value
        case (a: JsonStringValue, b: JsonStringValue) => a.value == b.value
        case (a: JsonArrayValue, b: JsonArrayValue) =>
            if (a.size() != b.size()) { return false }
            for (index in 0..a.size()) {
                if (!jsonNodesEquivalent(a[index], b[index])) { return false }
            }
            true
        case (a: JsonObjectValue, b: JsonObjectValue) =>
            if (a.size() != b.size()) { return false }
            for ((key, value) in a.entries()) {
                match (b.get(key)) {
                    case Some(other) => if (!jsonNodesEquivalent(value, other)) { return false }
                    case None => return false
                }
            }
            true
        case _ => jsonNumbersEquivalent(left, right)
    }
}

private func jsonNumbersEquivalent(left: JsonNode, right: JsonNode): Bool {
    match ((jsonNodeAsDecimal(left), jsonNodeAsDecimal(right))) {
        case (Some(a), Some(b)) => a == b
        case _ => false
    }
}

func jsonNodeAsDecimal(value: JsonNode): Option<Decimal> {
    try {
        match (value) {
            case intValue: JsonIntValue => Some(Decimal(intValue.value))
            case floatValue: JsonFloatValue => Some(Decimal.parse(floatValue.value.toString()))
            case numberValue: JsonNumberLiteralValue => Some(Decimal.parse(numberValue.literal))
            case _ => None<Decimal>
        }
    } catch (_: Exception) {
        None<Decimal>
    }
}
