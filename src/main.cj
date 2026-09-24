package cjdoc

main(args: Array<String>): Int64 {
    if (args.size == 2 && args[0] == "--internal-source-parse") {
        return runSourceParseWorker(args[1])
    }
    if (args.size == 3 && args[0] == "--internal-chir-analyze") {
        return runChirAnalyzeWorker(args[1], args[2])
    }
    runCli(args)
}
