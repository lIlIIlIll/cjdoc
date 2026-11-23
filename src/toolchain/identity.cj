protected package cjdoc.toolchain

import cjdoc.process.executeWithBoundedOutput
import std.env.*

// Host/wrapper observations used only as cache hints. They do not authenticate
// the dynamically loaded parser build or the documented target's selected
// compiler, standard library, or independently selected stdx component.
protected class ToolchainIdentity {
    protected let compilerVersion: String
    protected let compilerTarget: String
    protected let toolchainFingerprint: String
    protected let stdxDigest: String
    protected let stdxDependencyDigest: String
    protected let stdxVariant: String

    protected init(compilerExecutable!: ?String = None) {
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

    protected func sourceBackendFingerprint(): String {
        "cjdoc-source-backend=std.ast/v1\n" +
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
