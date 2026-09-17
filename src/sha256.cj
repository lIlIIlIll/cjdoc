package cjdoc

import cjdoc.model.*
import std.collection.*

internal class Sha256Digest {
    internal static func digest(value: String): String {
        contractFingerprint(value)
    }

    internal static func digestBytes(input: Array<Byte>): String {
        contractFingerprintBytes(input)
    }
}
