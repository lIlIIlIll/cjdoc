package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCodecV8Suite3 {
    @TestCase
    func fencedCodeAndOrderedListBoundsFailClosed(): Unit {
        let boundedFence = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("~"), DOC_IR_MAX_FENCE_LENGTH, "cj", "cj", ""), literal: "main()")
        validateDocumentationSet(codecMarkdownDocument(MarkdownNode("document",
            children: [boundedFence])))

        let oversizedFence = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("~"), DOC_IR_MAX_FENCE_LENGTH + 1, "", "", ""), literal: "main()")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [oversizedFence]))))

        let collidingFence = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("`"), 3, "", "", ""), literal: "```")
        let collidingDocument = codecMarkdownDocument(
            MarkdownNode("document", children: [collidingFence]))
        let collidingJson = encodeDocIr(collidingDocument)
        @Expect(decodeDocIr(collidingJson).declarations.size, 1)

        let invalidBacktickInfo = MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3,
                "cj`unsafe", "cj", ""), literal: "main()")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [invalidBacktickInfo]))))

        let tildeWithBacktickInfo = MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("~"), 3,
                "cj`safe", "cj", ""), literal: "main()")
        let tildeJson = encodeDocIr(codecMarkdownDocument(
            MarkdownNode("document", children: [tildeWithBacktickInfo])))
        @Expect(decodeDocIr(tildeJson).declarations.size, 1)
        let invalidBacktickJson = tildeJson.replace(
            "\"fenceCharacter\": \"~\"", "\"fenceCharacter\": \"`\"")
        @Expect(invalidBacktickJson != tildeJson)
        let infoError = @AssertThrows[IllegalArgumentException](decodeDocIr(invalidBacktickJson))
        @Expect(infoError.message.contains("invalid Doc IR schema"))

        let multilineInfo = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("~"), 3, "cj\nunsafe", "cj", ""), literal: "main()")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [multilineInfo]))))

        let item = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("notTask"),
            children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "item")])])
        let overflowingList = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            9223372036854775807, "period", true), children: [item, item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [overflowingList]))))

        let lastNineDigitItem = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            DOC_IR_MAX_ORDERED_LIST_NUMBER, "period", true), children: [item])
        validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [lastNineDigitItem])))
        let sequenceBecomesTenDigits = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            DOC_IR_MAX_ORDERED_LIST_NUMBER, "period", true), children: [item, item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [sequenceBecomesTenDigits]))))
        let tenDigitStart = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            DOC_IR_MAX_ORDERED_LIST_NUMBER + 1, "period", true), children: [item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [tenDigitStart]))))
        let zeroOrdered = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            0, "period", true), children: [item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [zeroOrdered]))))
        let nonzeroBullet = MarkdownNode("list", MarkdownNodeMetadata.forList("bullet",
            1, "none", true), children: [item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [nonzeroBullet]))))

        let orderedJson = encodeDocIr(codecMarkdownDocument(MarkdownNode("document",
            children: [MarkdownNode("list", MarkdownNodeMetadata.forList("ordered", 3,
                "period", true), children: [item])])))
        let zeroOrderedJson = orderedJson.replace("\"start\": 3", "\"start\": 0")
        @Expect(zeroOrderedJson != orderedJson)
        let orderedSchemaError = @AssertThrows[IllegalArgumentException](decodeDocIr(zeroOrderedJson))
        @Expect(orderedSchemaError.message.contains("invalid Doc IR schema"))
    }

    @TestCase
    func markdownGrammarAndTableMetadataAreClosed(): Unit {
        let paragraph = MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "cell")])
        let invalidList = MarkdownNode("list", MarkdownNodeMetadata.forList("bullet", 0, "none", true),
            children: [paragraph])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [invalidList]))))

        let invalidParagraph = MarkdownNode("paragraph", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("indented", None<String>, 0, "", "", ""), literal: "code")])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [invalidParagraph]))))

        let headerCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("left"),
            children: [MarkdownNode("text", literal: "name")])
        let bodyCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("left"),
            children: [MarkdownNode("text", literal: "value")])
        let header = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true),
            children: [headerCell])
        let body = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(false),
            children: [bodyCell])
        let validTable = MarkdownNode("table", MarkdownNodeMetadata.forTable(["left"]),
            children: [header, body])
        validateDocumentationSet(codecMarkdownDocument(MarkdownNode("document", children: [validTable])))

        let wrongHeader = MarkdownNode("table", MarkdownNodeMetadata.forTable(["left"]),
            children: [MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(false),
                children: [headerCell])])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [wrongHeader]))))

        let wrongAlignment = MarkdownNode("table", MarkdownNodeMetadata.forTable(["right"]),
            children: [header])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [wrongAlignment]))))

        let legacyTable = MarkdownNode("table", children: [MarkdownNode("table_row",
            children: [MarkdownNode("table_cell", children: [MarkdownNode("text", literal: "legacy")])])])
        validateDocumentationSet(codecMarkdownDocument(MarkdownNode("document", children: [legacyTable])))
    }

    @TestCase
    func contentAddressedImagesMustResolveButRelativeReferencesMayRemainMissing(): Unit {
        let relative = MarkdownNode("document", children: [MarkdownNode("paragraph", children: [
            MarkdownNode("image", literal: "images/missing.png",
                children: [MarkdownNode("text", literal: "missing")])
        ])])
        validateDocumentationSet(codecMarkdownDocument(relative))

        let dangling = MarkdownNode("document", children: [MarkdownNode("paragraph", children: [
            MarkdownNode("image", literal: "sha256-0000000000000000000000000000000000000000000000000000000000000000",
                children: [MarkdownNode("text", literal: "missing")])
        ])])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(dangling)))
    }

    @TestCase
    func imageAssetsRequireCompleteRasterStructureAndTotalPixelBudget(): Unit {
        let truncated = codecAsset("R0lGODlh", "images/truncated.gif")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecMarkdownDocument(MarkdownNode("document"), assets: [truncated])))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(V7_CODEC_FIXTURE.replace(
            "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "R0lGODlh")))

        // Each image declares an 8192x8192 logical canvas (67,108,864
        // pixels) and passes the per-image limit. Three distinct payloads
        // exceed the 200,000,000-pixel document budget.
        let largeAssets = [
            codecAsset("R0lGODlhACAAIIAAAAAAAP///ywAAAAAAQAgACACAUwAOw==", "images/large-0.gif"),
            codecAsset("R0lGODlhACAAIIAAAAAAAP///ywAAAAAAQAgACACAU0AOw==", "images/large-1.gif"),
            codecAsset("R0lGODlhACAAIIAAAAAAAP///ywAAAAAAQAgACACAU4AOw==", "images/large-2.gif")
        ]
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document"), assets: largeAssets)))
    }


}
