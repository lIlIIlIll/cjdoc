package cjdoc

import cjdoc.source.discovery.SyntaxSourceProvider
import cjdoc.source.frontend.{sourceImportFactsFromText, sourceImportTextsFromSource}
import cjdoc.source.model.SourceImportFacts
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// CHIR and example dependency selection both consume these captured AST facts.
private let IMPORT_FACT_PACKAGE = "import_fact_probe"

private func importFactSource(importLine: String): String {
    "package ${IMPORT_FACT_PACKAGE}\n${importLine}\npublic func answer(): Int64 { 1 }\n"
}

private func importFactsFor(importLine: String): Array<SourceImportFacts> {
    let texts = sourceImportTextsFromSource("src/api.cj", importFactSource(importLine), false)
    @Expect(texts.size, 1)
    let facts = sourceImportFactsFromText("src/api.cj", texts[0])
    @Expect(facts.size, 1)
    facts
}

private func referencePaths(facts: Array<SourceImportFacts>): Array<String> {
    let result = ArrayList<String>()
    for (entry in facts) {
        for (reference in entry.referencePaths()) {
            let qualified = if (entry.organization.isEmpty()) {
                reference
            } else {
                entry.organization + "::" + reference
            }
            result.add(qualified)
        }
    }
    result.toArray()
}

private func hasReference(facts: Array<SourceImportFacts>, expected: String): Bool {
    for (reference in referencePaths(facts)) {
        if (reference == expected) { return true }
    }
    false
}

@Test
class SourceImportFactTest {
    @TestCase
    func legalImportSpellingsProduceTheSamePackageReference(): Unit {
        let expected = "${IMPORT_FACT_PACKAGE}.helper.value"
        for (importLine in ["import ${IMPORT_FACT_PACKAGE}.helper.value",
            "import\t${IMPORT_FACT_PACKAGE}.helper.value",
            "private import ${IMPORT_FACT_PACKAGE}.helper.value",
            "internal import ${IMPORT_FACT_PACKAGE}.helper.value",
            "protected import ${IMPORT_FACT_PACKAGE}.helper.value",
            "public import ${IMPORT_FACT_PACKAGE}.helper.value",
            "import  ${IMPORT_FACT_PACKAGE}.helper.value"]) {
            let facts = importFactsFor(importLine)
            @Expect(hasReference(facts, expected), true)
        }
    }

    @TestCase
    func modifierIsCapturedRatherThanStripped(): Unit {
        @Expect(importFactsFor("private import ${IMPORT_FACT_PACKAGE}.helper.value")[0].modifier,
            "private")
        @Expect(importFactsFor("import\t${IMPORT_FACT_PACKAGE}.helper.value")[0].modifier, "")
        @Expect(importFactsFor("public import ${IMPORT_FACT_PACKAGE}.helper.*")[0].modifier,
            "public")
    }

    @TestCase
    func aliasAndSelectionListKeepEveryReference(): Unit {
        let aliased = importFactsFor(
            "import ${IMPORT_FACT_PACKAGE}.helper.value as answer")
        @Expect(hasReference(aliased, "${IMPORT_FACT_PACKAGE}.helper.value"), true)
        @Expect(aliased[0].alias, Some("answer"))
        let selected = importFactsFor(
            "import ${IMPORT_FACT_PACKAGE}.helper.{value}")
        @Expect(hasReference(selected, "${IMPORT_FACT_PACKAGE}.helper.value"), true)
        @Expect(hasReference(selected, "${IMPORT_FACT_PACKAGE}.helper"), true)
        let many = importFactsFor(
            "import ${IMPORT_FACT_PACKAGE}.helper.{value, other as renamed}")
        @Expect(hasReference(many, "${IMPORT_FACT_PACKAGE}.helper.other"), true)
        @Expect(hasReference(many, "${IMPORT_FACT_PACKAGE}.helper.value"), true)
    }

    @TestCase
    func organizationQualifierIsPreservedOnEveryReference(): Unit {
        let facts = importFactsFor("import sample_org::probe.helper.value")
        @Expect(facts[0].organization, "sample_org")
        @Expect(hasReference(facts, "sample_org::probe.helper.value"), true)
    }

    @TestCase
    func wildcardSelectsThePackageItself(): Unit {
        let facts = importFactsFor("import ${IMPORT_FACT_PACKAGE}.helper.*")
        @Expect(referencePaths(facts), ["${IMPORT_FACT_PACKAGE}.helper"])
    }

    @TestCase
    func factsSurviveTheSourceCacheAndStayAuthoritative(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let project = temporary.join("project")
            let cache = temporary.join("cache")
            Directory.create(project.join("src"), recursive: true)
            Directory.create(cache)
            File.writeTo(project.join("cjpm.toml"),
                "[package]\nname = \"${IMPORT_FACT_PACKAGE}\"\n".toArray())
            File.writeTo(project.join("src/api.cj"),
                importFactSource("private import\t${IMPORT_FACT_PACKAGE}.helper.value").toArray())
            let provider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("import-fact-cache-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT)
            let cold = provider.collect(project.toString())
            @Expect(cold.sourceFileOrigins.size, 1)
            @Expect(referencePaths(cold.sourceFileOrigins[0].importFacts),
                ["${IMPORT_FACT_PACKAGE}.helper.value"])
            let warm = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("import-fact-cache-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT).collect(project.toString())
            @Expect(warm.sourceFileOrigins[0].importFacts.size, 1)
            @Expect(referencePaths(warm.sourceFileOrigins[0].importFacts),
                ["${IMPORT_FACT_PACKAGE}.helper.value"])
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
