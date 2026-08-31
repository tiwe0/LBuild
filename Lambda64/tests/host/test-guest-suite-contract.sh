#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner="$repo_root/tests/guest/runner.lisp"

for suite in core-runtime os-services gc-allocator; do
    grep -Fq "SYS:SOURCE;TESTS;GUEST;$(printf '%s' "$suite" | tr '[:lower:]' '[:upper:]').LISP" "$runner" || {
        echo "Guest runner does not load ${suite}.lisp" >&2
        exit 1
    }
done

actual_names=$(sed -n 's/^(define-test "\([^"]*\)" ().*/\1/p' \
    "$repo_root/tests/guest/core-runtime.lisp" \
    "$repo_root/tests/guest/os-services.lisp" \
    "$repo_root/tests/guest/gc-allocator.lisp" | sort)
expected_names=$(sed -n '/^(defparameter \*expected-test-names\*/,/))$/p' "$runner" | \
    sed -n 's/.*"\([^"]*\)".*/\1/p' | sort)

[[ -n "$actual_names" ]] || { echo "No guest tests were discovered" >&2; exit 1; }
[[ $(wc -l <<< "$actual_names" | tr -d ' ') -eq 26 ]] || {
    echo "Guest suite must contain the 26 catalogued tests" >&2
    exit 1
}
[[ $(uniq -d <<< "$actual_names" | wc -l | tr -d ' ') -eq 0 ]] || {
    echo "Duplicate guest test name" >&2
    exit 1
}
diff -u <(printf '%s\n' "$expected_names") <(printf '%s\n' "$actual_names")

echo "guest suite catalog contract passed"
