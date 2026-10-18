package highlight_host_fixture

import cjdoc.*
import cjdoc.render.*
import std.fs.*
import std.time.*

// Explicit optional-backend acceptance executable, not a default Node dependency.
// Arguments: project, cjdoc binary (AST preflight), Node, adapter, request audit.
main(args: Array<String>): Int64 {
    if (args.size != 5) { return 2 }
    let audit = Path(args[4])
    let started = MonoTime.now()
    let generation = spawn {
        DocumentationEngine().generate(GenerationRequest(args[0], lintProfile: "off",
            astPreflightExecutable: Some(args[1]), highlightAdapter: Some(args[3]),
            highlightNode: Some(args[2]),
            highlight: Some(HighlightConfig(languages: ["cangjie", "python"]))))
    }
    while (!exists(audit)) {
        if ((MonoTime.now() - started).toMilliseconds() > 10000) {
            generation.cancel()
            return 3
        }
        sleep(Duration.millisecond * 10)
    }
    // The authorized adapter creates the audit only after receiving a request.
    let cancelledAt = MonoTime.now()
    generation.cancel()
    let documentation = generation.get(Duration.second * 3)
    if ((MonoTime.now() - cancelledAt).toMilliseconds() >= 3000) { return 4 }
    let encoded = encodeDocIr(documentation)
    if (!encoded.contains("backend-unavailable")) {
        return 5
    }
    println("public Future cancellation returned within the three-second bound")
    0
}
