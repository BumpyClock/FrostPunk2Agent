#!/usr/bin/env bash
set -euo pipefail
command -v bun >/dev/null || { echo 'Install Bun 1.2.20 and run bun install --frozen-lockfile in cli first.' >&2; exit 1; }
[[ $(bun --version) == 1.2.20 ]] || { echo 'Use Bun 1.2.20 for the locked CLI toolchain.' >&2; exit 1; }
[[ -f cli/node_modules/typescript/bin/tsc ]] || { echo 'Run bun install --frozen-lockfile in cli before pushing. Hook never installs.' >&2; exit 1; }
bun run --cwd cli typecheck
