set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    cjc -v
    cjpm -v
    python3 -c 'import json; print("Python standard library: OK")'

build:
    cjpm build

test:
    cjpm test

schema:
    mkdir -p target/schema-check
    target/release/bin/main schema doc-ir > target/schema-check/doc-ir.schema.json
    target/release/bin/main schema diagnostics > target/schema-check/diagnostics.schema.json
    target/release/bin/main schema cfg-matrix > target/schema-check/cfg-matrix.schema.json
    target/release/bin/main schema search-index > target/schema-check/search-index.schema.json
    cmp docs/schema/doc-ir.schema.json target/schema-check/doc-ir.schema.json
    cmp docs/schema/diagnostics.schema.json target/schema-check/diagnostics.schema.json
    cmp docs/schema/cfg-matrix.schema.json target/schema-check/cfg-matrix.schema.json
    cmp docs/schema/search-index.schema.json target/schema-check/search-index.schema.json

golden:
    scripts/check.sh

check:
    scripts/check.sh

smoke:
    target/release/bin/main generate --project tests/fixtures/projects/basic --format json --format markdown --format html --output target/smoke

provider-smoke:
    cd tests/fixtures/projects/provider_plugin && cjpm run
