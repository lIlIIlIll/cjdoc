package cjdoc_chir_protocol

import std.collection.*
import std.fs.*

public let CHIR_WORKER_PROTOCOL = "cjdoc-chir-worker/1"
public let MAX_CHIR_REQUEST_BYTES: Int64 = 4 * 1024 * 1024
public let MAX_CHIR_RESPONSE_BYTES: Int64 = 16 * 1024 * 1024

// One resolved type in a signature, in pre-order, with its depth in the
// argument tree. `qualifiedName` is the name CHIR resolved, which distinguishes
// same-spelled types from different packages.
public class ChirTypeNode {
    public let depth: Int64
    public let qualifiedName: String

    public init(depth: Int64, qualifiedName: String) {
        this.depth = depth
        this.qualifiedName = qualifiedName
    }
}

// The parameter/return type structure CHIR resolved for one declaration. The
// first `paramCount` top-level entries are the parameters, in source order; the
// remaining top-level entry, when present, is the return type.
public class ChirWorkerSignatureRecord {
    public let packageName: String
    public let name: String
    public let ownerName: String
    public let paramCount: Int64
    public let types: ArrayList<ChirTypeNode>

    public init(packageName: String, name: String, ownerName: String, paramCount: Int64,
        types: ArrayList<ChirTypeNode>) {
        this.packageName = packageName
        this.name = name
        this.ownerName = ownerName
        this.paramCount = paramCount
        this.types = types
    }
}

public class ChirWorkerFunctionRecord {
    public let packageName: String
    public let name: String
    public let ownerKind: String
    public let ownerPackageName: String
    public let ownerName: String
    public let targetPackageName: String
    public let targetName: String
    public let genericArity: Int64
    public let parameterCount: Int64

    public init(packageName: String, name: String, ownerKind: String, ownerPackageName: String,
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

public class ChirWorkerMemberRecord {
    public let packageName: String
    public let name: String
    public let ownerPackageName: String
    public let ownerName: String

    public init(packageName: String, name: String, ownerPackageName: String, ownerName: String) {
        this.packageName = packageName
        this.name = name
        this.ownerPackageName = ownerPackageName
        this.ownerName = ownerName
    }
}

public class ChirWorkerTypeRecord {
    public let packageName: String
    public let name: String

    public init(packageName: String, name: String) {
        this.packageName = packageName
        this.name = name
    }
}

public class ChirWorkerExtendRecord {
    public let packageName: String
    public let targetPackageName: String
    public let targetName: String

    public init(packageName: String, targetPackageName: String, targetName: String) {
        this.packageName = packageName
        this.targetPackageName = targetPackageName
        this.targetName = targetName
    }
}
public class ChirWorkerEnumCaseRecord {
    public let packageName: String
    public let ownerName: String
    public let name: String

    public init(packageName: String, ownerName: String, name: String) {
        this.packageName = packageName
        this.ownerName = ownerName
        this.name = name
    }
}

public class ChirWorkerSummary {
    public let functionRecords = ArrayList<ChirWorkerFunctionRecord>()
    public let memberRecords = ArrayList<ChirWorkerMemberRecord>()
    public let typeRecords = ArrayList<ChirWorkerTypeRecord>()
    public let extendRecords = ArrayList<ChirWorkerExtendRecord>()
    public let signatureRecords = ArrayList<ChirWorkerSignatureRecord>()
    public let enumCaseRecords = ArrayList<ChirWorkerEnumCaseRecord>()
    public var functionCount: Int64 = 0
    public var typeCount: Int64 = 0
    public var extendCount: Int64 = 0
}

public func writeChirWorkerRequest(path: Path, compiler: String, moduleName: String,
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

public func readChirWorkerResponse(text: String): ChirWorkerSummary {
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
            case "signature" => summary.signatureRecords.add(parseSignatureRecord(value))
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

public func readChirWorkerRequest(text: String): HashMap<String, ArrayList<String>> {
    let fields = HashMap<String, ArrayList<String>>()
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


public func requiredChirWorkerField(fields: HashMap<String, ArrayList<String>>, key: String): String {
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

public func chirWorkerFields(fields: HashMap<String, ArrayList<String>>, key: String): Array<String> {
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

private func parseSignatureRecord(value: String): ChirWorkerSignatureRecord {
    let fields = value.split("\t")
    if (fields.size < 5) {
        throw IllegalArgumentException("CHIR worker signature record is malformed")
    }
    let paramCount = parseWorkerCount(fields[3])
    let typeCount = parseWorkerCount(fields[4])
    if (fields.size != 5 + typeCount * 2) {
        throw IllegalArgumentException("CHIR worker signature record type count is inconsistent")
    }
    let types = ArrayList<ChirTypeNode>()
    var index: Int64 = 0
    while (index < typeCount) {
        types.add(ChirTypeNode(parseWorkerCount(fields[5 + index * 2]),
            recordValue(fields[6 + index * 2])))
        index++
    }
    ChirWorkerSignatureRecord(fields[0], fields[1], recordValue(fields[2]), paramCount, types)
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

public func writeChirWorkerSuccess(path: Path, summary: ChirWorkerSummary): Unit {
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
    for (record in summary.signatureRecords) {
        let fields = ArrayList<String>()
        fields.add(chirRecordValue(record.packageName))
        fields.add(chirRecordValue(record.name))
        fields.add(chirRecordValue(record.ownerName))
        fields.add(record.paramCount.toString())
        fields.add(record.types.size.toString())
        for (node in record.types) {
            fields.add(node.depth.toString())
            fields.add(chirRecordValue(node.qualifiedName))
        }
        let joined = StringBuilder()
        var firstField = true
        for (field in fields) {
            if (!firstField) { joined.append("\t") }
            firstField = false
            joined.append(field)
        }
        lines.add("signature=" + joined.toString())
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

public func writeChirWorkerFailure(path: Path, message: String): Unit {
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

