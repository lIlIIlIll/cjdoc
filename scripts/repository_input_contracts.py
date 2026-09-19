from __future__ import annotations

import re

COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
MARKDOWN_LICENSE_SHA256 = "0d52dcdcb50af1bfd2c06821c888bdec9683830f79c78863173e3d0b12f2ac19"
MARKDOWN_UPSTREAM = "https://github.com/lIlIIlIll/markdown.git"
YJSON_UPSTREAM = "https://github.com/lIlIIlIll/yjson.git"
YJSON_COMMIT = "54b4965dee0f0b96710cbc678ec5ec9a126b055c"
YJSON_MACROS_COMMIT = "fec0adce41f73d037d876cbac7a28aee8108bb5c"
LEGACY_SCHEMA_SHA256 = {
    6: "a8db4442d6587b7d93108109730b6c2840a13eb031c07632bcd59b8488033a0a",
    7: "814eae6a9145f986608795cca731874b54c6cafd05f6bbbed19053640c1b6943",
    8: "95c5c707c8dcadd2bf67ffe5f88b6365f10c8499701dc2979338cad5df404b5c",
}
YJSON_LICENSE_SHA256 = "ff2bfac16f9884d002e66b1b2c75c20c626bc41ff31cdf411c5acdf224288295"
YJSON_PACKAGE_MANIFEST_SHA256 = "b5500422a100a4bbfa44ec2bd93494a1b8ca545c51ebff37fce1719d484f1e95"
YJSON_UPSTREAM_NOTICE_SHA256 = "bb2c645eed19b9243804ba40ca1b23161dbe7f2692d946e189f96866213628eb"
YJSON_SOURCE_SHA256 = {
    "src/lib_json_patch.cj": "82115f63f01807f3e7057518579cea4e058baf51c0e767e93e867a3a9c34a5de",
    "src/lib_json_pointer.cj": "ac5ffe300745a4123fbf0f6ecfb73aa2fc3743c89945dda4bc56c11d1fadf012",
    "src/lib_json_schema.cj": "bbaac0a63e4a28c57568a0d33bf7a9da7cdddb0457062ead6cc7649849326d21",
    "src/linear_regex.cj": "21a233eb8915bf9b78f4881093e30e007626e23c8be59bcac7282cf6ad62e3c5",
    "src/work_limits.cj": "6af3af0f970f47e87ab045ceaf9d9c4675ef7cdc23f27df2870a275b3f057e21",
}
YJSON_VENDOR_PATCHES = (
    {
        "path": "src/lib_json_schema.cj",
        "reason": "Avoid large RuneArray allocation while counting JSON Schema string length.",
    },
)
LEGACY_MIGRATION_RECEIPT_SHA256 = \
    "9e9ddc889a380f29abcf869471118e1bff92fc596055fad7cef0631a1ee5b40d"
JSON_SCHEMA_DRAFT = "https://json-schema.org/draft/2020-12/schema"

GOLDEN_NAMES = (
    "basic",
    "functions",
    "types",
    "extend",
    "source-edges",
    "unsupported",
    "workspace",
    "conditional-linux",
    "path-dependencies",
)

CURRENT_GOLDEN_VERSION = 10
LEGACY_GOLDEN_VERSIONS = (6, 7, 8, 9)

SCHEMA_NAMES = (
    "doc-ir",
    "doc-ir-v6",
    "doc-ir-v7",
    "doc-ir-v8",
    "doc-ir-v9",
    "doc-ir-v10",
    "diagnostics",
    "cfg-matrix",
    "search-index",
    "symbol-index",
    "navigation-index",
    "api-surface",
    "api-surface-v1",
    "api-diff",
    "documentation-coverage-v1",
    "documentation-coverage",
    "doctest-results",
    "versions",
)
SCHEMA_CONTRACTS = {
    "doc-ir": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/10",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v6": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/6",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v7": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/7",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v8": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v8.schema.json",
        "cjdoc.doc-ir/8",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v9": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v9.schema.json",
        "cjdoc.doc-ir/9",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v10": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v10.schema.json",
        "cjdoc.doc-ir/10",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "diagnostics": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/diagnostics.schema.json",
        "cjdoc.diagnostics/2", ("schemaVersion", "diagnostics"),
    ),
    "cfg-matrix": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/cfg-matrix.schema.json",
        "cjdoc.cfg-matrix/2", ("schemaVersion", "generator", "profiles"),
    ),
    "search-index": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/search-index.schema.json",
        "cjdoc.search-index/6", ("schemaVersion", "entries"),
    ),
    "symbol-index": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/symbol-index.schema.json",
        "cjdoc.symbol-index/1", ("schemaVersion", "project", "entries"),
    ),
    "navigation-index": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/navigation-index.schema.json",
        "cjdoc.navigation-index/1", ("schemaVersion", "project", "pages"),
    ),
    "api-surface": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface-v2.schema.json",
        "cjdoc.api-surface/2", ("schemaVersion", "project", "audience", "cfgProfile", "collectionState", "declarations", "exposures"),
    ),
    "api-surface-v1": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface.schema.json",
        "cjdoc.api-surface/1", ("schemaVersion", "project", "audience", "declarations", "exposures"),
    ),
    "api-diff": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-diff.schema.json",
        "cjdoc.api-diff/1", ("schemaVersion", "baseline", "current", "comparisonState", "summary", "entries"),
    ),
    "documentation-coverage-v1": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-coverage-v1.schema.json",
        "cjdoc.documentation-coverage/1", ("schemaVersion", "audience", "symbols", "parameters"),
    ),
    "documentation-coverage": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-coverage.schema.json",
        "cjdoc.documentation-coverage/2", ("schemaVersion", "audience", "metrics", "packages", "modules"),
    ),
    "doctest-results": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doctest-results.schema.json",
        "cjdoc.doctest/1", ("schemaVersion", "mode", "timeoutMs", "memoryMb", "jobs", "summary", "results"),
    ),
    "versions": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/versions.schema.json",
        "cjdoc.versions/1", ("schemaVersion", "project", "latest", "latestPolicy", "versions"),
    ),
}
SCHEMA_OPTIONAL_PROPERTIES = {
    "symbol-index": ("version",),
}
DOC_IR_CORE_DEFS = {
    "asset", "comment", "configuration", "declaration", "diagnostic", "file",
    "generator", "macroInvocation", "markdownNode", "module", "orphanComment",
    "package", "parameter", "portablePath", "position", "project", "provider",
    "semanticInfo", "sourceRange", "unsupportedDeclaration",
    "unboundSemanticDeclaration",
}
DOC_IR_ARRAY_REFS = {
    "providers": "provider",
    "modules": "module",
    "packages": "package",
    "files": "file",
    "declarations": "declaration",
    "assets": "asset",
    "orphanDocComments": "orphanComment",
    "macroInvocations": "macroInvocation",
    "unsupportedDeclarations": "unsupportedDeclaration",
    "unboundSemanticDeclarations": "unboundSemanticDeclaration",
    "diagnostics": "diagnostic",
}
