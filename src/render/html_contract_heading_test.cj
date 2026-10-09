package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func renderedBehaviorContractTags(tags: Array<DocTag>, locale: String): String {
    let comment = DocComment("raw", "summary", "", MarkdownNode("document"), tags: tags)
    let out = RenderTextBuffer()
    appendDocumentationContractsHtml(out, comment, locale, "contract-fixture")
    out.toString()
}

@Test
class HtmlContractHeadingTest {
    @TestCase
    func solePostconditionUsesSpecificHeadingAndOriginalAnchor(): Unit {
        let tags = [DocTag("postcondition", "", "New item equals value.toString().")]
        let zh = renderedBehaviorContractTags(tags, "zh-CN")
        let en = renderedBehaviorContractTags(tags, "en")
        @Expect(zh.contains("id=\"contract-fixture--behavior-contracts-heading\">后置条件</h3>"), true)
        @Expect(en.contains("id=\"contract-fixture--behavior-contracts-heading\">Postcondition</h3>"), true)
        @Expect(zh.contains("behavior-contract-single"), true)
        @Expect(zh.contains("value.toString()"), true)
        @Expect(!zh.contains("行为契约"), true)
        @Expect(!zh.contains("<dt>"), true)
    }

    @TestCase
    func solePreconditionKeepsSubjectAndMissingDescriptionStatus(): Unit {
        let present = renderedBehaviorContractTags([
            DocTag("precondition", "index", "index is within bounds")], "zh-CN")
        @Expect(present.contains("前置条件</h3>"), true)
        @Expect(present.contains("behavior-contract-subject"), true)
        @Expect(present.contains("<code>index</code>"), true)
        @Expect(present.contains("index is within bounds"), true)

        let incomplete = renderedBehaviorContractTags([
            DocTag("precondition", "", "")], "en")
        @Expect(incomplete.contains("Precondition</h3>"), true)
        @Expect(incomplete.contains("data-state=\"incomplete\""), true)
        @Expect(incomplete.contains("incomplete"), true)
    }

    @TestCase
    func multipleContractsRetainTypeLabelsSubjectsAndDescriptions(): Unit {
        let tags = [
            DocTag("precondition", "index", "index >= 0"),
            DocTag("postcondition", "", "the result is stable"),
            DocTag("concurrency", "", "callers synchronize externally")
        ]
        let zh = renderedBehaviorContractTags(tags, "zh-CN")
        let en = renderedBehaviorContractTags(tags, "en")
        @Expect(zh.contains("行为约束</h3><dl>"), true)
        @Expect(en.contains("Behavioral constraints</h3><dl>"), true)
        @Expect(zh.contains("<code>前置条件</code>"), true)
        @Expect(zh.contains("<code>后置条件</code>"), true)
        @Expect(zh.contains("<code>并发</code>"), true)
        @Expect(en.contains("<code>index</code>"), true)
        @Expect(en.contains("the result is stable"), true)
        @Expect(en.contains("callers synchronize externally"), true)
        @Expect(!en.contains("Behavior contracts"), true)
    }

    @TestCase
    func noContractTagsProduceNoSection(): Unit {
        let html = renderedBehaviorContractTags([
            DocTag("return", "", "unrelated documentation")], "zh-CN")
        @Expect(html.isEmpty(), true)
    }
}
