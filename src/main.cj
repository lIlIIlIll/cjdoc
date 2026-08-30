package cjdoc

main(args: Array<String>): Int64 {
    if (args.size == 2 && args[0] == "--internal-ast-preflight") {
        return runAstParsePreflight(args[1])
    }
    runCli(args)
}
