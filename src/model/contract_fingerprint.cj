package cjdoc.model

import cjdoc.digest.Sha256Digest

public func contractFingerprint(value: String): String {
    Sha256Digest.digest(value)
}

public func contractFingerprintBytes(input: Array<Byte>): String {
    Sha256Digest.digestBytes(input)
}
