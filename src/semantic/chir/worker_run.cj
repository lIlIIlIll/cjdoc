protected package cjdoc.semantic.chir

import cjdoc.source.model.SourceFileOrigin
import cjdoc.filesystem.readTextBounded
import cjdoc.process.executeWithBoundedOutput
import cjdoc_chir_protocol.*
import std.collection.*
import std.env.*
import std.fs.*

// One worker invocation for one package. The call either completed (decoded
// summary plus the retained artifact root dependents import from) or the worker
// itself reported a failure the factory turns into a package diagnostic.
// Staging and decode errors are deliberately not caught here: they propagate to
// the factory, which reports them in its own established form.
internal enum ChirWorkerRunOutcome {
    | Completed(ChirWorkerSummary, String)
    | Failed(String)
}

// The private staging directory is handed to the caller's retention list as soon
// as it exists, so a partly staged failure is still cleaned up by dispose.
internal func chirRunWorker(workerPath: String, compiler: String, moduleName: String,
    packageName: String, origins: Array<SourceFileOrigin>, importPaths: ArrayList<String>,
    cfgValues: ArrayList<String>, compilerOptions: ArrayList<String>,
    retainedDirectories: ArrayList<Path>): ChirWorkerRunOutcome {
    let temporary = try {
        Directory.createTemp(getTempDirectory())
    } catch (_: Exception) {
        return ChirWorkerRunOutcome.Failed("private CHIR directory could not be created")
    }
    retainedDirectories.add(temporary)
    let sourcePaths = ArrayList<String>()
    var index: Int64 = 0
    for (origin in origins) {
        let staged = temporary.join("source-${index}.cj")
        File.writeTo(staged, origin.capturedSource.toArray())
        sourcePaths.add(staged.toString())
        index++
    }
    let request = temporary.join("request.txt")
    let response = temporary.join("response.txt")
    writeChirWorkerRequest(request, compiler, moduleName, packageName, importPaths,
        cfgValues, sourcePaths, compilerOptions: compilerOptions.toArray())
    let (workerCode, stdout, stderr) = executeWithBoundedOutput(workerPath,
        ["--internal-chir-analyze", request.toString(), response.toString()],
        workingDirectory: Some(temporary))
    if (workerCode != 0) {
        return ChirWorkerRunOutcome.Failed(
            "CHIR worker failed: " + boundedChirCompilerOutput(stdout, stderr))
    }
    let summary = readChirWorkerResponse(readTextBounded(response, MAX_CHIR_RESPONSE_BYTES))
    if (summary.functionCount < 0 || summary.typeCount < 0 || summary.extendCount < 0) {
        return ChirWorkerRunOutcome.Failed("CHIR worker returned invalid declaration counts")
    }
    ChirWorkerRunOutcome.Completed(summary, temporary.join("chir-out").toString())
}

// Compiler stdout and stderr are bounded so a hostile or broken compiler cannot
// turn one failure into an unbounded diagnostic.
internal func boundedChirCompilerOutput(stdout: Array<Byte>, stderr: Array<Byte>): String {
    let out = try { String.fromUtf8(stdout).trimAscii() } catch (_: Exception) { "" }
    let err = try { String.fromUtf8(stderr).trimAscii() } catch (_: Exception) { "" }
    let combined = if (out.isEmpty()) { err } else if (err.isEmpty()) { out } else { out + "\\n" + err }
    let bytes = combined.toArray()
    if (bytes.size <= 8192) { return combined }
    String.fromUtf8(bytes[..8192]) + "\\n... CHIR compiler output truncated"
}
