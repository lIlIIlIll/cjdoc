protected package cjdoc.render.codec

import std.collection.ArrayList

protected func assetMediaExtension(mediaType: String): String {
    match (mediaType) {
        case "image/png" => "png"
        case "image/jpeg" => "jpg"
        case "image/gif" => "gif"
        case "image/webp" => "webp"
        case "image/avif" => "avif"
        case _ => throw IllegalArgumentException("unsupported local asset media type '${mediaType}'")
    }
}

internal func base64Digit(value: Byte): Int64 {
    if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
    if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
    if (value == b'+') { return 62 }
    if (value == b'/') { return 63 }
    return -1
}

protected func decodeAssetBase64(value: String): Array<Byte> {
    let encoded = value.toArray()
    if (encoded.isEmpty() || encoded.size % 4 != 0) {
        throw IllegalArgumentException("invalid local asset base64")
    }
    let decoded = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < encoded.size) {
        let last = index + 4 == encoded.size
        let first = base64Digit(encoded[index])
        let second = base64Digit(encoded[index + 1])
        if (first < 0 || second < 0) { throw IllegalArgumentException("invalid local asset base64") }
        let thirdPadding = encoded[index + 2] == b'='
        let fourthPadding = encoded[index + 3] == b'='
        if (thirdPadding) {
            if (!last || !fourthPadding || (second & 15) != 0) {
                throw IllegalArgumentException("invalid local asset base64 padding")
            }
            decoded.add(UInt8((first << 2) | (second >> 4)))
        } else {
            let third = base64Digit(encoded[index + 2])
            if (third < 0) { throw IllegalArgumentException("invalid local asset base64") }
            decoded.add(UInt8((first << 2) | (second >> 4)))
            decoded.add(UInt8(((second & 15) << 4) | (third >> 2)))
            if (fourthPadding) {
                if (!last || (third & 3) != 0) {
                    throw IllegalArgumentException("invalid local asset base64 padding")
                }
            } else {
                let fourth = base64Digit(encoded[index + 3])
                if (fourth < 0) { throw IllegalArgumentException("invalid local asset base64") }
                decoded.add(UInt8(((third & 3) << 6) | fourth))
            }
        }
        index += 4
    }
    decoded.toArray()
}
