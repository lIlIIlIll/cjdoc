#!/usr/bin/env bash
set -euo pipefail

# Use Codex's SDK environment helper when it exists on the local development
# host. Release/CI hosts can call this script unchanged with cjc/cjpm already
# available in their environment.
codex_runner=/home/elliot/.codex/scripts/codex_cangjie_env
if [[ "${CJDOC_DISABLE_CODEX_RUNNER:-0}" != "1" && -x "${codex_runner}" ]]; then
    exec "${codex_runner}" "$@"
fi

working_directory=""
if [[ "${1:-}" == "--cwd" ]]; then
    if [[ $# -lt 3 ]]; then
        echo "error: --cwd requires a directory and command" >&2
        exit 2
    fi
    working_directory="$2"
    shift 2
fi
if [[ -n "${working_directory}" ]]; then
    cd "${working_directory}"
fi
exec "$@"
