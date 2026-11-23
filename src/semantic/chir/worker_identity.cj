protected package cjdoc.semantic.chir

import cjdoc.process.executeWithBoundedOutput
import cjdoc_chir_protocol.{CHIR_WORKER_PROTOCOL, CJDOC_PRODUCT_VERSION}

internal func chirWorkerCompatibilityFailure(executable: String): ?String {
    try {
        let (versionCode, versionOutput, _) = executeWithBoundedOutput(executable, ["--version"])
        if (versionCode != 0 || String.fromUtf8(versionOutput).trimAscii() !=
            "cjdoc-chir-worker " + CJDOC_PRODUCT_VERSION) {
            return Some("CJDOC2104: CHIR worker product version does not match cjdoc")
        }
        let (protocolCode, protocolOutput, _) = executeWithBoundedOutput(executable, ["--protocol-version"])
        if (protocolCode != 0 || String.fromUtf8(protocolOutput).trimAscii() != CHIR_WORKER_PROTOCOL) {
            return Some("CJDOC2104: CHIR worker protocol does not match cjdoc")
        }
        None
    } catch (error: Exception) {
        Some("CJDOC2101: CHIR worker could not be started: " + error.message)
    }
}
