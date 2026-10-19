# Class

## class ArrayDeque\<T>

```cangjie
public class ArrayDeque<T> <: Deque<T> {
    public init()
    public init(capacity: Int64)
}
```

Function: ArrayDeque is an implementation class of a double-ended queue (deque), allowing insertion and deletion operations at both ends. ArrayDeque is implemented based on a resizable array, with its capacity continuously growing during element insertion, defaulting to a 50% expansion each time. The implementation of ArrayDeque adopts a circular queue approach, ensuring that insertion, deletion, and lookup operations have a time complexity of O(1) without expansion.

Parent Types:

- [Deque](./collection_package_interface.md#interface-dequet)\<T>

### prop capacity

```cangjie
public prop capacity: Int64
```

Function: Gets the capacity of this deque.

Type: [Int64](../../core/core_package_api/core_package_intrinsics.md#int64)
