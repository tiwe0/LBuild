#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

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
