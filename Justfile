set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

doctor:
    git --version
    cjc -v
    cjpm -v
    python3 -c 'import json; print("Python standard library: OK")'

build:
    cjpm build

test:
    cjpm test

schema:
    target_root="$$(python3 scripts/safe_output_root.py --repo . --directory ./target --create)"; schema_dir="$${target_root}/schema-check"; python3 scripts/safe_output_root.py --repo . --directory "$${schema_dir}" --create >/dev/null; target/release/bin/main schema doc-ir > "$${schema_dir}/doc-ir.schema.json"; target/release/bin/main schema doc-ir-v6 > "$${schema_dir}/doc-ir-v6.schema.json"; target/release/bin/main schema doc-ir-v7 > "$${schema_dir}/doc-ir-v7.schema.json"; target/release/bin/main schema doc-ir-v8 > "$${schema_dir}/doc-ir-v8.schema.json"; target/release/bin/main schema diagnostics > "$${schema_dir}/diagnostics.schema.json"; target/release/bin/main schema cfg-matrix > "$${schema_dir}/cfg-matrix.schema.json"; target/release/bin/main schema search-index > "$${schema_dir}/search-index.schema.json"; cmp docs/schema/doc-ir.schema.json "$${schema_dir}/doc-ir.schema.json"; cmp docs/schema/doc-ir-v6.schema.json "$${schema_dir}/doc-ir-v6.schema.json"; cmp docs/schema/doc-ir-v7.schema.json "$${schema_dir}/doc-ir-v7.schema.json"; cmp docs/schema/doc-ir-v8.schema.json "$${schema_dir}/doc-ir-v8.schema.json"; cmp docs/schema/diagnostics.schema.json "$${schema_dir}/diagnostics.schema.json"; cmp docs/schema/cfg-matrix.schema.json "$${schema_dir}/cfg-matrix.schema.json"; cmp docs/schema/search-index.schema.json "$${schema_dir}/search-index.schema.json"

golden:
    scripts/check.sh

check:
    scripts/check.sh

real-smoke:
    python3 scripts/real_repository_smoke.py --project .

perf:
    python3 scripts/perf_gate.py check

release-check:
    scripts/release_check.sh

smoke:
    target/release/bin/main generate --project tests/fixtures/projects/basic --format json --format markdown --format html --output target/smoke

provider-smoke:
    cd tests/fixtures/projects/provider_plugin && cjpm run
