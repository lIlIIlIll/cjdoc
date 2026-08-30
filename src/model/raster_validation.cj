package cjdoc.model

import std.collection.*

protected let DOC_IR_MAX_ASSET_BYTES: Int64 = 16 * 1024 * 1024
protected let DOC_IR_MAX_TOTAL_ASSET_BYTES: Int64 = 64 * 1024 * 1024
protected let DOC_IR_MAX_ASSET_DIMENSION: Int64 = 16384
protected let DOC_IR_MAX_ASSET_PIXELS: Int64 = 100 * 1000 * 1000
protected let DOC_IR_MAX_TOTAL_ASSET_PIXELS: Int64 = 200 * 1000 * 1000

private class RasterDimensions {
    let width: Int64
    let height: Int64

    init(width: Int64, height: Int64) { this.width = width; this.height = height }
}

private func rasterStartsWith(value: Array<Byte>, expected: Array<Byte>): Bool {
    if (value.size < expected.size) { return false }
    var index: Int64 = 0
    while (index < expected.size) {
        if (value[index] != expected[index]) { return false }
        index++
    }
    true
}

private func rasterBig16(value: Array<Byte>, offset: Int64): Int64 {
    (Int64(value[offset]) << 8) | Int64(value[offset + 1])
}

private func rasterLittle16(value: Array<Byte>, offset: Int64): Int64 {
    Int64(value[offset]) | (Int64(value[offset + 1]) << 8)
}

private func rasterBig32(value: Array<Byte>, offset: Int64): Int64 {
    (Int64(value[offset]) << 24) | (Int64(value[offset + 1]) << 16) |
        (Int64(value[offset + 2]) << 8) | Int64(value[offset + 3])
}

private func rasterLittle32(value: Array<Byte>, offset: Int64): Int64 {
    Int64(value[offset]) | (Int64(value[offset + 1]) << 8) |
        (Int64(value[offset + 2]) << 16) | (Int64(value[offset + 3]) << 24)
}

private func rasterFourCc(value: Array<Byte>, offset: Int64, expected: String): Bool {
    if (offset < 0 || offset + 4 > value.size) { return false }
    let bytes = expected.toArray()
    bytes.size == 4 && value[offset] == bytes[0] && value[offset + 1] == bytes[1] &&
        value[offset + 2] == bytes[2] && value[offset + 3] == bytes[3]
}

private func rasterCrc32(value: Array<Byte>, start: Int64, end: Int64): Int64 {
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

private func rasterPngDimensions(value: Array<Byte>): ?RasterDimensions {
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

private class GifSubBlocks {
    let end: Int64
    let payloadBytes: Int64
    init(end: Int64, payloadBytes: Int64) { this.end = end; this.payloadBytes = payloadBytes }
}

private func rasterGifSubBlocks(value: Array<Byte>, start: Int64): ?GifSubBlocks {
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

private func rasterGifDimensions(value: Array<Byte>): ?RasterDimensions {
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

private func rasterJpegSof(marker: Byte): Bool {
    marker == 0xC0 || marker == 0xC1 || marker == 0xC2 || marker == 0xC3 ||
        marker == 0xC5 || marker == 0xC6 || marker == 0xC7 || marker == 0xC9 ||
        marker == 0xCA || marker == 0xCB || marker == 0xCD || marker == 0xCE || marker == 0xCF
}

private func rasterJpegDimensions(value: Array<Byte>): ?RasterDimensions {
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

private func rasterWebpDimensions(value: Array<Byte>): ?RasterDimensions {
    if (value.size < 30 || !rasterFourCc(value, 0, "RIFF") ||
        !rasterFourCc(value, 8, "WEBP") || rasterLittle32(value, 4) != value.size - 8) {
        return None
    }
    var index: Int64 = 12
    var dimensions: ?RasterDimensions = None
    var canvas: ?RasterDimensions = None
    var extended = false
    var chunks: Int64 = 0
    while (index + 8 <= value.size) {
        let chunkSize = rasterLittle32(value, index + 4)
        if (chunkSize < 0 || chunkSize > value.size - index - 8) { return None }
        let payload = index + 8
        let padded = chunkSize & 1
        if (chunkSize + padded > value.size - index - 8) { return None }
        if (rasterFourCc(value, index, "ANIM") || rasterFourCc(value, index, "ANMF")) {
            return None
        }
        if (rasterFourCc(value, index, "VP8X")) {
            if (chunks != 0 || chunkSize != 10 || extended) { return None }
            let flags = value[payload]
            if ((flags & 0xC3) != 0) { return None }
            extended = true
            canvas = Some(RasterDimensions(1 + Int64(value[payload + 4]) +
                (Int64(value[payload + 5]) << 8) + (Int64(value[payload + 6]) << 16),
                1 + Int64(value[payload + 7]) + (Int64(value[payload + 8]) << 8) +
                (Int64(value[payload + 9]) << 16)))
        } else if (rasterFourCc(value, index, "VP8L")) {
            if (dimensions.isSome() || chunkSize <= 5 || value[payload] != 0x2F) { return None }
            let bits = rasterLittle32(value, payload + 1)
            dimensions = Some(RasterDimensions(1 + (bits & 0x3FFF),
                1 + ((bits >> 14) & 0x3FFF)))
        } else if (rasterFourCc(value, index, "VP8 ")) {
            if (dimensions.isSome() || chunkSize <= 10 || (value[payload] & 1) != 0 ||
                value[payload + 3] != 0x9D || value[payload + 4] != 0x01 ||
                value[payload + 5] != 0x2A) { return None }
            dimensions = Some(RasterDimensions(rasterLittle16(value, payload + 6) & 0x3FFF,
                rasterLittle16(value, payload + 8) & 0x3FFF))
        } else if (!rasterFourCc(value, index, "ALPH") &&
            !rasterFourCc(value, index, "ICCP") && !rasterFourCc(value, index, "EXIF") &&
            !rasterFourCc(value, index, "XMP ")) { return None }
        if (!extended && !rasterFourCc(value, index, "VP8L") &&
            !rasterFourCc(value, index, "VP8 ")) { return None }
        if (chunkSize == 0 && !rasterFourCc(value, index, "VP8X")) { return None }
        if (padded == 1 && value[payload + chunkSize] != 0) { return None }
        index += 8 + chunkSize + padded
        chunks++
    }
    if (index != value.size || dimensions.isNone()) { return None }
    let image = dimensions.getOrThrow()
    match (canvas) {
        case Some(value) => if (value.width != image.width || value.height != image.height) {
            return None
        }
        case None => ()
    }
    dimensions
}

private class RasterBox {
    let kindOffset: Int64
    let payloadStart: Int64
    let end: Int64
    init(kindOffset: Int64, payloadStart: Int64, end: Int64) {
        this.kindOffset = kindOffset; this.payloadStart = payloadStart; this.end = end
    }
}

private func rasterBox(value: Array<Byte>, start: Int64, end: Int64): ?RasterBox {
    if (start < 0 || start + 8 > end || end > value.size) { return None }
    let size = rasterBig32(value, start)
    if (size < 8 || size > end - start) { return None }
    Some(RasterBox(start + 4, start + 8, start + size))
}

private func rasterBigN(value: Array<Byte>, offset: Int64, count: Int64): Int64 {
    if (count < 0 || count > 4 || offset < 0 || offset + count > value.size) { return -1 }
    var result: Int64 = 0
    var index: Int64 = 0
    while (index < count) { result = (result << 8) | Int64(value[offset + index]); index++ }
    result
}

private class AvifPropertyState {
    let dimensionsByIndex = HashMap<Int64, RasterDimensions>()
    var propertyCount: Int64 = 0
    var primaryHasDimensions = false
}

private func rasterAvifProperties(value: Array<Byte>, box: RasterBox,
    primary: Int64): ?RasterDimensions {
    var ipco: ?RasterBox = None
    var ipma: ?RasterBox = None
    var index = box.payloadStart
    while (index < box.end) {
        let child = match (rasterBox(value, index, box.end)) {
            case Some(found) => found
            case None => return None
        }
        if (rasterFourCc(value, child.kindOffset, "ipco")) { ipco = Some(child) }
        if (rasterFourCc(value, child.kindOffset, "ipma")) { ipma = Some(child) }
        index = child.end
    }
    if (ipco.isNone() || ipma.isNone()) { return None }
    let state = AvifPropertyState()
    index = ipco.getOrThrow().payloadStart
    while (index < ipco.getOrThrow().end) {
        let property = match (rasterBox(value, index, ipco.getOrThrow().end)) {
            case Some(found) => found
            case None => return None
        }
        state.propertyCount++
        if (rasterFourCc(value, property.kindOffset, "ispe")) {
            if (property.end - property.payloadStart != 12 ||
                rasterBig32(value, property.payloadStart) != 0) { return None }
            state.dimensionsByIndex[state.propertyCount] = RasterDimensions(
                rasterBig32(value, property.payloadStart + 4),
                rasterBig32(value, property.payloadStart + 8))
        }
        index = property.end
    }
    let associations = ipma.getOrThrow()
    if (associations.end - associations.payloadStart < 8) { return None }
    let version = value[associations.payloadStart]
    let flags = rasterBig32(value, associations.payloadStart) & 0xFFFFFF
    if (version > 1) { return None }
    index = associations.payloadStart + 4
    let entryCount = rasterBig32(value, index); index += 4
    var result: ?RasterDimensions = None
    var entry: Int64 = 0
    while (entry < entryCount) {
        let itemBytes: Int64 = if (version == 0) { 2 } else { 4 }
        if (index + itemBytes + 1 > associations.end) { return None }
        let item = rasterBigN(value, index, itemBytes); index += itemBytes
        let count = Int64(value[index]); index++
        var association: Int64 = 0
        while (association < count) {
            let bytes: Int64 = if ((flags & 1) != 0) { 2 } else { 1 }
            if (index + bytes > associations.end) { return None }
            let raw = rasterBigN(value, index, bytes); index += bytes
            let propertyIndex = if (bytes == 2) { raw & 0x7FFF } else { raw & 0x7F }
            if (item == primary) {
                match (state.dimensionsByIndex.get(propertyIndex)) {
                    case Some(dimensions) => result = Some(dimensions)
                    case None => ()
                }
            }
            association++
        }
        entry++
    }
    if (index != associations.end) { return None }
    result
}

protected func rasterAvifPayloadRangesAreOrdered(
    mediaPayloads: Array<(Int64, Int64)>): Bool {
    if (mediaPayloads.isEmpty()) { return false }
    var previousEnd: Int64 = -1
    for ((payloadStart, payloadEnd) in mediaPayloads) {
        if (payloadStart < 0 || payloadEnd <= payloadStart ||
            (previousEnd >= 0 && payloadStart < previousEnd)) { return false }
        previousEnd = payloadEnd
    }
    true
}

protected func rasterAvifOrderedPayloadRangeContains(
    mediaPayloads: Array<(Int64, Int64)>, start: Int64, end: Int64): Bool {
    if (start < 0 || end <= start || mediaPayloads.isEmpty()) { return false }
    var low: Int64 = 0
    var high = mediaPayloads.size
    while (low < high) {
        let middle = low + (high - low) / 2
        let (payloadStart, _) = mediaPayloads[middle]
        if (payloadStart <= start) {
            low = middle + 1
        } else {
            high = middle
        }
    }
    if (low == 0) { return false }
    let (payloadStart, payloadEnd) = mediaPayloads[low - 1]
    start >= payloadStart && end <= payloadEnd
}

private func rasterAvifLocationHasPayload(value: Array<Byte>, box: RasterBox,
    primary: Int64, mediaPayloads: Array<(Int64, Int64)>): Bool {
    if (box.end - box.payloadStart < 8) { return false }
    let version = value[box.payloadStart]
    if (version > 2) { return false }
    var index = box.payloadStart + 4
    let sizes = value[index]; index++
    let sizes2 = value[index]; index++
    let offsetSize = Int64((sizes >> 4) & 0xF)
    let lengthSize = Int64(sizes & 0xF)
    let baseOffsetSize = Int64((sizes2 >> 4) & 0xF)
    let indexSize = if (version == 1 || version == 2) { Int64(sizes2 & 0xF) } else { 0 }
    if (offsetSize > 4 || lengthSize < 1 || lengthSize > 4 || baseOffsetSize > 4 ||
        indexSize > 4) { return false }
    let countBytes: Int64 = if (version < 2) { 2 } else { 4 }
    if (index + countBytes > box.end) { return false }
    let itemCount = rasterBigN(value, index, countBytes); index += countBytes
    var itemIndex: Int64 = 0
    var found = false
    while (itemIndex < itemCount) {
        let idBytes: Int64 = if (version < 2) { 2 } else { 4 }
        if (index + idBytes > box.end) { return false }
        let item = rasterBigN(value, index, idBytes); index += idBytes
        var constructionMethod: Int64 = 0
        if (version == 1 || version == 2) {
            if (index + 2 > box.end) { return false }
            constructionMethod = rasterBig16(value, index) & 0xF; index += 2
        }
        if (index + 2 + baseOffsetSize + 2 > box.end) { return false }
        let dataReference = rasterBig16(value, index); index += 2
        let baseOffset = rasterBigN(value, index, baseOffsetSize); index += baseOffsetSize
        let extentCount = rasterBig16(value, index); index += 2
        var extent: Int64 = 0
        while (extent < extentCount) {
            if (index + indexSize + offsetSize + lengthSize > box.end) { return false }
            index += indexSize
            let extentOffset = rasterBigN(value, index, offsetSize); index += offsetSize
            let extentLength = rasterBigN(value, index, lengthSize); index += lengthSize
            if (!found && item == primary && dataReference == 0 && constructionMethod == 0 &&
                extentLength > 0 && baseOffset >= 0 && extentOffset >= 0 &&
                baseOffset <= value.size - extentOffset) {
                let start = baseOffset + extentOffset
                if (start <= value.size - extentLength) {
                    found = rasterAvifOrderedPayloadRangeContains(mediaPayloads, start,
                        start + extentLength)
                }
            }
            extent++
        }
        itemIndex++
    }
    index == box.end && found
}

private func rasterAvifPrimaryIsImage(value: Array<Byte>, box: RasterBox,
    primary: Int64): Bool {
    if (box.end - box.payloadStart < 6) { return false }
    let version = value[box.payloadStart]
    if (version > 1) { return false }
    var index = box.payloadStart + 4
    let countBytes: Int64 = if (version == 0) { 2 } else { 4 }
    if (index + countBytes > box.end) { return false }
    let count = rasterBigN(value, index, countBytes); index += countBytes
    var seen: Int64 = 0
    while (seen < count && index < box.end) {
        let child = match (rasterBox(value, index, box.end)) {
            case Some(found) => found
            case None => return false
        }
        if (!rasterFourCc(value, child.kindOffset, "infe") ||
            child.end - child.payloadStart < 12) { return false }
        let infeVersion = value[child.payloadStart]
        if (infeVersion == 2 || infeVersion == 3) {
            let idBytes: Int64 = if (infeVersion == 2) { 2 } else { 4 }
            let item = rasterBigN(value, child.payloadStart + 4, idBytes)
            let typeOffset = child.payloadStart + 4 + idBytes + 2
            if (item == primary && rasterFourCc(value, typeOffset, "av01")) { return true }
        }
        index = child.end
        seen++
    }
    false
}

private func rasterAvifDimensions(value: Array<Byte>): ?RasterDimensions {
    if (value.size < 32) { return None }
    var index: Int64 = 0
    var hasAvif = false
    var animated = false
    var meta: ?RasterBox = None
    var mediaPayloads = ArrayList<(Int64, Int64)>()
    var first = true
    while (index < value.size) {
        let box = match (rasterBox(value, index, value.size)) {
            case Some(found) => found
            case None => return None
        }
        if (first) {
            if (!rasterFourCc(value, box.kindOffset, "ftyp") ||
                box.end - box.payloadStart < 8 || (box.end - box.payloadStart) % 4 != 0) {
                return None
            }
            var brand = box.payloadStart
            while (brand + 4 <= box.end) {
                if (brand != box.payloadStart + 4) {
                    if (rasterFourCc(value, brand, "avif")) { hasAvif = true }
                    if (rasterFourCc(value, brand, "avis")) { animated = true }
                }
                brand += 4
            }
            first = false
        } else if (rasterFourCc(value, box.kindOffset, "meta")) {
            if (meta.isSome()) { return None }
            meta = Some(box)
        } else if (rasterFourCc(value, box.kindOffset, "mdat")) {
            if (box.end > box.payloadStart) {
                mediaPayloads.add((box.payloadStart, box.end))
            }
        }
        index = box.end
    }
    let orderedMediaPayloads = mediaPayloads.toArray()
    if (!hasAvif || animated || meta.isNone() ||
        !rasterAvifPayloadRangesAreOrdered(orderedMediaPayloads)) { return None }
    let metaBox = meta.getOrThrow()
    if (metaBox.end - metaBox.payloadStart < 4 ||
        rasterBig32(value, metaBox.payloadStart) != 0) { return None }
    index = metaBox.payloadStart + 4
    var primary: Int64 = -1
    var properties: ?RasterBox = None
    var locations: ?RasterBox = None
    var itemInfo: ?RasterBox = None
    while (index < metaBox.end) {
        let child = match (rasterBox(value, index, metaBox.end)) {
            case Some(found) => found
            case None => return None
        }
        if (rasterFourCc(value, child.kindOffset, "pitm")) {
            if (child.end - child.payloadStart < 6) { return None }
            let version = value[child.payloadStart]
            primary = if (version == 0) {
                rasterBig16(value, child.payloadStart + 4)
            } else if (version == 1 && child.end - child.payloadStart >= 8) {
                rasterBig32(value, child.payloadStart + 4)
            } else { return None }
        }
        if (rasterFourCc(value, child.kindOffset, "iprp")) { properties = Some(child) }
        if (rasterFourCc(value, child.kindOffset, "iloc")) { locations = Some(child) }
        if (rasterFourCc(value, child.kindOffset, "iinf")) { itemInfo = Some(child) }
        index = child.end
    }
    if (primary < 0 || properties.isNone() || locations.isNone() || itemInfo.isNone() ||
        !rasterAvifPrimaryIsImage(value, itemInfo.getOrThrow(), primary) ||
        !rasterAvifLocationHasPayload(value, locations.getOrThrow(), primary,
            orderedMediaPayloads)) { return None }
    rasterAvifProperties(value, properties.getOrThrow(), primary)
}

private func rasterDimensions(mediaType: String, value: Array<Byte>): ?RasterDimensions {
    match (mediaType) {
        case "image/png" => rasterPngDimensions(value)
        case "image/jpeg" => rasterJpegDimensions(value)
        case "image/gif" => rasterGifDimensions(value)
        case "image/webp" => rasterWebpDimensions(value)
        case "image/avif" => rasterAvifDimensions(value)
        case _ => None
    }
}

protected func validateRasterAsset(mediaType: String, bytes: Array<Byte>): Int64 {
    if (bytes.isEmpty() || bytes.size > DOC_IR_MAX_ASSET_BYTES) {
        throw IllegalArgumentException("raster asset byte size is outside the supported limit")
    }
    if (mediaType != "image/png" && mediaType != "image/jpeg" &&
        mediaType != "image/gif" && mediaType != "image/webp" &&
        mediaType != "image/avif") {
        throw IllegalArgumentException("raster asset media type is unsupported")
    }
    let dimensions = match (rasterDimensions(mediaType, bytes)) {
        case Some(found) => found
        case None => throw IllegalArgumentException(
            "raster asset container, payload, or dimensions are invalid")
    }
    if (dimensions.width <= 0 || dimensions.height <= 0 ||
        dimensions.width > DOC_IR_MAX_ASSET_DIMENSION ||
        dimensions.height > DOC_IR_MAX_ASSET_DIMENSION ||
        dimensions.width > DOC_IR_MAX_ASSET_PIXELS / dimensions.height) {
        throw IllegalArgumentException("raster asset dimensions or pixel count exceed the limit")
    }
    dimensions.width * dimensions.height
}
