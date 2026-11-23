protected package cjdoc.render.search

import cjdoc.render.codec.required
import yjson.*

// Strict structural matching against the subset of JSON schema that the
// published search contract uses for request fields.
private func searchJsonMatchesType(value: JsonNode, expected: String): Bool {
    match (expected) {
        case "string" => value.kind() == JsonKind.String
        case "array" => value.kind() == JsonKind.Array
        case "object" => try { let _ = value.asObject(); true } catch (_: Exception) { false }
        case "boolean" => try { let _ = value.asBool(); true } catch (_: Exception) { false }
        case "integer" => try { let _ = value.asInt64(); true } catch (_: Exception) { false }
        case "null" => value.kind() == JsonKind.Null
        case _ => false
    }
}

protected func searchJsonMatchesSchema(value: JsonNode, schemaNode: JsonNode): Bool {
    let schema = schemaNode.asObject()
    match (schema.get("type")) {
        case Some(typeNode) =>
            let matched = if (typeNode.kind() == JsonKind.Array) {
                var anyType = false
                let types = typeNode.asArray()
                for (index in 0..types.size()) {
                    if (searchJsonMatchesType(value, types[index].asString())) {
                        anyType = true
                        break
                    }
                }
                anyType
            } else { searchJsonMatchesType(value, typeNode.asString()) }
            if (!matched) { return false }
        case None => ()
    }
    match (schema.get("const")) {
        case Some(constant) => if (value.toJson() != constant.toJson()) { return false }
        case None => ()
    }
    match (schema.get("enum")) {
        case Some(enumNode) =>
            var found = false
            let values = enumNode.asArray()
            for (index in 0..values.size()) {
                if (value.toJson() == values[index].toJson()) { found = true; break }
            }
            if (!found) { return false }
        case None => ()
    }
    if (value.kind() == JsonKind.String) {
        let count = searchRuneCount(value.asString())
        match (schema.get("minLength")) {
            case Some(minimum) => if (count < minimum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("maxLength")) {
            case Some(maximum) => if (count > maximum.asInt64()) { return false }
            case None => ()
        }
    }
    if (searchJsonMatchesType(value, "integer")) {
        let number = value.asInt64()
        match (schema.get("minimum")) {
            case Some(minimum) => if (number < minimum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("maximum")) {
            case Some(maximum) => if (number > maximum.asInt64()) { return false }
            case None => ()
        }
    }
    if (value.kind() == JsonKind.Array) {
        let values = value.asArray()
        match (schema.get("minItems")) {
            case Some(minimum) => if (values.size() < minimum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("maxItems")) {
            case Some(maximum) => if (values.size() > maximum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("items")) {
            case Some(itemSchema) =>
                for (index in 0..values.size()) {
                    if (!searchJsonMatchesSchema(values[index], itemSchema)) { return false }
                }
            case None => ()
        }
    }
    if (searchJsonMatchesType(value, "object")) {
        let object = value.asObject()
        let properties: ?JsonObject = match (schema.get("properties")) {
            case Some(value) => Some(value.asObject())
            case None => Option<JsonObject>.None
        }
        let additionalProperties = match (schema.get("additionalProperties")) {
            case Some(value) => value.asBool()
            case None => true
        }
        for (index in 0..object.size()) {
            let key = object.nameAt(index)
            match (properties) {
                case Some(declared) =>
                    match (declared.get(key)) {
                        case Some(childSchema) =>
                            if (!searchJsonMatchesSchema(object.valueAt(index), childSchema)) {
                                return false
                            }
                        case None => if (!additionalProperties) { return false }
                    }
                case None => if (!additionalProperties) { return false }
            }
        }
        match (schema.get("required")) {
            case Some(required) =>
                let names = required.asArray()
                for (index in 0..names.size()) {
                    if (object.get(names[index].asString()).isNone()) { return false }
                }
            case None => ()
        }
    }
    true
}
