package cjdoc

import cjdoc.model.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func rasterTestBig32(value: Int64): Array<Byte> {
    let bits = UInt64(value)
    [UInt8((bits >> 24) & 0xFF), UInt8((bits >> 16) & 0xFF),
        UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
}

private func rasterTestBig16(value: Int64): Array<Byte> {
    let bits = UInt64(value)
    [UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
}

private func rasterTestBox(kind: String, payload: Array<Byte>): Array<Byte> {
    let out = ArrayList<Byte>()
    out.add(all: rasterTestBig32(payload.size + 8))
    out.add(all: kind.toArray())
    out.add(all: payload)
    out.toArray()
}

private func rasterTestAppend(target: ArrayList<Byte>, parts: Array<Array<Byte>>): Unit {
    for (part in parts) { target.add(all: part) }
}

private func rasterTestUnassociatedAvif(): Array<Byte> {
    let ftypPayload = ArrayList<Byte>()
    rasterTestAppend(ftypPayload, ["avif".toArray(), [0, 0, 0, 0],
        "avif".toArray(), "mif1".toArray()])
    let ftyp = rasterTestBox("ftyp", ftypPayload.toArray())

    let pitm = rasterTestBox("pitm", [0, 0, 0, 0, 0, 1])
    let infePayload = ArrayList<Byte>()
    rasterTestAppend(infePayload, [[2, 0, 0, 0, 0, 1, 0, 0], "av01".toArray()])
    let infe = rasterTestBox("infe", infePayload.toArray())
    let iinfPayload = ArrayList<Byte>()
    rasterTestAppend(iinfPayload, [[0, 0, 0, 0, 0, 1], infe])
    let iinf = rasterTestBox("iinf", iinfPayload.toArray())

    let ispePayload = ArrayList<Byte>()
    rasterTestAppend(ispePayload, [[0, 0, 0, 0], rasterTestBig32(1), rasterTestBig32(1)])
    let ipco = rasterTestBox("ipco", rasterTestBox("ispe", ispePayload.toArray()))
    let ipma = rasterTestBox("ipma", [0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0])
    let iprpPayload = ArrayList<Byte>()
    rasterTestAppend(iprpPayload, [ipco, ipma])
    let iprp = rasterTestBox("iprp", iprpPayload.toArray())

    let placeholderLocation: Array<Byte> = [
        0, 0, 0, 0, 0x44, 0, 0, 1, 0, 1, 0, 0, 0, 1,
        0, 0, 0, 0, 0, 0, 0, 1
    ]
    let placeholderMetaPayload = ArrayList<Byte>()
    rasterTestAppend(placeholderMetaPayload, [[0, 0, 0, 0], pitm, iinf, iprp,
        rasterTestBox("iloc", placeholderLocation)])
    let payloadOffset = ftyp.size + rasterTestBox("meta",
        placeholderMetaPayload.toArray()).size + 8
    let location = ArrayList<Byte>()
    location.add(all: placeholderLocation[0..14])
    location.add(all: rasterTestBig32(payloadOffset))
    location.add(all: placeholderLocation[18..22])
    let metaPayload = ArrayList<Byte>()
    rasterTestAppend(metaPayload, [[0, 0, 0, 0], pitm, iinf, iprp,
        rasterTestBox("iloc", location.toArray())])
    let result = ArrayList<Byte>()
    rasterTestAppend(result, [ftyp, rasterTestBox("meta", metaPayload.toArray()),
        rasterTestBox("mdat", [0x01])])
    result.toArray()
}

private func rasterTestIloc(extents: Array<(Int64, Int64)>): Array<Byte> {
    let payload = ArrayList<Byte>()
    rasterTestAppend(payload, [[0, 0, 0, 0, 0x44, 0, 0, 1, 0, 1, 0, 0],
        rasterTestBig16(extents.size)])
    for ((offset, length) in extents) {
        rasterTestAppend(payload, [rasterTestBig32(offset), rasterTestBig32(length)])
    }
    rasterTestBox("iloc", payload.toArray())
}

private func rasterTestAvifMeta(iloc: Array<Byte>): Array<Byte> {
    let pitm = rasterTestBox("pitm", [0, 0, 0, 0, 0, 1])
    let infePayload = ArrayList<Byte>()
    rasterTestAppend(infePayload, [[2, 0, 0, 0, 0, 1, 0, 0], "av01".toArray()])
    let infe = rasterTestBox("infe", infePayload.toArray())
    let iinfPayload = ArrayList<Byte>()
    rasterTestAppend(iinfPayload, [[0, 0, 0, 0, 0, 1], infe])
    let iinf = rasterTestBox("iinf", iinfPayload.toArray())

    let ispePayload = ArrayList<Byte>()
    rasterTestAppend(ispePayload, [[0, 0, 0, 0], rasterTestBig32(1), rasterTestBig32(1)])
    let ipco = rasterTestBox("ipco", rasterTestBox("ispe", ispePayload.toArray()))
    let ipma = rasterTestBox("ipma", [0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1])
    let iprpPayload = ArrayList<Byte>()
    rasterTestAppend(iprpPayload, [ipco, ipma])
    let metaPayload = ArrayList<Byte>()
    rasterTestAppend(metaPayload, [[0, 0, 0, 0], pitm, iinf,
        rasterTestBox("iprp", iprpPayload.toArray()), iloc])
    rasterTestBox("meta", metaPayload.toArray())
}

private func rasterTestManyExtentAvif(mediaCount: Int64): Array<Byte> {
    let ftypPayload = ArrayList<Byte>()
    rasterTestAppend(ftypPayload, ["avif".toArray(), [0, 0, 0, 0],
        "avif".toArray(), "mif1".toArray()])
    let ftyp = rasterTestBox("ftyp", ftypPayload.toArray())

    let placeholderExtents = ArrayList<(Int64, Int64)>()
    var index: Int64 = 0
    while (index < mediaCount) {
        placeholderExtents.add((0, 1))
        index++
    }
    let placeholderMeta = rasterTestAvifMeta(
        rasterTestIloc(placeholderExtents.toArray()))
    let mediaStart = ftyp.size + placeholderMeta.size
    let extents = ArrayList<(Int64, Int64)>()
    index = 0
    while (index < mediaCount) {
        let payloadStart = mediaStart + index * 9 + 8
        // Every earlier extent lands in the following box header. The final
        // extent is valid, so a validator must examine all predecessors.
        let offset = if (index + 1 == mediaCount) { payloadStart } else { payloadStart + 1 }
        extents.add((offset, 1))
        index++
    }
    let result = ArrayList<Byte>()
    rasterTestAppend(result, [ftyp, rasterTestAvifMeta(rasterTestIloc(extents.toArray()))])
    index = 0
    while (index < mediaCount) {
        result.add(all: rasterTestBox("mdat", [UInt8(index & 0xFF)]))
        index++
    }
    result.toArray()
}

@Test
class LocalAssetPipelineTest {
    @TestCase
    func singleAndAggregateAssetBudgetsUseInclusiveLimits(): Unit {
        let itemLimit: Int64 = 16 * 1024 * 1024
        let totalLimit: Int64 = 64 * 1024 * 1024

        @Expect(localAssetBudgetAllows(0, itemLimit))
        @Expect(!localAssetBudgetAllows(0, itemLimit + 1))
        @Expect(localAssetBudgetAllows(totalLimit - itemLimit, itemLimit))
        @Expect(!localAssetBudgetAllows(totalLimit - itemLimit + 1, itemLimit))
        @Expect(!localAssetBudgetAllows(0, 0))
        @Expect(!localAssetBudgetAllows(-1, 1))
        @Expect(localAssetInspectionBudgetAllows(totalLimit - 1, 1, totalLimit))
        @Expect(!localAssetInspectionBudgetAllows(totalLimit, 1, totalLimit))
    }

    @TestCase
    func filesystemRootProducesTheWholeRelativePath(): Unit {
        @Expect(localAssetRelativePath("/", "/tmp/image.gif"), Some("tmp/image.gif"))
        @Expect(localAssetRelativePath("/project", "/project/image.gif"), Some("image.gif"))
        @Expect(localAssetRelativePath("/project", "/other/image.gif"), None<String>)
    }

    @TestCase
    func rasterValidatorRejectsAnimationAndMetadataOnlyGif(): Unit {
        let image = File.readFrom(
            Path("tests/fixtures/projects/local_assets/src/images/pixel.gif"))
        @Expect(validateRasterAsset("image/gif", image), 1)

        let animated = ArrayList<Byte>()
        animated.add(all: image[0..42])
        animated.add(all: image[27..42])
        animated.add(0x3B)
        @ExpectThrows[IllegalArgumentException](
            validateRasterAsset("image/gif", animated.toArray()))

        let metadataOnly = ArrayList<Byte>()
        metadataOnly.add(all: image[0..19])
        metadataOnly.add(0x3B)
        @ExpectThrows[IllegalArgumentException](
            validateRasterAsset("image/gif", metadataOnly.toArray()))
    }

    @TestCase
    func rasterValidatorRejectsAnimatedAndMetadataOnlyWebp(): Unit {
        let animated: Array<Byte> = [
            b'R', b'I', b'F', b'F', 22, 0, 0, 0, b'W', b'E', b'B', b'P',
            b'V', b'P', b'8', b'X', 10, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ]
        @ExpectThrows[IllegalArgumentException](
            validateRasterAsset("image/webp", animated))

        let metadataOnly: Array<Byte> = [
            b'R', b'I', b'F', b'F', 22, 0, 0, 0, b'W', b'E', b'B', b'P',
            b'V', b'P', b'8', b'X', 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ]
        @ExpectThrows[IllegalArgumentException](
            validateRasterAsset("image/webp", metadataOnly))
    }

    @TestCase
    func rasterValidatorRejectsAnimatedAndUnassociatedAvif(): Unit {
        let avis: Array<Byte> = [
            0, 0, 0, 24, b'f', b't', b'y', b'p', b'a', b'v', b'i', b's',
            0, 0, 0, 0, b'a', b'v', b'i', b's', b'm', b'i', b'f', b'1',
            0, 0, 0, 9, b'm', b'd', b'a', b't', 0x01
        ]
        @ExpectThrows[IllegalArgumentException](validateRasterAsset("image/avif", avis))
        @ExpectThrows[IllegalArgumentException](
            validateRasterAsset("image/avif", rasterTestUnassociatedAvif()))
    }

    @TestCase
    func avifPayloadLookupRejectsGapsCrossingsAndInvalidIndexes(): Unit {
        let ordered: Array<(Int64, Int64)> = [(8, 12), (20, 24), (32, 40)]
        @Expect(rasterAvifPayloadRangesAreOrdered(ordered))
        @Expect(rasterAvifOrderedPayloadRangeContains(ordered, 20, 24))
        @Expect(!rasterAvifOrderedPayloadRangeContains(ordered, 13, 14))
        @Expect(!rasterAvifOrderedPayloadRangeContains(ordered, 11, 21))
        @Expect(!rasterAvifPayloadRangesAreOrdered([(20, 24), (8, 12)]))
        @Expect(!rasterAvifPayloadRangesAreOrdered([(8, 21), (20, 24)]))
    }

    @TestCase
    func rasterValidatorAcceptsManyAvifMediaPayloadsAndExtents(): Unit {
        @Expect(validateRasterAsset("image/avif", rasterTestManyExtentAvif(4096)), 1)
    }
}
