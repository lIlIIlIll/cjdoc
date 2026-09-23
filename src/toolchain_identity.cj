package cjdoc

import std.env.*

// Captures the authenticated compiler and stdx identity that owns generated
// source facts. Missing wrapper metadata remains explicit so cache keys cannot
// silently claim a verified toolchain.
internal class ToolchainIdentity {
    public let compilerVersion: String
    public let compilerTarget: String
    public let toolchainFingerprint: String
    public let stdxDigest: String
    public let stdxDependencyDigest: String
    public let stdxVariant: String

    init(compilerExecutable!: ?String = None) {
        let configuredVersion = environmentValue("CJDOC_TOOLCHAIN_VERSION", "unknown-cjc")
        compilerVersion = if (configuredVersion != "unknown-cjc") {
            configuredVersion
        } else {
            match (compilerExecutable) {
                case Some(executable) => compilerVersionFromExecutable(executable)
                case None => "unknown-cjc"
            }
        }
        compilerTarget = environmentValue("CJDOC_TOOLCHAIN_TARGET", "unknown-target")
        toolchainFingerprint = environmentValue("CJDOC_TOOLCHAIN_FINGERPRINT", "unknown-toolchain")
        stdxDigest = environmentValue("CJDOC_STDX_DIGEST", "unknown-stdx")
        stdxDependencyDigest = environmentValue("CJDOC_STDX_DEPENDENCY_DIGEST", stdxDigest)
        stdxVariant = environmentValue("CJDOC_STDX_VARIANT", "unknown-variant")
    }

    func sourceBackendFingerprint(): String {
        "cjdoc-source-backend=stdx.syntax/v2\n" +
            "compiler=${compilerVersion}\n" +
            "target=${compilerTarget}\n" +
            "toolchain=${toolchainFingerprint}\n" +
            "stdx=${stdxDigest}\n" +
            "stdx-dependencies=${stdxDependencyDigest}\n" +
            "stdx-variant=${stdxVariant}"
    }
}

private func compilerVersionFromExecutable(executable: String): String {
    try {
        let (exitCode, output, _) = executeWithBoundedOutput(executable, ["--version"])
        if (exitCode != 0) { return "unknown-cjc" }
        for (line in String.fromUtf8(output).split("\n")) {
            let trimmed = line.trimAscii()
            let prefix = "Cangjie Compiler:"
            if (trimmed.startsWith(prefix)) {
                let version = trimmed.removePrefix(prefix).trimAscii()
                if (!version.isEmpty()) { return version }
            }
        }
    } catch (_: Exception) {}
    "unknown-cjc"
}

private func environmentValue(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(value) => if (value.trimAscii().isEmpty()) { fallback } else { value }
        case None => fallback
    }
}
