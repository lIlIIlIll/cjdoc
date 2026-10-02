package cjdoc_chir_worker

import std.collection.*
import std.fs.*

import stdx.chir.*
import cjdoc_chir_protocol.*

private let MAX_CHIR_ARTIFACT_BYTES: Int64 = 128 * 1024 * 1024

main(args: Array<String>): Int64 {
    if (args.size != 3 || args[0] != "--internal-chir-analyze") { return 2 }
    runChirAnalyzeWorker(args[1], args[2])
}

internal func runChirAnalyzeWorker(requestPath: String, responsePath: String): Int64 {
    let response = Path(responsePath)
    try {
        let request = Path(requestPath)
        validateChirWorkerFile(request)
        let root = request.parent
        let fields = readChirWorkerRequest(readTextBounded(request, MAX_CHIR_REQUEST_BYTES))
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

private func boundedWorkerCompilerOutput(stdout: Array<Byte>, stderr: Array<Byte>): String {
    let out = try { String.fromUtf8(stdout).trimAscii() } catch (_: Exception) { "" }
    let err = try { String.fromUtf8(stderr).trimAscii() } catch (_: Exception) { "" }
    let combined = if (out.isEmpty()) { err } else if (err.isEmpty()) { out } else { out + "\n" + err }
    let bytes = combined.toArray()
    if (bytes.size <= 8192) { return combined }
    String.fromUtf8(bytes[..8192]) + "\n... CHIR compiler output truncated"
}
