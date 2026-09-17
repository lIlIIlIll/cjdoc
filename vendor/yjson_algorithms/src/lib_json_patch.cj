package yjson_algorithms

import yjson.*

import std.collection.*
import std.deriving.Derive
import std.math.numeric.*

private func jsonPatchError(message: String, operationIndex!: Int64 = -1,
    code!: String = "invalid_json_patch", path!: String = ""): JsonException {
    let resolvedPath = if (!path.isEmpty() || operationIndex < 0) { path }
        else { "/${operationIndex}" }
    JsonException(message, code: code, path: resolvedPath)
}

@Derive[Equatable]
public enum JsonPatchOperationKind <: ToString {
    Add | Remove | Replace | Move | Copy | Test

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
        config!: JsonReadOptions = JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)): JsonPatch {
        fromValue(JsonNode.parse(text, config: config))
    }

    public static func fromValue(value: JsonValueView): JsonPatch {
        if (value.kind() != JsonKind.Array) {
            throw JsonException("JSON Patch document must be an array", code: "invalid_json_patch")
        }
        let operations = ArrayList<JsonPatchOperation>(value.size())
        for (index in 0..value.size()) {
            operations.add(parseJsonPatchOperation(value.element(index).getOrThrow().materialize(), index))
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

    /**
     * Applies atomically to a detached copy. The input is never changed.
     */
    public func apply(target: JsonValueView, limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        enforceWorkLimit(patchOperations.size, limits.maxOperations, "patch operations")
        for (operation in patchOperations) {
            enforceWorkLimit(operation.path.rawTokens().size, limits.maxPointerSegments, "pointer segments")
            if (let Some(source) <- operation.source) {
                enforceWorkLimit(source.rawTokens().size, limits.maxPointerSegments, "pointer segments")
            }
        }
        let copyWork = JsonPatchCopyWork(limits.maxCopiedNodes)
        copyWork.charge(target)
        applyJsonPatchOperations(target.materialize(), patchOperations, copyWork)
    }

    /**
     * Applies atomically and commits into the original root container when
     * its kind is unchanged. Callers must always use the returned root.
     */
    public func applyInPlace(target: JsonNode,
        limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        let result = apply(target, limits: limits)
        commitJsonRoot(target, result)
    }
}

public class JsonMergePatch {
    public static func apply(target: JsonValueView, patch: JsonValueView,
        limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        enforceWorkLimit(jsonPatchNodeCount(target) + jsonPatchNodeCount(patch),
            limits.maxCopiedNodes, "copied nodes")
        let result = applyJsonMergePatch(target.materialize(), patch.materialize())
        enforceWorkLimit(jsonPatchNodeCount(result), limits.maxCopiedNodes, "copied nodes")
        result
    }

    public static func applyInPlace(target: JsonNode, patch: JsonNode,
        limits!: JsonPatchLimits = JsonPatchLimits.defaults): JsonNode {
        commitJsonRoot(target, apply(target, patch, limits: limits))
    }
}

private func jsonPatchNodeCount(value: JsonValueView): Int64 {
    match (value.kind()) {
        case JsonKind.Array =>
            var total: Int64 = 1
            for (index in 0..value.size()) {
                total += jsonPatchNodeCount(value.element(index).getOrThrow())
            }
            total
        case JsonKind.Object =>
            var total: Int64 = 1
            for (index in 0..value.size()) { total += jsonPatchNodeCount(value.memberValue(index)) }
            total
        case _ => 1
    }
}

private class JsonPatchCopyWork {
    private let limit: Int64
    private var copiedNodes: Int64 = 0

    init(limit: Int64) { this.limit = limit }

    func charge(value: JsonValueView): Unit {
        let count = jsonPatchNodeCount(value)
        if (limit > 0 && (count > limit || copiedNodes > limit - count)) {
            throw JsonException(
                "JSON algorithm copied nodes budget exceeded: limit=${limit}, consumed=${copiedNodes + count}",
                code: "work_limit_exceeded")
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
        case _ => throw jsonPatchError("Unknown JSON Patch operation '${opText}'", operationIndex: index)
    }
    let source = match (objectValue.get("from")) {
        case Some(fromValue) => Some(JsonPointer.parse(fromValue.asString()))
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

private func requireJsonPatchString(objectValue: JsonObject, name: String, index: Int64): String {
    objectValue.get(name).getOrThrow({ =>
        jsonPatchError("JSON Patch operation ${index} is missing '${name}'", operationIndex: index)
    }).asString()
}

private func validateJsonPatchOperation(operation: JsonPatchOperation, index: Int64): Unit {
    match (operation.kind) {
        case Add | Replace | Test =>
            if (operation.value.isNone()) {
                throw jsonPatchError("JSON Patch '${operation.kind}' requires 'value'", operationIndex: index)
            }
        case Move | Copy =>
            if (operation.source.isNone()) {
                throw jsonPatchError("JSON Patch '${operation.kind}' requires 'from'", operationIndex: index)
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
        } catch (error: JsonException) {
            if (error.code == "work_limit_exceeded") { throw error }
            let code = if (error.code.startsWith("json_patch")) { error.code } else { "json_patch_path" }
            throw jsonPatchError(error.message, operationIndex: index,
                code: code, path: error.path)
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
            let copied = sourceValue.materialize()
            copyWork.charge(copied)
            jsonPatchAdd(root, operation.path, copied)
        case Move => jsonPatchMove(root, operation.source.getOrThrow(), operation.path)
        case Test =>
            let expected = operation.value.getOrThrow()
            copyWork.charge(expected)
            let actual = operation.path.evaluate(root)
            if (!jsonNodesEquivalent(actual, expected)) {
                throw jsonPatchError("JSON Patch test operation failed", code: "json_patch_test_failed",
                    path: operation.path.toString())
            }
            root
    }
}

private func jsonPatchAdd(root: JsonNode, pointer: JsonPointer, value: JsonNode): JsonNode {
    if (pointer.isRoot()) { return value }
    let (parent, token) = jsonPointerParent(root, pointer)
    match (parent) {
        case objectValue: JsonObject => objectValue.put(token, value); root
        case arrayValue: JsonArray =>
            let index = parseJsonPointerArrayIndex(token, arrayValue.size(), true).getOrThrow({ =>
                jsonPointerError("Invalid JSON Patch add array index '${token}'", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            arrayValue.insert(index, value)
            root
        case _ => throw jsonPointerError("JSON Patch add parent is not a container", pointer.toString(),
            code: "json_pointer_not_found")
    }
}

private func jsonPatchRemove(root: JsonNode, pointer: JsonPointer): (JsonNode, JsonNode) {
    if (pointer.isRoot()) {
        throw jsonPatchError("Removing the complete JSON document has no JsonNode result",
            code: "json_patch_path", path: pointer.toString())
    }
    let (parent, token) = jsonPointerParent(root, pointer)
    match (parent) {
        case objectValue: JsonObject =>
            let removed = objectValue.remove(token).getOrThrow({ =>
                jsonPointerError("JSON Patch remove target does not exist", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            (root, removed)
        case arrayValue: JsonArray =>
            let index = parseJsonPointerArrayIndex(token, arrayValue.size(), false).getOrThrow({ =>
                jsonPointerError("Invalid JSON Patch remove array index '${token}'", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            (root, arrayValue.removeAt(index))
        case _ => throw jsonPointerError("JSON Patch remove parent is not a container", pointer.toString(),
            code: "json_pointer_not_found")
    }
}

private func jsonPatchReplace(root: JsonNode, pointer: JsonPointer, value: JsonNode): JsonNode {
    if (pointer.isRoot()) { return value }
    let _ = pointer.evaluate(root)
    let (parent, token) = jsonPointerParent(root, pointer)
    match (parent) {
        case objectValue: JsonObject => objectValue.put(token, value); root
        case arrayValue: JsonArray =>
            let index = parseJsonPointerArrayIndex(token, arrayValue.size(), false).getOrThrow({ =>
                jsonPointerError("Invalid JSON Patch replace array index '${token}'", pointer.toString(),
                    code: "json_pointer_not_found")
            })
            arrayValue.set(index, value)
            root
        case _ => throw jsonPointerError("JSON Patch replace parent is not a container", pointer.toString(),
            code: "json_pointer_not_found")
    }
}

private func jsonPatchMove(root: JsonNode, source: JsonPointer, destination: JsonPointer): JsonNode {
    if (source.toString() == destination.toString()) { return root }
    if (!source.isRoot() && destination.toString().startsWith(source.toString() + "/")) {
        throw jsonPatchError("JSON Patch move destination is inside the source", code: "json_patch_path",
            path: destination.toString())
    }
    if (source.isRoot()) {
        if (destination.isRoot()) { return root }
        throw jsonPatchError("Cannot move the document root into one of its descendants",
            code: "json_patch_path", path: destination.toString())
    }
    let (withoutSource, moved) = jsonPatchRemove(root, source)
    jsonPatchAdd(withoutSource, destination, moved)
}

private func applyJsonMergePatch(target: JsonNode, patch: JsonNode): JsonNode {
    match (patch) {
        case patchObject: JsonObject =>
            let targetObject = match (target) {
                case objectValue: JsonObject => objectValue
                case _ => JsonObject()
            }
            for (index in 0..patchObject.size()) {
                let name = patchObject.nameAt(index)
                let patchValue = patchObject.valueAt(index)
                if (patchValue.isNull) {
                    let _ = targetObject.remove(name)
                } else {
                    let current = match (targetObject.get(name)) {
                        case Some(value) => value
                        case None => JsonNode.nullValue
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
        case (targetObject: JsonObject, resultObject: JsonObject) =>
            while (targetObject.size() > 0) {
                let _ = targetObject.remove(targetObject.nameAt(targetObject.size() - 1))
            }
            for (index in 0..resultObject.size()) {
                targetObject.put(resultObject.nameAt(index), resultObject.valueAt(index))
            }
            targetObject
        case (targetArray: JsonArray, resultArray: JsonArray) =>
            while (targetArray.size() > 0) { let _ = targetArray.removeAt(targetArray.size() - 1) }
            for (index in 0..resultArray.size()) { targetArray.add(resultArray[index]) }
            targetArray
        case _ => result
    }
}

func deepCopyJsonNode(value: JsonNode): JsonNode {
    value.materialize()
}

func jsonNodesEquivalent(left: JsonValueView, right: JsonValueView): Bool {
    if (left.kind() != right.kind()) { return false }
    match (left.kind()) {
        case JsonKind.Null => true
        case JsonKind.Boolean => left.asBool() == right.asBool()
        case JsonKind.String => left.asString() == right.asString()
        case JsonKind.Number => jsonNumbersEquivalent(left, right)
        case JsonKind.Array =>
            if (left.size() != right.size()) { return false }
            for (index in 0..left.size()) {
                if (!jsonNodesEquivalent(left.element(index).getOrThrow(),
                    right.element(index).getOrThrow())) { return false }
            }
            true
        case JsonKind.Object =>
            if (left.size() != right.size()) { return false }
            for (index in 0..left.size()) {
                let key = left.memberName(index)
                match (right.member(key)) {
                    case Some(other) => if (!jsonNodesEquivalent(left.memberValue(index), other)) { return false }
                    case None => return false
                }
            }
            true
    }
}

private func jsonNumbersEquivalent(left: JsonValueView, right: JsonValueView): Bool {
    match ((jsonNodeAsDecimal(left), jsonNodeAsDecimal(right))) {
        case (Some(a), Some(b)) => a == b
        case _ => false
    }
}

func jsonNodeAsDecimal(value: JsonValueView): Option<Decimal> {
    try {
        if (value.kind() == JsonKind.Number) { Some(Decimal.parse(value.asNumberText())) }
        else { None<Decimal> }
    } catch (_: Exception) {
        None<Decimal>
    }
}
