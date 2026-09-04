from __future__ import annotations

import re

COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
MAX_MEMBERS = 128
MAX_ARCHIVE_SIZE = 512 * 1024 * 1024
MAX_MEMBER_SIZE = 512 * 1024 * 1024
MAX_TOTAL_SIZE = 1024 * 1024 * 1024
MAX_ZIP_DIRECTORY_SIZE = 8 * 1024 * 1024
MAX_TAR_EXPANDED_SIZE = MAX_TOTAL_SIZE + (MAX_MEMBERS + 32) * 1024
MAX_MANIFEST_SIZE = 1024 * 1024
STREAM_CHUNK_SIZE = 1024 * 1024
SCHEMA_PAYLOAD = {
    "docs/schema/doc-ir.schema.json",
    "docs/schema/doc-ir-v6.schema.json",
    "docs/schema/doc-ir-v7.schema.json",
    "docs/schema/doc-ir-v8.schema.json",
    "docs/schema/diagnostics.schema.json",
    "docs/schema/cfg-matrix.schema.json",
    "docs/schema/search-index.schema.json",
    "docs/schema/api-surface.schema.json",
    "docs/schema/documentation-coverage.schema.json",
}
REPOSITORY_PAYLOAD = {
    "README.md": "README.md",
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "licenses/markdown-MIT.txt": "third_party/licenses/markdown-LICENSE",
    "licenses/yjson-Apache-2.0.txt": "vendor/yjson_algorithms/LICENSE",
    **{name: name for name in SCHEMA_PAYLOAD},
}

