import std.ast.*
import std.fs.*

main(args: Array<String>): Int64 {
    if (args.size != 1) { return 2 }
    let source = String.fromUtf8(File.readFrom(args[0]))
    let _ = parseProgram(cangjieLex(source))
    return 0
}
