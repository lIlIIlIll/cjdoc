from __future__ import annotations

import re

COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
MARKDOWN_LICENSE_SHA256 = "0d52dcdcb50af1bfd2c06821c888bdec9683830f79c78863173e3d0b12f2ac19"
YJSON_COMMIT = "78b84e6e110bcc84adcc97e8ec24995c7272782e"
MARKDOWN_UPSTREAM = "https://github.com/lIlIIlIll/markdown.git"
YJSON_UPSTREAM = "https://github.com/lIlIIlIll/yjson.git"
LEGACY_SCHEMA_SHA256 = {
    6: "a8db4442d6587b7d93108109730b6c2840a13eb031c07632bcd59b8488033a0a",
    7: "814eae6a9145f986608795cca731874b54c6cafd05f6bbbed19053640c1b6943",
}
YJSON_LICENSE_SHA256 = "ff2bfac16f9884d002e66b1b2c75c20c626bc41ff31cdf411c5acdf224288295"
YJSON_PACKAGE_MANIFEST_SHA256 = "3fa30b7a7f48b50a44747c19d966c2105948bed0ee7b019ae254d524e8a0feab"
YJSON_UPSTREAM_NOTICE_SHA256 = "78c5a27f82199641cf1de729c73a28e293884aa26722e432767cfcbb7face43f"
YJSON_SOURCE_SHA256 = {
    "src/lib_json_patch.cj": "32848edf1826af8b8b6816a7244ab6ffd370485f21e6ecbda0baa20fa4495492",
    "src/lib_json_pointer.cj": "972ce953184cb0e2b0c0d2b5da1589b376639f1d1d496331d435842c4d50d991",
    "src/lib_json_schema.cj": "bc6e110bb7b78807b26eb7c23e091c5fef2c02997f616a792fc5b70f81184a01",
    "src/work_limits.cj": "52aa1b8fbd41deaa72c80028f1500fe6ff9bafbcf9f5b11d2569bbc61baaeb6c",
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

CURRENT_GOLDEN_VERSION = 8
LEGACY_GOLDEN_VERSIONS = (6, 7)

SCHEMA_NAMES = (
    "doc-ir",
    "doc-ir-v6",
    "doc-ir-v7",
    "doc-ir-v8",
    "diagnostics",
    "cfg-matrix",
    "search-index",
    "api-surface",
    "documentation-coverage",
)
SCHEMA_CONTRACTS = {
    "doc-ir": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/8",
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
        "cjdoc.search-index/4", ("schemaVersion", "entries"),
    ),
    "api-surface": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface.schema.json",
        "cjdoc.api-surface/1", ("schemaVersion", "project", "audience", "declarations", "exposures"),
    ),
    "documentation-coverage": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-coverage.schema.json",
        "cjdoc.documentation-coverage/1", ("schemaVersion", "audience", "symbols", "parameters"),
    ),
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
