package cjdoc

import cjdoc.model as api_model
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func writeCommentPipelineFile(path: Path, text: String): Unit {
    File.writeTo(path, text.toArray())
}

private func readCommentPipelineFile(path: Path): String {
    String.fromUtf8(File.readFrom(path))
}

private func commentDeclaration(documentation: api_model.DocumentationSet,
    name: String): api_model.SymbolDoc {
    for (declaration in documentation.declarations) {
        if (declaration.name == name) { return declaration }
    }
    throw IllegalStateException("declaration '${name}' not found")
}

private func generateCommentProject(root: String, lintProfile!: String = "off"): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(root, lintProfile: lintProfile,
        audience: "all", jobs: 1,
        astPreflightExecutable: Some("target/release/bin/main")))
}

private func commentDiagnosticCodes(documentation: api_model.DocumentationSet): ArrayList<String> {
    let codes = ArrayList<String>()
    for (diagnostic in documentation.diagnostics) { codes.add(diagnostic.code) }
    codes
}

@Test
class CommentSpecPipelineTest {
    @TestCase
    func workspaceDescriptorPolicyIsValidatedButNeverInherited(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let member = root.join("packages").join("alpha")
            Directory.create(member.join("src"), recursive: true)
            writeCommentPipelineFile(root.join("cjpm.toml"),
                "[workspace]\nmembers = [\"packages/alpha\"]\n")
            writeCommentPipelineFile(member.join("cjpm.toml"),
                "[package]\ncjc-version = \"1.1.0\"\nname = \"alpha\"\nversion = \"0.0.0\"\n" +
                "output-type = \"static\"\n\n[dependencies]\n")
            writeCommentPipelineFile(member.join("src").join("alpha.cj"),
                "package alpha\n\n/**\n * Alpha.\n * @maintainer platform.\n */\npublic func alpha(): Unit {}\n")
            // The descriptor directory owns no declarations, so its alias only has
            // to be a valid policy; it must not reach the member's comments.
            writeCommentPipelineFile(root.join("cjdoc.toml"),
                "[comments.aliases]\nmaintainer = \"see\"\n")
            let documentation = generateCommentProject(root.toString())
            @Expect(commentDiagnosticCodes(documentation).contains("CJDOC3139"), false)
            let declaration = commentDeclaration(documentation, "alpha")
            let comment = declaration.documentation.getOrThrow()
            @Expect(comment.tags.size, 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func invalidWorkspaceDescriptorPolicyFailsGeneration(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let member = root.join("packages").join("alpha")
            Directory.create(member.join("src"), recursive: true)
            writeCommentPipelineFile(root.join("cjpm.toml"),
                "[workspace]\nmembers = [\"packages/alpha\"]\n")
            writeCommentPipelineFile(member.join("cjpm.toml"),
                "[package]\ncjc-version = \"1.1.0\"\nname = \"alpha\"\nversion = \"0.0.0\"\n" +
                "output-type = \"static\"\n\n[dependencies]\n")
            writeCommentPipelineFile(member.join("src").join("alpha.cj"),
                "package alpha\n\n/** Alpha. */\npublic func alpha(): Unit {}\n")
            writeCommentPipelineFile(root.join("cjdoc.toml"),
                "[comments.aliases]\nmaintainer = \"nowhere\"\n")
            let error = @AssertThrows[IllegalArgumentException](generateCommentProject(root.toString()))
            @Expect(error.message.contains("CJDOC3139"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func memberPolicyAppliesOnlyToItsOwnModule(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let alpha = root.join("packages").join("alpha")
            let beta = root.join("packages").join("beta")
            Directory.create(alpha.join("src"), recursive: true)
            Directory.create(beta.join("src"), recursive: true)
            writeCommentPipelineFile(root.join("cjpm.toml"),
                "[workspace]\nmembers = [\"packages/alpha\", \"packages/beta\"]\n")
            for (entry in [("alpha", alpha), ("beta", beta)]) {
                writeCommentPipelineFile(entry[1].join("cjpm.toml"),
                    "[package]\ncjc-version = \"1.1.0\"\nname = \"" + entry[0] +
                    "\"\nversion = \"0.0.0\"\noutput-type = \"static\"\n\n[dependencies]\n")
                writeCommentPipelineFile(entry[1].join("src").join(entry[0] + ".cj"),
                    "package " + entry[0] + "\n\n/**\n * " + entry[0] +
                    ".\n * @maintainer platform.\n */\npublic func " + entry[0] + "(): Unit {}\n")
            }
            // Only alpha declares the alias, so beta keeps every line as prose.
            writeCommentPipelineFile(alpha.join("cjdoc.toml"),
                "[comments.aliases]\nmaintainer = \"see\"\n")
            let documentation = generateCommentProject(root.toString())
            @Expect(commentDiagnosticCodes(documentation).contains("CJDOC3139"), false)
            let alphaDeclaration = commentDeclaration(documentation, "alpha")
            let betaDeclaration = commentDeclaration(documentation, "beta")
            @Expect(alphaDeclaration.documentation.getOrThrow().tags.size, 1)
            @Expect(betaDeclaration.documentation.getOrThrow().tags.size, 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}

private func writeRuleProject(root: Path): Unit {
    writeCommentPipelineFile(root.join("cjpm.toml"),
        "[package]\ncjc-version = \"1.1.0\"\nname = \"rules\"\nversion = \"0.0.0\"\n" +
        "output-type = \"static\"\n\n[dependencies]\n")
    Directory.create(root.join("src"), recursive: true)
    writeCommentPipelineFile(root.join("src").join("rules.cj"),
        "package rules\n\n" +
        "/**\n * Documented and owned.\n * @owner platform\n */\npublic func owned(): Unit {}\n\n" +
        "/**\n * Documented without an owner tag.\n */\n" +
        "public func missingOwner(): Unit {}\n\n" +
        "/**\n * Only a trigger tag.\n" +
        " * @deprecated Use something else.\n */\npublic func triggeredWithoutOwner(): Unit {}\n\n" +
        "/**\n * Untagged declaration.\n" +
        " * @since 1.0.0\n */\npublic func untriggered(): Unit {}\n")
    writeCommentPipelineFile(root.join("cjdoc.toml"),
        "[comments.aliases]\nmaintainer = \"owner\"\n" +
        "[[comments.fields]]\nid = \"owner\"\ntitle = \"负责人\"\nrepeatable = true\n" +
        "[comments.fields.titles]\nen = \"Owner\"\n" +
        "[[comments.rules]]\nrequire = \"owner\"\nwhen-present = \"deprecated\"\n" +
        "severity = \"warning\"\n" +
        "[i18n]\ndefault-language = \"en\"\nlanguages = [\"en\"]\n")
}

private func commentRuleDiagnostics(documentation: api_model.DocumentationSet): ArrayList<String> {
    let names = ArrayList<String>()
    for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3142") {
        for (declaration in documentation.declarations) {
            if (diagnostic.symbolId == Some(declaration.id)) { names.add(declaration.name) }
        }
    }
    names
}

@Test
class CommentRuleEvaluationTest {
    @TestCase
    func warningRuleReportsOnlyEnabledTriggers(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            writeRuleProject(root)
            let documentation = generateCommentProject(root.toString(), lintProfile: "standard")
            let reported = commentRuleDiagnostics(documentation)
            @Expect(reported.size, 1)
            @Expect(reported[0], "triggeredWithoutOwner")
            for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3142") {
                @Expect(diagnostic.severity, "warning")
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func offProfileDisablesRulesButKeepsStructureErrors(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            writeRuleProject(root)
            let documentation = generateCommentProject(root.toString(), lintProfile: "off")
            @Expect(commentRuleDiagnostics(documentation).isEmpty(), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func structureErrorSurvivesOffProfile(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            writeRuleProject(root)
            writeCommentPipelineFile(root.join("src").join("rules.cj"),
                readCommentPipelineFile(root.join("src").join("rules.cj")).replace(
                    " * @owner platform\n", " * @owner[lang=en] platform\n"))
            let documentation = generateCommentProject(root.toString(), lintProfile: "off")
            @Expect(commentDiagnosticCodes(documentation).contains("CJDOC3140"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
