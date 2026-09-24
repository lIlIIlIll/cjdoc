package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.process.*

internal let SOURCE_PARSE_WORKER_PROTOCOL = "cjdoc-source-parse-worker/1"
internal func decodeParsedSource(input: SourceInputFile, cacheKey: String,
    bytes: Array<UInt8>, capturedSourceIndex: CapturedSourceIndex, capturedSource: String,
    maxItems!: Int64 = MAX_SOURCE_CACHE_ITEMS): ParsedSourceFile {
    let reader = SourceCacheReader(bytes, maxItems: maxItems)
    if (reader.next() != SOURCE_CACHE_FORMAT || reader.next() != cacheKey) {
        throw IllegalArgumentException("cache key mismatch")
    }
    let parsed = ParsedSourceFile(input)
    parsed.capturedSource = capturedSource
    parsed.packageName = cacheReadOptionalString(reader)
    cacheReadStrings(reader, parsed.imports)
    var count = checkedCacheCount(reader)
    var index: Int64 = 0
    while (index < count) {
        parsed.declarations.add(cacheReadDeclaration(reader, input.module.id))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.reExports.add(cacheReadReExport(reader, input.module.id))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.orphanDocComments.add(cacheReadOrphanDocComment(reader))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.macroInvocations.add(cacheReadMacroInvocation(reader))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.unsupportedDeclarations.add(cacheReadUnsupported(reader))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.diagnostics.add(cacheReadDiagnostic(reader))
        index++
    }
    let payloadEnd = reader.offset
    let expectedChecksum = reader.next()
    if (expectedChecksum != Sha256Digest.digestBytes(bytes[..payloadEnd])) {
        throw IllegalArgumentException("source cache checksum mismatch")
    }
    if (!reader.finished()) { throw IllegalArgumentException("trailing cache data") }
    validateDecodedSourceCache(parsed, capturedSourceIndex, capturedSource)
    parsed.cacheStatus = "hit"
    return parsed
}

internal func stableSourceCacheHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

internal func defaultSourceCacheFingerprint(): String {
    let identity = ToolchainIdentity()
    let sdkPath = match (getVariable("CANGJIE_HOME")) {
        case Some(value) => value
        case None => match (getVariable("CANGJIE_SDK_ROOT")) {
            case Some(value) => value
            case None => "unknown-sdk"
        }
    }
    let canonicalSdk = try { canonicalize(sdkPath).toString() } catch (_: Exception) { sdkPath }
    let compilerVersion = if (identity.compilerVersion != "unknown-cjc") {
        identity.compilerVersion
    } else {
        try {
            let (exitCode, output, _) = executeWithBoundedOutput("cjc", ["--version"])
            if (exitCode == 0) { String.fromUtf8(output).trimAscii() } else { "unknown-cjc" }
        } catch (_: Exception) {
            "unknown-cjc"
        }
    }
    "${identity.sourceBackendFingerprint()}\nsdk=${canonicalSdk}\ncjc=${compilerVersion}"
}
internal func makeSourceCacheKey(input: SourceInputFile, fallbackPackageName: String,
    source: String, fingerprint: String): ?String {
    let writer = SourceCacheWriter()
    writer.add(SOURCE_CACHE_FORMAT)
    writer.add(fingerprint)
    writer.add(input.logicalPath)
    writer.add(input.module.id)
    writer.add(fallbackPackageName)
    writer.add(source)
    match (writer.result()) {
        case Some(bytes) => Some(Sha256Digest.digestBytes(bytes))
        case None => None
    }
}

internal func sourceCachePath(directory: String, input: SourceInputFile,
    cacheKey: String): String {
    let pathHash = stableSourceCacheHash(input.logicalPath)
    let contentHash = stableSourceCacheHash(cacheKey)
    Path(directory).join("${pathHash}-${contentHash}.cache").toString()
}

internal func writeSourceCache(path: String, content: Array<UInt8>): Bool {
    if (content.size > MAX_SOURCE_CACHE_BYTES) { return false }
    let temporary = try {
        File.createTemp(Path(path).parent)
    } catch (_: Exception) {
        return false
    }
    let temporaryPath = try {
        temporary.info.path
    } catch (_: Exception) {
        try { temporary.close() } catch (_: Exception) {}
        return false
    }
    var closed = false
    var succeeded = false
    try {
        temporary.write(content)
        let written = temporary.info
        if (!written.isRegular() || written.size != content.size ||
            written.size > MAX_SOURCE_CACHE_BYTES) {
            throw IllegalStateException("source cache write did not produce a bounded regular file")
        }
        temporary.close()
        closed = true
        rename(temporaryPath, to: Path(path), overwrite: true)
        succeeded = true
    } catch (_: Exception) {
        succeeded = false
    } finally {
        if (!closed) { try { temporary.close() } catch (_: Exception) {} }
        try { let _ = removeIfExists(temporaryPath) } catch (_: Exception) {}
    }
    succeeded
}

internal func encodeAndWriteSourceCache(path: String, cacheKey: String,
    parsed: ParsedSourceFile, capturedSourceIndex: CapturedSourceIndex,
    capturedSource: String, auxiliaryBudget: SourceAuxiliaryBudget): Bool {
    if (auxiliaryBudget.limitReached()) { return false }
    match (encodeParsedSource(cacheKey, parsed, capturedSourceIndex, capturedSource)) {
        case Some(content) =>
            if (!auxiliaryBudget.consumeBytes(content.size)) { return false }
            writeSourceCache(path, content)
        case None => false
    }
}

internal func normalizeSourceNewlines(source: String): String {
    source.replace("\r\n", "\n").replace("\r", "\n")
}

internal func sourceParseWorkerFailure(input: SourceInputFile, code: String,
    message: String): ParsedSourceFile {
    let result = ParsedSourceFile(input)
    result.diagnostics.add(Diagnostic("error", code, message,
        source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
    result
}

internal func sourceParseWorkerCacheKey(source: String): String {
    Sha256Digest.digestBytes(source.toArray())
}

internal func writeSourceParseWorkerRequest(path: Path, sourcePath: Path, outputPath: Path,
    input: SourceInputFile, fallbackPackageName: String, sourceDigest: String): Unit {
    let writer = SourceCacheWriter(maxBytes: 1024 * 1024, maxItems: 128)
    writer.add(SOURCE_PARSE_WORKER_PROTOCOL)
    writer.add(sourcePath.toString())
    writer.add(outputPath.toString())
    writer.add(input.logicalPath)
    writer.add(input.module.id)
    writer.add(input.module.name)
    writer.add(fallbackPackageName)
    writer.add(sourceDigest)
    match (writer.result()) {
        case Some(bytes) => File.writeTo(path, bytes)
        case None => throw IllegalArgumentException("source parser worker request exceeds the safety limit")
    }
}

internal func sourceParseWorkerParse(input: SourceInputFile, fallbackPackageName: String,
    source: String, executable: String): ParsedSourceFile {
    let temporary = try {
        Directory.createTemp(getTempDirectory())
    } catch (_: Exception) {
        return sourceParseWorkerFailure(input, "CJDOC1020",
            "source parser worker is unavailable; file skipped")
    }
    let sourceDigest = sourceParseWorkerCacheKey(source)
    try {
        let sourcePath = temporary.join("source.cj")
        let requestPath = temporary.join("request.bin")
        let outputPath = temporary.join("response.bin")
        File.writeTo(sourcePath, source.toArray())
        writeSourceParseWorkerRequest(requestPath, sourcePath, outputPath, input,
            fallbackPackageName, sourceDigest)
        let workerPath = try { canonicalize(Path(executable)).toString() } catch (_: Exception) { executable }
        let (status, _, _) = executeWithBoundedOutput(workerPath,
            ["--internal-source-parse", requestPath.toString()])
        if (status != 0) {
            if (hasDeepSourceBinaryExpression(source)) {
                return sourceParseWorkerFailure(input, "CJDOC1012",
                    "source expression exceeds the safe std.ast binary-expression depth; file skipped")
            }
            return sourceParseWorkerFailure(input, "CJDOC1011",
                "std.ast parser rejected the source; file skipped")
        }
        let response = readFileBounded(outputPath, MAX_SOURCE_CACHE_BYTES)
        let capturedSourceIndex = CapturedSourceIndex(source)
        let parsed = decodeParsedSource(input, sourceDigest, response,
            capturedSourceIndex, source)
        parsed.cacheStatus = "worker"
        return parsed
    } catch (_: Exception) {
        return sourceParseWorkerFailure(input, "CJDOC1020",
            "source parser worker returned an invalid response; file skipped")
    } finally {
        let _ = removeIfExists(temporary, recursive: true)
    }
}

internal func runSourceParseWorker(requestPath: String): Int64 {
    try {
        let requestInfo = FileInfo(requestPath)
        if (!requestInfo.isRegular() || requestInfo.isSymbolicLink() || requestInfo.size < 0 ||
            requestInfo.size > 1024 * 1024) { return 2 }
        let requestRoot = canonicalize(Path(requestPath).parent).toString()
        let reader = SourceCacheReader(readFileBounded(Path(requestPath), 1024 * 1024),
            maxItems: 128)
        if (reader.next() != SOURCE_PARSE_WORKER_PROTOCOL) { return 2 }
        let sourcePath = reader.next()
        let outputPath = reader.next()
        let logicalPath = reader.next()
        let moduleId = reader.next()
        let moduleName = reader.next()
        let fallbackPackageName = reader.next()
        let sourceDigest = reader.next()
        if (!reader.finished()) { return 2 }
        let canonicalSource = canonicalize(Path(sourcePath)).toString()
        let canonicalOutput = Path(outputPath).toString()
        if (!hostPathIsWithin(requestRoot, canonicalSource) ||
            !hostPathIsWithin(requestRoot, canonicalOutput)) { return 2 }
        let sourceInfo = FileInfo(canonicalSource)
        if (!sourceInfo.isRegular() || sourceInfo.isSymbolicLink() ||
            sourceInfo.size < 0 || sourceInfo.size > MAX_SOURCE_FILE_BYTES) { return 2 }
        let source = normalizeSourceNewlines(readTextBounded(Path(canonicalSource),
            MAX_SOURCE_FILE_BYTES))
        if (sourceParseWorkerCacheKey(source) != sourceDigest) { return 2 }
        let module = SourceModule(moduleId, moduleName, "root", "")
        let input = SourceInputFile(canonicalSource, requestRoot, logicalPath, module,
            sourceInfo.size)
        let parsed = parseSourceTextWithAst(input, fallbackPackageName, source)
        let encoded = encodeParsedSource(sourceDigest, parsed, CapturedSourceIndex(source), source)
        match (encoded) {
            case Some(bytes) => File.writeTo(Path(canonicalOutput), bytes)
            case None => return 2
        }
        0
    } catch (_: Exception) {
        2
    }
}

internal func parseSourceFrontend(input: SourceInputFile, fallbackPackageName: String,
    source: String, astPreflightExecutable: ?String): ParsedSourceFile {
    let parsed = match (astPreflightExecutable) {
        case Some(executable) =>
            if (!executable.isEmpty()) {
                sourceParseWorkerParse(input, fallbackPackageName, source, executable)
            } else {
                parseSourceTextWithAst(input, fallbackPackageName, source)
            }
        case _ => parseSourceTextWithAst(input, fallbackPackageName, source)
    }
    parsed.capturedSource = source
    parsed
}

internal func parseSourceInput(input: SourceInputFile, fallbackPackageName: String,
    cacheDirectory: ?String, cacheFingerprint: String,
    astPreflightExecutable: ?String, auxiliaryBudget: SourceAuxiliaryBudget): ParsedSourceFile {
    try {
        let inputInfo = FileInfo(input.actualPath)
        if (inputInfo.isRegular() && !inputInfo.isSymbolicLink() &&
            inputInfo.size > MAX_SOURCE_FILE_BYTES) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1026",
                "source file exceeds the 32 MiB safety limit; file skipped",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
        if (!inputInfo.isRegular() || inputInfo.isSymbolicLink() || inputInfo.size < 0 ||
            inputInfo.size != input.discoveredSize) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1011",
                "failed to parse '${input.logicalPath}'",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
    } catch (_: Exception) {
        // The normal read path below reports inaccessible or disappearing files.
    }
    let source = try {
        normalizeSourceNewlines(readTextBounded(Path(input.actualPath), MAX_SOURCE_FILE_BYTES))
    } catch (_: Exception) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1011",
            "failed to parse '${input.logicalPath}'",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    let capturedSourceIndex = CapturedSourceIndex(source)
    if (!capturedSourceIndex.available) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1028",
            "source exceeds the ${MAX_CAPTURED_SOURCE_LINES}-line indexing limit; file skipped",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    match (cacheDirectory) {
        case None => return withCapturedSourceIndex(
            parseSourceFrontend(input, fallbackPackageName, source, astPreflightExecutable),
            capturedSourceIndex)
        case Some(directory) =>
            if (auxiliaryBudget.limitReached() || !auxiliaryBudget.consumeWork(source.size)) {
                let parsed = parseSourceFrontend(input, fallbackPackageName, source,
                    astPreflightExecutable)
                parsed.diagnostics.add(Diagnostic("error", "CJDOC1028",
                    "source metadata or cache exceeded the configured aggregate byte/work safety budget; remaining cache work skipped"))
                parsed.cacheStatus = "miss-write-failed"
                return withCapturedSourceIndex(parsed, capturedSourceIndex)
            }
            let cacheKeyValue = makeSourceCacheKey(input, fallbackPackageName, source, cacheFingerprint)
            if (cacheKeyValue.isNone()) {
                let parsed = parseSourceFrontend(input, fallbackPackageName, source,
                    astPreflightExecutable)
                parsed.cacheStatus = "miss-write-failed"
                return withCapturedSourceIndex(parsed, capturedSourceIndex)
            }
            let cacheKey = cacheKeyValue.getOrThrow()
            let path = sourceCachePath(directory, input, cacheKey)
            if (exists(path)) {
                try {
                    return withCapturedSourceIndex(decodeParsedSource(input, cacheKey,
                        readAuxiliaryFileBounded(Path(path), MAX_SOURCE_CACHE_BYTES,
                            auxiliaryBudget), capturedSourceIndex,
                        source),
                        capturedSourceIndex)
                } catch (_: Exception) {
                    let parsed = parseSourceFrontend(input, fallbackPackageName, source,
                        astPreflightExecutable)
                    if (auxiliaryBudget.limitReached()) {
                        parsed.diagnostics.add(Diagnostic("error", "CJDOC1028",
                            "source metadata or cache exceeded the configured aggregate byte/work safety budget; remaining cache work skipped"))
                        parsed.cacheStatus = "miss-write-failed"
                        return withCapturedSourceIndex(parsed, capturedSourceIndex)
                    }
                    parsed.cacheStatus = if (encodeAndWriteSourceCache(path, cacheKey, parsed,
                        capturedSourceIndex, source, auxiliaryBudget)) {
                        "corrupt-written"
                    } else {
                        "corrupt-write-failed"
                    }
                    return withCapturedSourceIndex(parsed, capturedSourceIndex)
                }
            }
            let parsed = parseSourceFrontend(input, fallbackPackageName, source,
                astPreflightExecutable)
            parsed.cacheStatus = if (encodeAndWriteSourceCache(path, cacheKey, parsed,
                capturedSourceIndex, source, auxiliaryBudget)) {
                "miss-written"
            } else {
                "miss-write-failed"
            }
            if (auxiliaryBudget.limitReached()) {
                parsed.diagnostics.add(Diagnostic("error", "CJDOC1028",
                    "source metadata or cache exceeded the configured aggregate byte/work safety budget; remaining cache work skipped"))
            }
            return withCapturedSourceIndex(parsed, capturedSourceIndex)
    }
}

internal func mergeParsedSource(sourceSnapshot: SourceSnapshot, parsed: ParsedSourceFile,
    cacheStats: SourceCacheStats, aggregation: SourceAggregationIndex): Unit {
    let packageName = match (parsed.packageName) {
        case Some(value) => value
        case None => parsed.input.module.name
    }
    sourceSnapshot.sourceFileOrigins.add(SourceFileOrigin(parsed.input.logicalPath,
        parsed.input.actualPath, parsed.input.actualRoot, parsed.input.module.sourcePrefix,
        capturedSourceIndex: parsed.capturedSourceIndex, packageName: packageName,
        imports: parsed.imports.toArray(), capturedSource: parsed.capturedSource))
    match (parsed.cacheStatus) {
        case "hit" => cacheStats.hits++
        case "miss-written" =>
            cacheStats.misses++
            cacheStats.writes++
        case "miss-write-failed" =>
            cacheStats.misses++
            cacheStats.writeFailures++
        case "corrupt-written" =>
            cacheStats.misses++
            cacheStats.corruptEntries++
            cacheStats.writes++
        case "corrupt-write-failed" =>
            cacheStats.misses++
            cacheStats.corruptEntries++
            cacheStats.writeFailures++
        case _ => ()
    }
    if (let Some(packageName) <- parsed.packageName) {
        aggregation.add(sourceSnapshot, parsed.input, packageName)
    }
    sourceSnapshot.declarations.add(all: parsed.declarations)
    sourceSnapshot.reExports.add(all: parsed.reExports)
    sourceSnapshot.orphanDocComments.add(all: parsed.orphanDocComments)
    sourceSnapshot.macroInvocations.add(all: parsed.macroInvocations)
    sourceSnapshot.unsupportedDeclarations.add(all: parsed.unsupportedDeclarations)
    for (diagnostic in parsed.diagnostics) {
        if (diagnostic.code == "CJDOC1028") {
            addSourceLimitDiagnostic(sourceSnapshot.diagnostics, diagnostic.message)
        } else {
            sourceSnapshot.diagnostics.add(diagnostic)
        }
    }
}

internal func parseAllSourceFiles(sourceSnapshot: SourceSnapshot, files: ArrayList<SourceInputFile>,
    jobs: Int64, cacheDirectory: ?String, cacheFingerprint: String,
    cacheStats: SourceCacheStats, astPreflightExecutable: ?String,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    let aggregation = SourceAggregationIndex()
    if (jobs <= 1 || files.size <= 1) {
        for (input in files) {
            mergeParsedSource(sourceSnapshot,
                parseSourceInput(input, input.module.name, cacheDirectory, cacheFingerprint,
                    astPreflightExecutable, auxiliaryBudget),
                cacheStats, aggregation)
        }
        return
    }
    var start: Int64 = 0
    while (start < files.size) {
        let futures = ArrayList<Future<ParsedSourceFile>>()
        let end = if (start + jobs < files.size) { start + jobs } else { files.size }
        var index = start
        while (index < end) {
            let input = files[index]
            let fallbackPackageName = input.module.name
            futures.add(spawn {
                parseSourceInput(input, fallbackPackageName, cacheDirectory, cacheFingerprint,
                    astPreflightExecutable, auxiliaryBudget)
            })
            index++
        }
        for (future in futures) {
            mergeParsedSource(sourceSnapshot, future.get(), cacheStats, aggregation)
        }
        start = end
    }
}
