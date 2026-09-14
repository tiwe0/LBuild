#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

# Fail fast and say why.  Many tests here are pure shell, so a missing SBCL does
# not surface until the first one that cross-compiles a probe form -- several
# hundred tests in, as a bare "sbcl: command not found" and exit 127, which
# reads like a broken test rather than a missing tool.
if ! command -v "${SBCL:-sbcl}" >/dev/null 2>&1; then
    echo "error: ${SBCL:-sbcl} not found on PATH." >&2
    echo "The host suite cross-compiles probe forms and needs SBCL installed." >&2
    exit 1
fi

while IFS= read -r test_script; do
    echo "==> ${test_script#"$repo_root/"}"
    "$test_script"
done < <(find "$script_dir" -maxdepth 1 -type f -name 'test-*.sh' -print | sort)

echo "==> tools/ci/test-assert-serial-log.sh"
"$repo_root/tools/ci/test-assert-serial-log.sh"

echo "==> shell syntax"
while IFS= read -r shell_script; do
    bash -n "$shell_script"
done < <(find "$repo_root/tests/host" "$repo_root/tools/ci" -type f -name '*.sh' -print | sort)

echo "host test suite passed"
