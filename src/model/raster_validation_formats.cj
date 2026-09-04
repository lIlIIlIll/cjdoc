package cjdoc.model


protected let DOC_IR_MAX_ASSET_BYTES: Int64 = 16 * 1024 * 1024
protected let DOC_IR_MAX_TOTAL_ASSET_BYTES: Int64 = 64 * 1024 * 1024
protected let DOC_IR_MAX_ASSET_DIMENSION: Int64 = 16384
protected let DOC_IR_MAX_ASSET_PIXELS: Int64 = 100 * 1000 * 1000
protected let DOC_IR_MAX_TOTAL_ASSET_PIXELS: Int64 = 200 * 1000 * 1000

internal class RasterDimensions {
    let width: Int64
    let height: Int64

    init(width: Int64, height: Int64) { this.width = width; this.height = height }
}

internal func rasterStartsWith(value: Array<Byte>, expected: Array<Byte>): Bool {
    if (value.size < expected.size) { return false }
    var index: Int64 = 0
    while (index < expected.size) {
        if (value[index] != expected[index]) { return false }
        index++
    }
    true
}

internal func rasterBig16(value: Array<Byte>, offset: Int64): Int64 {
    (Int64(value[offset]) << 8) | Int64(value[offset + 1])
}

internal func rasterLittle16(value: Array<Byte>, offset: Int64): Int64 {
    Int64(value[offset]) | (Int64(value[offset + 1]) << 8)
}

internal func rasterBig32(value: Array<Byte>, offset: Int64): Int64 {
    (Int64(value[offset]) << 24) | (Int64(value[offset + 1]) << 16) |
        (Int64(value[offset + 2]) << 8) | Int64(value[offset + 3])
}

internal func rasterLittle32(value: Array<Byte>, offset: Int64): Int64 {
    Int64(value[offset]) | (Int64(value[offset + 1]) << 8) |
        (Int64(value[offset + 2]) << 16) | (Int64(value[offset + 3]) << 24)
}

internal func rasterFourCc(value: Array<Byte>, offset: Int64, expected: String): Bool {
    if (offset < 0 || offset + 4 > value.size) { return false }
    let bytes = expected.toArray()
    bytes.size == 4 && value[offset] == bytes[0] && value[offset + 1] == bytes[1] &&
        value[offset + 2] == bytes[2] && value[offset + 3] == bytes[3]
}

internal func rasterCrc32(value: Array<Byte>, start: Int64, end: Int64): Int64 {
    var crc = 0xFFFFFFFFu32
    var index = start
    while (index < end) {
        crc = crc ^ UInt32(value[index])
        var bit: Int64 = 0
        while (bit < 8) {
            crc = if ((crc & 1u32) != 0u32) {
                (crc >> 1u32) ^ 0xEDB88320u32
            } else { crc >> 1u32 }
            bit++
        }
        index++
    }
    Int64(crc ^ 0xFFFFFFFFu32)
}

internal func rasterPngDimensions(value: Array<Byte>): ?RasterDimensions {
    if (value.size < 57 || !rasterStartsWith(value,
        [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])) { return None }
    var index: Int64 = 8
    var width: Int64 = 0
    var height: Int64 = 0
    var colorType: Byte = 0
    var chunks: Int64 = 0
    var hasPalette = false
    var hasImageData = false
    var endedImageData = false
    while (index + 12 <= value.size) {
        let length = rasterBig32(value, index)
        if (length < 0 || length > value.size - index - 12) { return None }
        let kind = index + 4
        let payload = index + 8
        let crcOffset = payload + length
        if (rasterCrc32(value, kind, crcOffset) != rasterBig32(value, crcOffset)) {
            return None
        }
        let isIhdr = rasterFourCc(value, kind, "IHDR")
        let isPlte = rasterFourCc(value, kind, "PLTE")
        let isIdat = rasterFourCc(value, kind, "IDAT")
        let isIend = rasterFourCc(value, kind, "IEND")
        if (rasterFourCc(value, kind, "acTL") || rasterFourCc(value, kind, "fcTL") ||
            rasterFourCc(value, kind, "fdAT")) { return None }
        if (chunks == 0) {
            if (!isIhdr || length != 13) { return None }
            width = rasterBig32(value, payload)
            height = rasterBig32(value, payload + 4)
            let bitDepth = value[payload + 8]
            colorType = value[payload + 9]
            let validBitDepth = match (colorType) {
                case 0 => bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8 ||
                    bitDepth == 16
                case 2 | 4 | 6 => bitDepth == 8 || bitDepth == 16
                case 3 => bitDepth == 1 || bitDepth == 2 || bitDepth == 4 || bitDepth == 8
                case _ => false
            }
            if (!validBitDepth || value[payload + 10] != 0 || value[payload + 11] != 0 ||
                value[payload + 12] > 1) { return None }
        } else if (isIhdr) { return None }
        if (isPlte) {
            if (hasPalette || hasImageData || length < 3 || length > 768 || length % 3 != 0 ||
                colorType == 0 || colorType == 4) { return None }
            hasPalette = true
        }
        if (isIdat) {
            if (endedImageData || length == 0 || (colorType == 3 && !hasPalette)) { return None }
            hasImageData = true
        } else if (hasImageData && !isIend) { endedImageData = true }
        let critical = value[kind] >= b'A' && value[kind] <= b'Z'
        if (critical && !isIhdr && !isPlte && !isIdat && !isIend) { return None }
        index = crcOffset + 4
        chunks++
        if (isIend) {
            if (length != 0 || !hasImageData || index != value.size) { return None }
            return Some(RasterDimensions(width, height))
        }
    }
    None
}

internal class GifSubBlocks {
    let end: Int64
    let payloadBytes: Int64
    init(end: Int64, payloadBytes: Int64) { this.end = end; this.payloadBytes = payloadBytes }
}

internal func rasterGifSubBlocks(value: Array<Byte>, start: Int64): ?GifSubBlocks {
    var index = start
    var payload: Int64 = 0
    while (index < value.size) {
        let size = Int64(value[index]); index++
        if (size == 0) { return Some(GifSubBlocks(index, payload)) }
        if (size > value.size - index) { return None }
        payload += size
        index += size
    }
    None
}

internal func rasterGifDimensions(value: Array<Byte>): ?RasterDimensions {
    if (value.size < 14 || (!rasterStartsWith(value, "GIF87a".toArray()) &&
        !rasterStartsWith(value, "GIF89a".toArray()))) { return None }
    let width = rasterLittle16(value, 6)
    let height = rasterLittle16(value, 8)
    let packed = Int64(value[10])
    var index: Int64 = 13
    if ((packed & 0x80) != 0) {
        let tableBytes = 3 * (1 << ((packed & 7) + 1))
        if (tableBytes > value.size - index) { return None }
        index += tableBytes
    }
    var images: Int64 = 0
    while (index < value.size) {
        let marker = value[index]; index++
        if (marker == 0x3B) {
            if (images == 1 && index == value.size) {
                return Some(RasterDimensions(width, height))
            }
            return None
        }
        if (marker == 0x21) {
            if (index >= value.size) { return None }
            let label = value[index]; index++
            if (label == 0xF9) {
                if (index + 6 > value.size || value[index] != 4 || value[index + 5] != 0) {
                    return None
                }
                index += 6
            } else {
                if (label == 0xFF) { return None }
                if (label == 0x01) {
                    if (index + 13 > value.size || value[index] != 12) { return None }
                    index += 13
                }
                let blocks = match (rasterGifSubBlocks(value, index)) {
                    case Some(found) => found
                    case None => return None
                }
                index = blocks.end
            }
        } else if (marker == 0x2C) {
            if (images != 0 || index + 9 > value.size) { return None }
            let left = rasterLittle16(value, index)
            let top = rasterLittle16(value, index + 2)
            let imageWidth = rasterLittle16(value, index + 4)
            let imageHeight = rasterLittle16(value, index + 6)
            if (imageWidth <= 0 || imageHeight <= 0 || left > width - imageWidth ||
                top > height - imageHeight) { return None }
            let imagePacked = Int64(value[index + 8]); index += 9
            if ((imagePacked & 0x80) != 0) {
                let tableBytes = 3 * (1 << ((imagePacked & 7) + 1))
                if (tableBytes > value.size - index) { return None }
                index += tableBytes
            }
            if (index >= value.size || value[index] < 2 || value[index] > 8) { return None }
            index++
            let blocks = match (rasterGifSubBlocks(value, index)) {
                case Some(found) => found
                case None => return None
            }
            if (blocks.payloadBytes == 0) { return None }
            index = blocks.end
            images++
        } else { return None }
    }
    None
}

internal func rasterJpegSof(marker: Byte): Bool {
    marker == 0xC0 || marker == 0xC1 || marker == 0xC2 || marker == 0xC3 ||
        marker == 0xC5 || marker == 0xC6 || marker == 0xC7 || marker == 0xC9 ||
        marker == 0xCA || marker == 0xCB || marker == 0xCD || marker == 0xCE || marker == 0xCF
}

internal func rasterJpegDimensions(value: Array<Byte>): ?RasterDimensions {
    if (value.size < 16 || value[0] != 0xFF || value[1] != 0xD8) { return None }
    var index: Int64 = 2
    var dimensions: ?RasterDimensions = None
    var scanPayload: Int64 = 0
    while (index < value.size) {
        if (value[index] != 0xFF) { return None }
        while (index < value.size && value[index] == 0xFF) { index++ }
        if (index >= value.size) { return None }
        let marker = value[index]; index++
        if (marker == 0xD9) {
            if (index != value.size || scanPayload == 0) { return None }
            return dimensions
        }
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
            return None
        }
        if (index + 2 > value.size) { return None }
        let length = rasterBig16(value, index)
        if (length < 2 || length > value.size - index) { return None }
        if (rasterJpegSof(marker)) {
            if (dimensions.isSome() || length < 11) { return None }
            let components = Int64(value[index + 7])
            if (components < 1 || components > 4 || length != 8 + 3 * components) { return None }
            dimensions = Some(RasterDimensions(rasterBig16(value, index + 5),
                rasterBig16(value, index + 3)))
        }
        if (marker == 0xDA) {
            if (dimensions.isNone() || length < 8) { return None }
            let components = Int64(value[index + 2])
            if (components < 1 || length != 6 + 2 * components) { return None }
            index += length
            var foundMarker = false
            while (index < value.size) {
                if (value[index] != 0xFF) { scanPayload++; index++; continue }
                let markerStart = index
                while (index < value.size && value[index] == 0xFF) { index++ }
                if (index >= value.size) { return None }
                if (value[index] == 0x00) { scanPayload++; index++; continue }
                if (value[index] >= 0xD0 && value[index] <= 0xD7) { index++; continue }
                index = markerStart
                foundMarker = true
                break
            }
            if (!foundMarker) { return None }
        } else { index += length }
    }
    None
}
