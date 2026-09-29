package cjdoc

main(args: Array<String>): Int64 {
    if (args.size == 2 && args[0] == "--internal-source-parse") {
        return runSourceParseWorker(args[1])
    }
    runCli(args)
}
