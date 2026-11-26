protected package cjdoc.semantic.chir

import cjdoc.source.discovery.SyntaxSourceProvider
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let IMPORT_FACT_PACKAGE = "import_fact_probe"

private func projectWithImport(importLine: String): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src/helper"), recursive: true)
    File.writeTo(root.join("cjpm.toml"),
        ("[package]\ncjc-version = \"1.2.0\"\nname = \"${IMPORT_FACT_PACKAGE}\"\n" +
         "version = \"1.0.0\"\noutput-type = \"static\"\n").toArray())
    File.writeTo(root.join("src/api.cj"),
        ("package ${IMPORT_FACT_PACKAGE}\n${importLine}\n" +
         "public func answer(): Int64 { value() }\n").toArray())
    File.writeTo(root.join("src/helper/api.cj"),
        "package ${IMPORT_FACT_PACKAGE}.helper\npublic func value(): Int64 { 42 }\n".toArray())
    root
}

private func chirDependencyNames(project: Path): Array<String> {
    let source = SyntaxSourceProvider(astPreflightExecutable: Some("target/release/bin/main"))
        .collect(project.toString())
    let names = ArrayList<String>()
    for (packageDoc in chirPackageDependencies(source, source.modules[0].id,
        IMPORT_FACT_PACKAGE)) {
        names.add(packageDoc.name)
    }
    names.toArray()
}

@Test
class ImportDependencySelectionTest {
    @TestCase
    func chirSelectionKeepsLegalSpellingsThatUsedToBeDropped(): Unit {
        for (importLine in ["import ${IMPORT_FACT_PACKAGE}.helper.value",
            "import\t${IMPORT_FACT_PACKAGE}.helper.value",
            "private import ${IMPORT_FACT_PACKAGE}.helper.value",
            "import ${IMPORT_FACT_PACKAGE}.helper.value as value",
            "import ${IMPORT_FACT_PACKAGE}.helper.{value}"]) {
            let project = projectWithImport(importLine)
            try {
                @Expect(chirDependencyNames(project), ["${IMPORT_FACT_PACKAGE}.helper"])
            } finally {
                let _ = removeIfExists(project, recursive: true)
            }
        }
    }

    @TestCase
    func chirSelectionIgnoresAnUnmatchedSiblingPrefix(): Unit {
        let project = projectWithImport("import ${IMPORT_FACT_PACKAGE}.helper.value")
        try {
            Directory.create(project.join("src/helper_extra"))
            File.writeTo(project.join("src/helper_extra/api.cj"),
                "package ${IMPORT_FACT_PACKAGE}.helper_extra\npublic func other(): Int64 { 1 }\n"
                    .toArray())
            @Expect(chirDependencyNames(project), ["${IMPORT_FACT_PACKAGE}.helper"])
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }
}
