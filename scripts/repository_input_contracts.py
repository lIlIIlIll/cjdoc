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
    9: "3d72ac96683c49a638713eb074b8b9a5e1f8b6ca6b825c173696c026d0479cfc",
    10: "936936af60ce73cd421bb773a8190a501546e1f96ec193f2930b47fc7865f78e",
    11: "f221ad1e88276241db683c94e899253f1ce9bd893f1959cbd23621c5011a0d59",
    12: "31be45685d06ac0b16e309217bdb8aa652248a014bd53136e9457b4cc64a3964",
    13: "69f2827a8db325952e27daa0c7a5e7cafc040c74765861a79d7fabd95d3ebe7f",
    14: "ede9db7a302e6df439ec63e06547cd036fdafaa18fc159c5e5e8463c5bd3d62c",
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

LEGACY13_GOLDEN_SHA256 = {
    "basic": "26f5cb6f9b39c6ec4b316474333eb981e3437ad63caf1761e1c778f355e81167",
    "conditional-linux": "f7901b1c0ce367f5a46ab8829155e9c7bcd2374bbb2fc317f590e6d8fc6b6919",
    "extend": "d57f02f673ecc3911b991306a190c4a0aca4e5fde94af80e8ab3caa3210e0f51",
    "functions": "28a2578aca94bc05e9f177fc335c67efa95919e9e695e90b38037009d7ffb5cd",
    "path-dependencies": "0f3d1ae5eb39affcc08aeef66cda3ec1bbe57bb56f5fec02bd476fdf61ad24ef",
    "source-edges": "925a410012458c0ceb08e651433a127e829f98edf72878111d31588b37a825a3",
    "types": "5c2ab1e02d81e25aff6a449f23c2dba8db509b78249b7ed3d3d225255b8b397d",
    "unsupported": "92113a53d5170b5d5d83c54a06428440451e86d4caa8410f9c12fff2348f650e",
    "workspace": "e2290993a74b17c29a103edd2e2d338a89b356e8a53ed49ded2662e13a690649"
}

LEGACY14_GOLDEN_SHA256 = {
    "basic": "0bf4546255dd6eba96ea9d6f63a9da8fe933f10fa02c96e957b4285815935422",
    "conditional-linux": "a94e0602c2df6fa1fb8b9f5ce657171ea8a07711b2bb8967be93bf06b628ca1f",
    "extend": "562dd1eab306e5526e08476034abcc45fce400a2fb2b7ee7b1481d911e6a07ae",
    "functions": "6a2dc29ff6526eaf6a5d6535a5810194eb3a327a3d5b40a45cd2f07994a46234",
    "path-dependencies": "735e9c30cef9fb5065e62fdbe4cb60e7c3a0609c3000cc0085bbdaf6c391541a",
    "source-edges": "3fe6dfc2bf01d80be4eb1395c71554c3d15045138d71c95d152af181e62972e1",
    "types": "9aad92878047d515c9dbeb0a24fef1c6844b61c27a5d4fc6b025106534ee357f",
    "unsupported": "c605d3e290b88b9ed576cbbc58f4470d09fe53e83dd8b203189b596796e60845",
    "workspace": "255a32994211b85d5ae56f47eff5140ff669e5200ac7d4516a74da6bf6738a70",
}

CURRENT_GOLDEN_VERSION = 15
LEGACY_GOLDEN_VERSIONS = (6, 7, 8, 9, 10, 11, 12, 13, 14)

SCHEMA_NAMES = (
    "doc-ir",
    "doc-ir-v6",
    "doc-ir-v7",
    "doc-ir-v8",
    "doc-ir-v9",
    "doc-ir-v10",
    "doc-ir-v11",
    "doc-ir-v12",
    "doc-ir-v13",
    "doc-ir-v14",
    "doc-ir-v15",
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
    "documentation-quality",
    "doctest-results",
    "versions",
    "api-surface-v2", "api-surface-v3", "api-diff-v1", "doctest-results-v1",
    "search-index-v8", "versions-v1", "translation-coverage", "site-manifest",
    "api-diff-v2", "doctest-results-v2", "search-index-v9", "versions-v2",
)
SCHEMA_CONTRACTS = {
    "documentation-quality": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-quality.schema.json",
        "cjdoc.documentation-quality/1",
        ("schemaVersion", "audience", "assessment", "symbols", "parameters", "findings"),
    ),
    "doc-ir": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/12",
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
    "doc-ir-v11": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v11.schema.json",
        "cjdoc.doc-ir/11",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v12": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v12.schema.json",
        "cjdoc.doc-ir/12",
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
        "cjdoc.search-index/8", ("schemaVersion", "entries"),
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
# Published legacy schemas retain their original contracts.
SCHEMA_CONTRACTS["doc-ir-v13"] = (
    SCHEMA_CONTRACTS["doc-ir-v12"][0].replace("v12", "v13"),
    "cjdoc.doc-ir/13", SCHEMA_CONTRACTS["doc-ir-v12"][2],
)
SCHEMA_CONTRACTS["doc-ir"] = (
    SCHEMA_CONTRACTS["doc-ir"][0], "cjdoc.doc-ir/15",
    (*SCHEMA_CONTRACTS["doc-ir"][2][:3], "apiCollectionState", "documentationRevision", *SCHEMA_CONTRACTS["doc-ir"][2][3:], "dependencies", "documentSets"),
)
SCHEMA_CONTRACTS["doc-ir-v14"] = (
    SCHEMA_CONTRACTS["doc-ir-v13"][0].replace("v13", "v14"),
    "cjdoc.doc-ir/14", (*SCHEMA_CONTRACTS["doc-ir-v13"][2][:3], "apiCollectionState", *SCHEMA_CONTRACTS["doc-ir-v13"][2][3:]),
)
SCHEMA_CONTRACTS["doc-ir-v15"] = (
    SCHEMA_CONTRACTS["doc-ir"][0].replace("doc-ir.schema", "doc-ir-v15.schema"),
    "cjdoc.doc-ir/15", SCHEMA_CONTRACTS["doc-ir"][2],
)
SCHEMA_CONTRACTS["symbol-index"] = (
    SCHEMA_CONTRACTS["symbol-index"][0], "cjdoc.symbol-index/2",
    (*SCHEMA_CONTRACTS["symbol-index"][2], "dependencies", "documentSets"),
)
for current, legacy in (("api-surface", "api-surface-v2"), ("api-diff", "api-diff-v1"),
                        ("doctest-results", "doctest-results-v1"),
                        ("search-index", "search-index-v8"), ("versions", "versions-v1")):
    SCHEMA_CONTRACTS[legacy] = SCHEMA_CONTRACTS[current]
for name, version in (("api-surface", 3), ("api-diff", 2), ("doctest-results", 2),
                      ("search-index", 9), ("versions", 2)):
    identifier, old_version, required = SCHEMA_CONTRACTS[name]
    if name == "api-surface":
        identifier = identifier.replace("v2", "v3")
    else:
        identifier = identifier.replace(".schema.json", f"-v{version}.schema.json")
    if name == "doctest-results":
        required = ("schemaVersion", "mode", "timeoutMs", "memoryMb", "jobs", "environmentFingerprint", "summary", "results")
    SCHEMA_CONTRACTS[name] = (identifier, old_version.rsplit("/", 1)[0] + f"/{version}", required)
for name, version in (("api-surface", 3), ("api-diff", 2), ("doctest-results", 2),
                      ("search-index", 9), ("versions", 2)):
    SCHEMA_CONTRACTS[f"{name}-v{version}"] = SCHEMA_CONTRACTS[name]
for name, version, required in (
    ("translation-coverage", "cjdoc.translation-coverage/1", ("schemaVersion", "languages")),
    ("site-manifest", "cjdoc.site-manifest/1", ("schemaVersion", "project", "version", "routes")),
):
    SCHEMA_CONTRACTS[name] = (f"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/{name}.schema.json", version, required)
SCHEMA_OPTIONAL_PROPERTIES = {
    "symbol-index": ("version", "provenance"),
    "doc-ir": ("languageOptions", "pages", "readingLanguage", "externalDocumentation"),
    "doc-ir-v13": ("languageOptions", "pages", "readingLanguage", "externalDocumentation"),
    "doc-ir-v14": ("languageOptions", "pages", "readingLanguage", "externalDocumentation"),
    "doc-ir-v15": ("languageOptions", "pages", "readingLanguage", "externalDocumentation"),
    "site-manifest": ("defaultLanguage",),
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
