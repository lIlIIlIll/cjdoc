import std.ast.*

func dumpCase(name: String, source: String): Unit {
    println("case=${name}")
    let tokens = cangjieLex(source)
    for (token in tokens) {
        println("kind=${token.kind}")
        println("value.begin")
        println(token.value)
        println("value.end")
        println("position=${token.pos.fileID}:${token.pos.line}:${token.pos.column}")
    }
}

main(): Int64 {
    dumpCase("lf", "/**\n * foo\n */\npublic func foo(x: String): Int64 {\n    return 0\n}\n")
    dumpCase("unicode", "/** 中文 */\npublic func 解析(文本: String): String { 文本 }\n")
    dumpCase("crlf", "/**\r\n * foo\r\n */\r\npublic func foo(): Unit {}\r\n")
    return 0
}
