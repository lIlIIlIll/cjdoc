import std.ast.*
import std.collection.ArrayList

class DeclarationVisitor <: Visitor {
    func emit(kind: String, decl: Decl): Unit {
        println("${kind}|${decl.identifier.value}|${decl.beginPos.line}:${decl.beginPos.column}|${decl.endPos.line}:${decl.endPos.column}")
    }

    func emitSuperTypes(owner: String, superTypes: ArrayList<TypeNode>): Unit {
        for (superType in superTypes) {
            println("relationship|${owner}|superType|${superType.toTokens().toString()}")
        }
    }

    public override func visit(decl: ClassDecl): Unit {
        emit("class", decl)
        emitSuperTypes(decl.identifier.value, decl.superTypes)
    }
    public override func visit(decl: StructDecl): Unit {
        emit("struct", decl)
        emitSuperTypes(decl.identifier.value, decl.superTypes)
    }
    public override func visit(decl: InterfaceDecl): Unit {
        emit("interface", decl)
        emitSuperTypes(decl.identifier.value, decl.superTypes)
    }
    public override func visit(decl: EnumDecl): Unit {
        emit("enum", decl)
        for (constructor in decl.constructors) {
            println("enum-case|${constructor.identifier.value}|${constructor.beginPos.line}:${constructor.beginPos.column}|${constructor.endPos.line}:${constructor.endPos.column}|identifier=${constructor.identifier.pos.line}:${constructor.identifier.pos.column}|types=${constructor.typeArguments.size}|tokens=${constructor.toTokens().toString()}")
            for (token in constructor.toTokens()) {
                println("enum-case-token|${token.kind}|${token.value}|${token.pos.line}:${token.pos.column}")
            }
        }
    }
    public override func visit(decl: ExtendDecl): Unit {
        println("extend|${decl.extendType.toTokens().toString()}|${decl.beginPos.line}:${decl.beginPos.column}|${decl.endPos.line}:${decl.endPos.column}")
        println("relationship|extend|extensionTarget|${decl.extendType.toTokens().toString()}")
        emitSuperTypes("extend", decl.superTypes)
    }
    public override func visit(decl: FuncDecl): Unit { emit("func", decl) }
    public override func visit(decl: PropDecl): Unit { emit("prop", decl) }
    public override func visit(decl: PrimaryCtorDecl): Unit { emit("primary-constructor", decl) }
    public override func visit(decl: TypeAliasDecl): Unit { emit("type-alias", decl) }
}

main(): Int64 {
    let source = "package probe.ast\n" +
        "public interface Reader { func read(): Int64 }\n" +
        "public class Parser<T> <: Reader {\n" +
        "    public let value: T\n" +
        "    public init(value: T) { this.value = value }\n" +
        "    public func read(): Int64 { 0 }\n" +
        "    public func parse<U>(text: String): T { value }\n" +
        "    public prop count: Int64 { get() { 0 } }\n" +
        "}\n" +
        "public struct Box<T> <: Reader { public let value: T }\n" +
        "public enum Status { Ready | Failed(String) }\n" +
        "public class Point { public Point(public let x: Int64, public let y: Int64) {} }\n" +
        "extend Parser<String> <: Reader { public func pretty(): String { value } }\n" +
        "public type Name = String\n"
    let program = parseProgram(cangjieLex(source))
    program.traverse(DeclarationVisitor())
    return 0
}
