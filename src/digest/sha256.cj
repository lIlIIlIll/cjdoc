protected package cjdoc.digest

import cjdoc.model.*

protected class Sha256Digest {
    protected static func digest(value: String): String {
        contractFingerprint(value)
    }

    protected static func digestBytes(input: Array<Byte>): String {
        contractFingerprintBytes(input)
    }
}

protected func isSha256(value: String): Bool { value.size == 64 && isLowercaseHex(value) }

protected func isFullGitSha(value: String): Bool { value.size == 40 && isLowercaseHex(value) }

private func isLowercaseHex(value: String): Bool {
    for (index in 0..value.size) {
        let byte = value[index]
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}
