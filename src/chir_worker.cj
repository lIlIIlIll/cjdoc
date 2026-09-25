package cjdoc

import std.collection.*
import std.fs.*
import std.process.*
import stdx.chir.*

internal let CHIR_WORKER_PROTOCOL = "cjdoc-chir-worker/1"
internal let MAX_CHIR_REQUEST_BYTES: Int64 = 4 * 1024 * 1024
internal let MAX_CHIR_RESPONSE_BYTES: Int64 = 16 * 1024 * 1024
internal let MAX_CHIR_ARTIFACT_BYTES: Int64 = 128 * 1024 * 1024

internal class ChirWorkerFunctionRecord {
    public let packageName: String
    public let name: String
    public let ownerKind: String
    public let ownerPackageName: String
    public let ownerName: String
    public let targetPackageName: String
    public let targetName: String
    public let genericArity: Int64
    public let parameterCount: Int64

    init(packageName: String, name: String, ownerKind: String, ownerPackageName: String,
        ownerName: String, targetPackageName: String, targetName: String,
        genericArity: Int64, parameterCount: Int64) {
        this.packageName = packageName
        this.name = name
        this.ownerKind = ownerKind
        this.ownerPackageName = ownerPackageName
        this.ownerName = ownerName
        this.targetPackageName = targetPackageName
        this.targetName = targetName
        this.genericArity = genericArity
        this.parameterCount = parameterCount
    }
}

internal class ChirWorkerMemberRecord {
    public let packageName: String
    public let name: String
    public let ownerPackageName: String
    public let ownerName: String

    init(packageName: String, name: String, ownerPackageName: String, ownerName: String) {
        this.packageName = packageName
        this.name = name
        this.ownerPackageName = ownerPackageName
        this.ownerName = ownerName
    }
}

internal class ChirWorkerTypeRecord {
    public let packageName: String
    public let name: String

    init(packageName: String, name: String) {
        this.packageName = packageName
        this.name = name
    }
}

internal class ChirWorkerExtendRecord {
    public let packageName: String
    public let targetPackageName: String
    public let targetName: String

    init(packageName: String, targetPackageName: String, targetName: String) {
        this.packageName = packageName
        this.targetPackageName = targetPackageName
        this.targetName = targetName
    }
}
internal class ChirWorkerEnumCaseRecord {
    public let packageName: String
    public let ownerName: String
    public let name: String

    init(packageName: String, ownerName: String, name: String) {
        this.packageName = packageName
        this.ownerName = ownerName
        this.name = name
    }
}

internal class ChirWorkerSummary {
    public let functionRecords = ArrayList<ChirWorkerFunctionRecord>()
    public let memberRecords = ArrayList<ChirWorkerMemberRecord>()
    public let typeRecords = ArrayList<ChirWorkerTypeRecord>()
    public let extendRecords = ArrayList<ChirWorkerExtendRecord>()
    public let enumCaseRecords = ArrayList<ChirWorkerEnumCaseRecord>()
    public var functionCount: Int64 = 0
    public var typeCount: Int64 = 0
    public var extendCount: Int64 = 0
}

internal func writeChirWorkerRequest(path: Path, compiler: String, moduleName: String,
    packageName: String, importPaths: ReadOnlyList<String>, cfgValues: ReadOnlyList<String>,
    sourcePaths: ReadOnlyList<String>): Unit {
    let lines = ArrayList<String>()
    lines.add("protocol=${CHIR_WORKER_PROTOCOL}")
    lines.add("compiler=${compiler}")
    lines.add("module=${moduleName}")
    lines.add("package=${packageName}")
    for (pathValue in importPaths) { lines.add("import=${pathValue}") }
    for (cfgValue in cfgValues) { lines.add("cfg=${cfgValue}") }
    for (pathValue in sourcePaths) { lines.add("source=${pathValue}") }
    File.writeTo(path, chirWorkerLinesText(lines).toArray())
}

internal func readChirWorkerResponse(path: Path): ChirWorkerSummary {
    let text = readTextBounded(path, MAX_CHIR_RESPONSE_BYTES)
    let lines = text.split("\n")
    if (lines.isEmpty() || lines[0] != "protocol=${CHIR_WORKER_PROTOCOL}") {
        throw IllegalArgumentException("CHIR worker response protocol mismatch")
    }
    var status = ""
    var failure = ""
    var protocolSeen = false
    var statusSeen = false
    var errorSeen = false
    var functionsSeen = false
    var typesSeen = false
    var extendsSeen = false
    let summary = ChirWorkerSummary()
    for (line in lines) {
        if (line.isEmpty()) { continue }
        let parts = line.split("=", 2)
        if (parts.size < 2) {
            throw IllegalArgumentException("CHIR worker response line is malformed")
        }
        let key = parts[0]
        let value = parts[1]
        match (key) {
            case "protocol" =>
                if (protocolSeen) {
                    throw IllegalArgumentException("CHIR worker response protocol is duplicated")
                }
                protocolSeen = true
                if (value != CHIR_WORKER_PROTOCOL) {
                    throw IllegalArgumentException("CHIR worker response protocol mismatch")
                }
            case "status" =>
                if (statusSeen) { throw IllegalArgumentException("CHIR worker response status is duplicated") }
                statusSeen = true
                status = value
            case "error" =>
                if (errorSeen) { throw IllegalArgumentException("CHIR worker response error is duplicated") }
                errorSeen = true
                failure = value
            case "function" => summary.functionRecords.add(parseFunctionRecord(value))
            case "member" => summary.memberRecords.add(parseMemberRecord(value))
            case "type" => summary.typeRecords.add(parseTypeRecord(value))
            case "extend" => summary.extendRecords.add(parseExtendRecord(value))
            case "enumCase" => summary.enumCaseRecords.add(parseEnumCaseRecord(value))
            case "functions" =>
                if (functionsSeen) { throw IllegalArgumentException("CHIR worker response functions is duplicated") }
                functionsSeen = true
                summary.functionCount = parseWorkerCount(value)
            case "types" =>
                if (typesSeen) { throw IllegalArgumentException("CHIR worker response types is duplicated") }
                typesSeen = true
                summary.typeCount = parseWorkerCount(value)
            case "extends" =>
                if (extendsSeen) { throw IllegalArgumentException("CHIR worker response extends is duplicated") }
                extendsSeen = true
                summary.extendCount = parseWorkerCount(value)
            case _ => throw IllegalArgumentException("CHIR worker response contains unknown field")
        }
    }
    if (!protocolSeen || !statusSeen || !functionsSeen || !typesSeen || !extendsSeen) {
        throw IllegalArgumentException("CHIR worker response is incomplete")
    }
    if (status != "ok") {
        if (failure.isEmpty()) { failure = "worker did not produce a successful CHIR package" }
        throw IllegalArgumentException(failure)
    }
    summary
}

internal func runChirAnalyzeWorker(requestPath: String, responsePath: String): Int64 {
    let response = Path(responsePath)
    try {
        let request = Path(requestPath)
        validateChirWorkerFile(request)
        let root = request.parent
        let fields = readChirWorkerRequest(request)
        let compiler = requiredChirWorkerField(fields, "compiler")
        let moduleName = requiredChirWorkerField(fields, "module")
        let packageName = requiredChirWorkerField(fields, "package")
        let sources = chirWorkerFields(fields, "source")
        if (sources.isEmpty()) { throw IllegalArgumentException("CHIR worker source set is empty") }
        for (pathValue in sources) { validateChirWorkerStagedFile(root, Path(pathValue)) }
        let output = root.join("chir-out")
        Directory.create(output)
        let args = ArrayList<String>()
        args.add("--emit-chir=raw")
        args.add("--output-type"); args.add("staticlib")
        args.add("--module-name"); args.add(moduleName)
        args.add("--output-dir"); args.add(output.toString())
        args.add("-o"); args.add("package.chir")
        for (pathValue in chirWorkerFields(fields, "import")) {
            args.add("--import-path"); args.add(pathValue)
        }
        for (cfgValue in chirWorkerFields(fields, "cfg")) {
            args.add("--cfg"); args.add(cfgValue)
        }
        for (pathValue in sources) { args.add(pathValue) }
        let (exitCode, stdout, stderr) = try {
            executeWithBoundedOutput(compiler, args.toArray(), workingDirectory: Some(root))
        } catch (error: Exception) {
            writeChirWorkerFailure(response, "CJDOC2101: compiler is unavailable: " + error.message)
            return 0
        }
        if (exitCode != 0) {
            writeChirWorkerFailure(response, "CJDOC2103: compiler failed: " +
                boundedWorkerCompilerOutput(stdout, stderr))
            return 0
        }
        let artifact = output.join("package.chir")
        let info = FileInfo(artifact)
        if (!info.isRegular() || info.isSymbolicLink() || info.size <= 0) {
            writeChirWorkerFailure(response, "CJDOC2104: compiler produced no valid raw CHIR artifact")
            return 0
        }
        let bytes = readFileBounded(artifact, MAX_CHIR_ARTIFACT_BYTES)
        let summary = deserializeAndSummarizeChir(bytes, packageName)
        writeChirWorkerSuccess(response, summary)
        0
    } catch (error: Exception) {
        try { writeChirWorkerFailure(response, "CJDOC2104: " + error.message) } catch (_: Exception) {}
        1
    }
}

private func deserializeAndSummarizeChir(bytes: Array<Byte>, packageName: String): ChirWorkerSummary {
    unsafe {
        let handle = acquireArrayRawData(bytes)
        try {
            let chirPackage = deserializePackage(handle.pointer, bytes.size)
            let summary = ChirWorkerSummary()
            for (value in chirPackage.functions) {
                if (value.isCompilerAdd() || value.isImported() || value.packageName != packageName) { continue }
                summary.functionCount++
                if (value.srcCodeName.isEmpty()) { continue }
                var ownerKind = "none"
                var ownerPackageName = ""
                var ownerName = ""
                var targetPackageName = ""
                var targetName = ""
                match (value.declaredParent) {
                    case Some(owner) =>
                        match (owner) {
                            case extendDef: ExtendDef =>
                                ownerKind = "extend"
                                ownerPackageName = extendDef.packageName
                                let target = chirCustomTypeIdentity(extendDef.extendedType)
                                targetPackageName = target[0]
                                targetName = target[1]
                            case _ =>
                                ownerKind = "type"
                                ownerPackageName = owner.packageName
                                ownerName = owner.srcCodeName
                        }
                    case None => ()
                }
                summary.functionRecords.add(ChirWorkerFunctionRecord(
                    value.packageName, value.srcCodeName, ownerKind, ownerPackageName, ownerName,
                    targetPackageName, targetName, value.genericTypeParams.size,
                    value.funcSrcCodeType.paramTypes.size))
            }
            for (value in chirPackage.allCustomTypeDefs) {
                if (value.isImported() || value.packageName != packageName) { continue }
                match (value) {
                    case extendDef: ExtendDef =>
                        summary.extendCount++
                        let target = chirCustomTypeIdentity(extendDef.extendedType)
                        summary.extendRecords.add(ChirWorkerExtendRecord(
                            extendDef.packageName, target[0], target[1]))
                    case _ =>
                        summary.typeCount++
                        if (!value.srcCodeName.isEmpty()) {
                            summary.typeRecords.add(ChirWorkerTypeRecord(
                                value.packageName, value.srcCodeName))
                        }
                        match (value) {
                            case enumDef: EnumDef =>
                                for (ctor in enumDef.constructors) {
                                    if (!ctor.srcCodeName.isEmpty()) {
                                        summary.enumCaseRecords.add(ChirWorkerEnumCaseRecord(
                                            value.packageName, value.srcCodeName, ctor.srcCodeName))
                                    }
                                }
                            case _ => ()
                        }
                        for (member in value.instanceVars) {
                            if (!member.name.isEmpty()) {
                                summary.memberRecords.add(ChirWorkerMemberRecord(
                                    value.packageName, member.name, value.packageName,
                                    value.srcCodeName))
                            }
                        }
                        for (member in value.staticVars) {
                            if (!member.srcCodeName.isEmpty()) {
                                summary.memberRecords.add(ChirWorkerMemberRecord(
                                    value.packageName, member.srcCodeName, value.packageName,
                                    value.srcCodeName))
                            }
                        }
                }
            }
            for (value in chirPackage.globalVars) {
                if (value.isCompilerAdd() || value.isImported() ||
                    value.packageName != packageName || value.srcCodeName.isEmpty()) {
                    continue
                }
                let owner = match (value.declaredParent) {
                    case Some(parent) => (parent.packageName, parent.srcCodeName)
                    case None => ("", "")
                }
                summary.memberRecords.add(ChirWorkerMemberRecord(
                    value.packageName, value.srcCodeName, owner[0], owner[1]))
            }
            summary
        } finally {
            releaseArrayRawData(handle)
        }
    }
}

private func chirCustomTypeIdentity(value: Type): (String, String) {
    match (value) {
        case custom: CustomType => (custom.def.packageName, custom.def.srcCodeName)
        case _ => ("-", "-")
    }
}

private func readChirWorkerRequest(path: Path): HashMap<String, ArrayList<String>> {
    let fields = HashMap<String, ArrayList<String>>()
    let text = readTextBounded(path, MAX_CHIR_REQUEST_BYTES)
    let lines = text.split("\n")
    if (lines.isEmpty() || lines[0] != "protocol=${CHIR_WORKER_PROTOCOL}") {
        throw IllegalArgumentException("CHIR worker request protocol mismatch")
    }
    for (line in lines[1..]) {
        if (line.isEmpty()) { continue }
        let parts = line.split("=", 2)
        if (parts.size < 2) {
            throw IllegalArgumentException("CHIR worker request line is malformed")
        }
        let key = parts[0]
        let value = parts[1]
        match (key) {
            case "compiler" | "module" | "package" | "import" | "cfg" | "source" => ()
            case _ => throw IllegalArgumentException("CHIR worker request contains unknown field")
        }
        if (let Some(values) <- fields.get(key)) {
            values.add(value)
        } else {
            let values = ArrayList<String>()
            values.add(value)
            fields[key] = values
        }
    }
    fields
}


private func requiredChirWorkerField(fields: HashMap<String, ArrayList<String>>, key: String): String {
    match (fields.get(key)) {
        case Some(values) =>
            if (values.size != 1) {
                throw IllegalArgumentException("CHIR worker field '${key}' must occur exactly once")
            }
            if (values[0].isEmpty()) {
                throw IllegalArgumentException("CHIR worker field '${key}' is empty")
            }
            values[0]
        case None => throw IllegalArgumentException("CHIR worker field '${key}' is missing")
    }
}

private func chirWorkerFields(fields: HashMap<String, ArrayList<String>>, key: String): Array<String> {
    match (fields.get(key)) {
        case Some(values) => values.toArray()
        case None => []
    }
}

private func recordFields(value: String, count: Int64): Array<String> {
    let fields = value.split("\t")
    if (fields.size != count) {
        throw IllegalArgumentException("CHIR worker declaration record is malformed")
    }
    for (field in fields) {
        if (field.contains("\n") || field.contains("\r")) {
            throw IllegalArgumentException("CHIR worker declaration record contains a newline")
        }
    }
    fields
}

private func recordValue(value: String): String {
    if (value == "-") { "" } else { value }
}

private func parseFunctionRecord(value: String): ChirWorkerFunctionRecord {
    let fields = recordFields(value, 9)
    ChirWorkerFunctionRecord(fields[0], fields[1], fields[2], recordValue(fields[3]),
        recordValue(fields[4]), recordValue(fields[5]), recordValue(fields[6]),
        parseWorkerCount(fields[7]), parseWorkerCount(fields[8]))
}

private func parseMemberRecord(value: String): ChirWorkerMemberRecord {
    let fields = recordFields(value, 4)
    ChirWorkerMemberRecord(fields[0], fields[1], recordValue(fields[2]), recordValue(fields[3]))
}

private func parseTypeRecord(value: String): ChirWorkerTypeRecord {
    let fields = recordFields(value, 2)
    ChirWorkerTypeRecord(fields[0], fields[1])
}

private func parseExtendRecord(value: String): ChirWorkerExtendRecord {
    let fields = recordFields(value, 3)
    ChirWorkerExtendRecord(fields[0], recordValue(fields[1]), recordValue(fields[2]))
}
private func parseEnumCaseRecord(value: String): ChirWorkerEnumCaseRecord {
    let fields = recordFields(value, 3)
    ChirWorkerEnumCaseRecord(fields[0], recordValue(fields[1]), fields[2])
}

private func parseWorkerCount(value: String): Int64 {
    let bytes = value.toArray()
    if (bytes.isEmpty()) { throw IllegalArgumentException("CHIR worker count is empty") }
    var result: Int64 = 0
    for (byte in bytes) {
        if (byte < b'0' || byte > b'9') {
            throw IllegalArgumentException("CHIR worker count is not decimal")
        }
        result = result * 10 + Int64(byte) - 48
        if (result > 1000000000) {
            throw IllegalArgumentException("CHIR worker count is too large")
        }
    }
    result
}

private func validateChirWorkerFile(path: Path): Unit {
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink()) {
        throw IllegalArgumentException("CHIR worker request must be a regular non-symbolic-link file")
    }
}

private func validateChirWorkerStagedFile(root: Path, path: Path): Unit {
    validateChirWorkerFile(path)
    let canonicalRoot = canonicalize(root).toString()
    let actual = canonicalize(path).toString()
    if (actual == canonicalRoot || !hostPathIsWithin(canonicalRoot, actual)) {
        throw IllegalArgumentException("CHIR worker source escapes its staging directory")
    }
}

private func writeChirWorkerSuccess(path: Path, summary: ChirWorkerSummary): Unit {
    let lines = ArrayList<String>()
    lines.add("protocol=${CHIR_WORKER_PROTOCOL}")
    lines.add("status=ok")
    lines.add("functions=" + summary.functionCount.toString())
    lines.add("types=" + summary.typeCount.toString())
    lines.add("extends=" + summary.extendCount.toString())
    for (record in summary.functionRecords) {
        lines.add("function=" + chirRecordValue(record.packageName) + "\t" +
            chirRecordValue(record.name) + "\t" + chirRecordValue(record.ownerKind) + "\t" +
            chirRecordValue(record.ownerPackageName) + "\t" + chirRecordValue(record.ownerName) + "\t" +
            chirRecordValue(record.targetPackageName) + "\t" + chirRecordValue(record.targetName) + "\t" +
            record.genericArity.toString() + "\t" + record.parameterCount.toString())
    }
    for (record in summary.memberRecords) {
        lines.add("member=" + chirRecordValue(record.packageName) + "\t" +
            chirRecordValue(record.name) + "\t" + chirRecordValue(record.ownerPackageName) + "\t" +
            chirRecordValue(record.ownerName))
    }
    for (record in summary.typeRecords) {
        lines.add("type=" + chirRecordValue(record.packageName) + "\t" +
            chirRecordValue(record.name))
    }
    for (record in summary.extendRecords) {
        lines.add("extend=" + chirRecordValue(record.packageName) + "\t" +
            chirRecordValue(record.targetPackageName) + "\t" + chirRecordValue(record.targetName))
    }
    for (record in summary.enumCaseRecords) {
        lines.add("enumCase=" + chirRecordValue(record.packageName) + "	" +
            chirRecordValue(record.ownerName) + "	" + chirRecordValue(record.name))
    }
    File.writeTo(path, chirWorkerLinesText(lines).toArray())
}

private func chirRecordValue(value: String): String {
    if (value.isEmpty()) { "-" } else { value }
}

private func chirWorkerLinesText(lines: ArrayList<String>): String {
    let builder = StringBuilder()
    var first = true
    for (line in lines) {
        if (!first) { builder.append("\n") }
        builder.append(line)
        first = false
    }
    builder.append("\n")
    builder.toString()
}

private func writeChirWorkerFailure(path: Path, message: String): Unit {
    let safe = message.replace("\n", " ").replace("\r", " ")
    let lines = ArrayList<String>()
    lines.add("protocol=${CHIR_WORKER_PROTOCOL}")
    lines.add("status=error")
    lines.add("functions=0")
    lines.add("types=0")
    lines.add("extends=0")
    lines.add("error=${safe}")
    File.writeTo(path, chirWorkerLinesText(lines).toArray())
}

private func boundedWorkerCompilerOutput(stdout: Array<Byte>, stderr: Array<Byte>): String {
    let out = try { String.fromUtf8(stdout).trimAscii() } catch (_: Exception) { "" }
    let err = try { String.fromUtf8(stderr).trimAscii() } catch (_: Exception) { "" }
    let combined = if (out.isEmpty()) { err } else if (err.isEmpty()) { out } else { out + "\n" + err }
    let bytes = combined.toArray()
    if (bytes.size <= 8192) { return combined }
    String.fromUtf8(bytes[..8192]) + "\n... CHIR compiler output truncated"
}
