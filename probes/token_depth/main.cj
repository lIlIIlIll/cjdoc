import std.ast.*
import std.collection.*
import std.fs.*

func isBinaryOperator(value: String): Bool {
    match (value) {
        case "+" | "-" | "*" | "/" | "%" | "&&" | "||" | "==" | "!=" |
            "<" | ">" | "<=" | ">=" | "&" | "|" | "^" | "<<" | ">>" | "??" => true
        case _ => false
    }
}

main(args: Array<String>): Int64 {
    let tokens = cangjieLex(String.fromUtf8(File.readFrom(args[0])))
    let outerOperators = ArrayList<Int64>()
    var operators: Int64 = 0
    var maximum: Int64 = 0
    var maximumLine: Int64 = 0
    for (token in tokens) {
        if (isBinaryOperator(token.value)) {
            operators++
            if (operators > maximum) {
                maximum = operators
                maximumLine = Int64(token.pos.line)
            }
        } else {
            match (token.value) {
                case "(" =>
                    outerOperators.add(operators)
                    operators = 0
                case ")" =>
                    if (outerOperators.isEmpty()) {
                        operators = 0
                    } else {
                        operators = outerOperators[outerOperators.size - 1]
                        outerOperators.remove(at: outerOperators.size - 1)
                    }
                case "," => operators = 0
                case ";" | "{" | "}" | "=" | "let" | "var" | "return" =>
                    operators = 0
                    while (!outerOperators.isEmpty()) {
                        outerOperators.remove(at: outerOperators.size - 1)
                    }
                case _ => ()
            }
        }
    }
    println("${maximum}|${maximumLine}")
    return 0
}
