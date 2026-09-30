import stdx.syntax.*

main() {
    let result = parseText("/** d */\npublic class C {}")
    if (let Some(node) <- result.node) {
        let tokens = node.toTokens()
        println("tokenCount=" + tokens.size.toString())
        for (token in tokens) {
            println(token.value + "|" + token.pos.line.toString() + ":" + token.pos.column.toString() + "|" + token.kind.toString())
        }
    }
}
