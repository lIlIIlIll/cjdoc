import std.collection.*
import std.sort.*

class Item {
    let key: String
    init(key: String) { this.key = key }
}

main(): Unit {
    let values = ArrayList<Item>()
    values.add(Item("b"))
    values.add(Item("a"))
    sort(values, lessThan: { left, right => left.key < right.key }, stable: true)

    let seen = HashSet<String>()
    println("${values[0].key}|${seen.add("id")}|${seen.contains("id")}|${seen.add("id")}")
}
