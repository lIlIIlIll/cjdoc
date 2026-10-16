# Classes

## class JsonArray

```cangjie
public class JsonArray <: JsonValue {
    public init()
    public init(list: ArrayList<JsonValue>)
    public init(list: Array<JsonValue>)
}
```

Functionality: This class is a subclass implementation of [JsonValue](encoding_json_package_classes.md#class-jsonvalue), primarily used for encapsulating array-type JSON data.

Parent Type:

- [JsonValue](#class-jsonvalue)

Example:

For usage examples, see [JsonArray Usage Samples](../json_samples/json_array_sample.md).

### init()

```cangjie
public init()
```

Functionality: Creates an empty [JsonArray](encoding_json_package_classes.md#class-jsonarray).

### init(ArrayList\<JsonValue>)

```cangjie
public init(list: ArrayList<JsonValue>)
```

Functionality: Encapsulates the specified ArrayList instance into a [JsonArray](encoding_json_package_classes.md#class-jsonarray) instance.

Parameters:

- list: ArrayList\<[JsonValue](encoding_json_package_classes.md#class-jsonvalue)> - The ArrayList used to create the [JsonArray](encoding_json_package_classes.md#class-jsonarray).

### init(Array\<JsonValue>)

```cangjie
public init(list: Array<JsonValue>)
```

Functionality: Encapsulates the specified Array instance into a [JsonArray](encoding_json_package_classes.md#class-jsonarray) instance.

Parameters:

- list: Array\<[JsonValue](encoding_json_package_classes.md#class-jsonvalue)> - The Array used to create the [JsonArray](encoding_json_package_classes.md#class-jsonarray).

### func add(JsonValue)

```cangjie
public func add(jv: JsonValue): JsonArray
```
