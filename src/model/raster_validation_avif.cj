package cjdoc.model

import std.collection.*

internal func rasterWebpDimensions(value: Array<Byte>): ?RasterDimensions {
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

internal class RasterBox {
    let kindOffset: Int64
    let payloadStart: Int64
    let end: Int64
    init(kindOffset: Int64, payloadStart: Int64, end: Int64) {
        this.kindOffset = kindOffset; this.payloadStart = payloadStart; this.end = end
    }
}

internal func rasterBox(value: Array<Byte>, start: Int64, end: Int64): ?RasterBox {
    if (start < 0 || start + 8 > end || end > value.size) { return None }
    let size = rasterBig32(value, start)
    if (size < 8 || size > end - start) { return None }
    Some(RasterBox(start + 4, start + 8, start + size))
}

internal func rasterBigN(value: Array<Byte>, offset: Int64, count: Int64): Int64 {
    if (count < 0 || count > 4 || offset < 0 || offset + count > value.size) { return -1 }
    var result: Int64 = 0
    var index: Int64 = 0
    while (index < count) { result = (result << 8) | Int64(value[offset + index]); index++ }
    result
}

internal class AvifPropertyState {
    let dimensionsByIndex = HashMap<Int64, RasterDimensions>()
    var propertyCount: Int64 = 0
    var primaryHasDimensions = false
}

internal func rasterAvifProperties(value: Array<Byte>, box: RasterBox,
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

internal func rasterAvifLocationHasPayload(value: Array<Byte>, box: RasterBox,
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

internal func rasterAvifPrimaryIsImage(value: Array<Byte>, box: RasterBox,
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

internal func rasterAvifDimensions(value: Array<Byte>): ?RasterDimensions {
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

internal func rasterDimensions(mediaType: String, value: Array<Byte>): ?RasterDimensions {
    match (mediaType) {
        case "image/png" => rasterPngDimensions(value)
        case "image/jpeg" => rasterJpegDimensions(value)
        case "image/gif" => rasterGifDimensions(value)
        case "image/webp" => rasterWebpDimensions(value)
        case "image/avif" => rasterAvifDimensions(value)
        case _ => None
    }
}
