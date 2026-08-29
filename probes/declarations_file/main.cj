import std.ast.*
import std.fs.*

class RangeVisitor <: Visitor {
    public override func visit(decl: FuncDecl): Unit {
        println("func|${decl.identifier.value}|${decl.beginPos.line}:${decl.beginPos.column}|${decl.endPos.line}:${decl.endPos.column}")
    }

    public override func visit(decl: VarDecl): Unit {
        let name = try { decl.identifier.value } catch (_: Exception) { "<pattern>" }
        println("var|${name}|${decl.beginPos.line}:${decl.beginPos.column}|${decl.endPos.line}:${decl.endPos.column}")
    }
}

main(args: Array<String>): Int64 {
    let source = String.fromUtf8(File.readFrom(args[0]))
    parseProgram(cangjieLex(source)).traverse(RangeVisitor())
    return 0
}
