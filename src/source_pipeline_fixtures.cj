package cjdoc

import cjdoc.model as api_model
import std.process.*


internal let FIXTURES = "tests/fixtures/projects/"
internal let TEST_AST_PREFLIGHT = Some("target/release/bin/main")

internal func generateFixture(name: String, lintProfile!: String = "off",
    includePathDependencies!: Bool = false, includeCachedDependencies!: Bool = false,
    dependencySources!: Array<DependencySourceInput> = [], cfgValues!: Array<CfgValue> = [],
    cacheDirectory!: ?String = None, cjpmCacheRoot!: ?String = None,
    jobs!: Int64 = 1): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(FIXTURES + name,
        lintProfile: lintProfile, audience: "all",
        includePathDependencies: includePathDependencies,
        includeCachedDependencies: includeCachedDependencies,
        dependencySources: dependencySources, cfgValues: cfgValues,
        cacheDirectory: cacheDirectory, cacheFingerprint: Some("source-pipeline-regressions-v1"),
        cjpmCacheRoot: cjpmCacheRoot,
        jobs: jobs,
        astPreflightExecutable: TEST_AST_PREFLIGHT))
}

internal func containsDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

internal func declarationNamed(documentation: api_model.DocumentationSet,
    name: String): api_model.SymbolDoc {
    for (declaration in documentation.declarations) {
        if (declaration.name == name) { return declaration }
    }
    throw IllegalStateException("fixture declaration '${name}' not found")
}

internal func markdownNodeNamed(node: api_model.MarkdownNode,
    kind: String): ?api_model.MarkdownNode {
    if (node.kind == kind) { return Some(node) }
    for (child in node.children) {
        if (let Some(found) <- markdownNodeNamed(child, kind)) { return Some(found) }
    }
    None
}

internal func diagnosticCount(documentation: api_model.DocumentationSet, code: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { count++ }
    }
    count
}

internal func testCjpmTarget(): String {
    let (exitCode, output, _) = executeWithOutput("cjc", ["--version"])
    if (exitCode != 0) { throw IllegalStateException("cjc --version failed") }
    for (line in String.fromUtf8(output).split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("Target:")) {
            return trimmed.removePrefix("Target:").trimAscii()
        }
    }
    throw IllegalStateException("cjc --version did not report Target")
}
