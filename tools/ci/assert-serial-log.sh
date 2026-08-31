#!/usr/bin/env bash

set -euo pipefail

mode=
log=
qemu_exit=
timed_out=false
expected_pass_exit=0
expected_fail_exit=1
expected_test_count=26

usage() {
    cat <<'EOF'
Usage: assert-serial-log.sh --mode MODE --log PATH --qemu-exit CODE [options]

Modes: diagnostic, positive, injected-failure
Options:
  --timed-out true|false
  --expected-pass-exit CODE
  --expected-fail-exit CODE
  --expected-test-count COUNT
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) mode=${2-}; shift 2 ;;
        --log) log=${2-}; shift 2 ;;
        --qemu-exit) qemu_exit=${2-}; shift 2 ;;
        --timed-out) timed_out=${2-}; shift 2 ;;
        --expected-pass-exit) expected_pass_exit=${2-}; shift 2 ;;
        --expected-fail-exit) expected_fail_exit=${2-}; shift 2 ;;
        --expected-test-count) expected_test_count=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$mode" in diagnostic|positive|injected-failure) ;; *) echo "Invalid mode: $mode" >&2; exit 2 ;; esac
[[ -f "$log" ]] || { echo "Serial log not found: $log" >&2; exit 2; }
[[ "$qemu_exit" =~ ^[0-9]+$ ]] || { echo "Invalid QEMU exit: $qemu_exit" >&2; exit 2; }
case "$timed_out" in true|false) ;; *) echo "Invalid timed-out value: $timed_out" >&2; exit 2 ;; esac
[[ "$expected_test_count" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid expected test count: $expected_test_count" >&2; exit 2; }

# QEMU's serial backend commonly emits CRLF.  Normalize it once so exact
# protocol records and line-anchored regular expressions behave identically
# for terminal captures and LF-only unit-test fixtures.
normalized_log=$(mktemp)
trap 'rm -f "$normalized_log"' EXIT
tr -d '\r' < "$log" > "$normalized_log"

forbidden_pattern='----- PANIC -----|Allocating during GC!|Unhandled condition|Entering the debugger|global debugger invoked'
if grep -E -q -- "$forbidden_pattern" "$normalized_log"; then
    echo "Forbidden panic/debugger text found in serial log" >&2
    exit 3
fi

if [[ "$timed_out" == true ]]; then
    echo "Guest timed out" >&2
    exit 124
fi

if [[ "$mode" != positive ]] && grep -F -q -- 'CI build completed successfully!' "$normalized_log"; then
    echo "Failure-mode log contains the CI success milestone" >&2
    exit 4
fi

require_ordered() {
    local previous=0 pattern line
    for pattern in "$@"; do
        line=$(awk -v after="$previous" -v pattern="$pattern" \
            'NR > after && index($0, pattern) { print NR; exit }' "$normalized_log")
        if [[ -z "$line" ]]; then
            echo "Missing or out-of-order serial milestone: $pattern" >&2
            return 1
        fi
        previous=$line
    done
}

if ! require_ordered \
    'Cold image coming up...' \
    'Initializing package system.' \
    'First GC.'
then
    exit 4
fi

if [[ "$mode" == diagnostic ]]; then
    echo "Diagnostic boot ended without the expected forbidden failure" >&2
    exit 4
fi

case "$mode" in
    positive)
        if ! require_ordered \
            'Cold image coming up...' \
            'Initializing package system.' \
            'First GC.' \
            'Cold load complete.' \
            'LAMBDA64_TEST_SUMMARY' \
            'CI build completed successfully!'
        then
            exit 4
        fi
        ;;
    injected-failure)
        if ! require_ordered \
            'Cold image coming up...' \
            'Initializing package system.' \
            'First GC.' \
            'Cold load complete.' \
            'LAMBDA64_TEST_SUMMARY'
        then
            exit 4
        fi
        ;;
esac

summary_count=$(grep -E -c '^LAMBDA64_TEST_SUMMARY pass=[0-9]+ fail=[0-9]+$' "$normalized_log" || true)
if [[ "$summary_count" -ne 1 ]]; then
    echo "Expected exactly one canonical test summary, found $summary_count" >&2
    exit 4
fi

summary=$(grep -E '^LAMBDA64_TEST_SUMMARY pass=[0-9]+ fail=[0-9]+$' "$normalized_log")
pass_count=$(printf '%s\n' "$summary" | sed -E 's/^.*pass=([0-9]+).*$/\1/')
fail_count=$(printf '%s\n' "$summary" | sed -E 's/^.*fail=([0-9]+).*$/\1/')
pass_record_count=$(grep -E -c '^LAMBDA64_TEST_PASS [^ ]+$' "$normalized_log" || true)
fail_record_count=$(grep -E -c '^LAMBDA64_TEST_FAIL [^ ]+ [^ ]+$' "$normalized_log" || true)

case "$mode" in
    positive)
        if [[ "$pass_count" -ne "$expected_test_count" || "$pass_record_count" -ne "$pass_count" ]]; then
            echo "Positive summary does not match real PASS records" >&2
            exit 4
        fi
        if [[ "$fail_count" -ne 0 || "$fail_record_count" -ne 0 ]]; then
            echo "Positive run contains test failures" >&2
            exit 4
        fi
        if [[ "$qemu_exit" -ne "$expected_pass_exit" ]]; then
            echo "Guest exit $qemu_exit disagrees with positive protocol" >&2
            exit 5
        fi
        ;;
    injected-failure)
        injected_record_count=$(grep -F -x -c \
            'LAMBDA64_TEST_FAIL harness.injected intentional' "$normalized_log" || true)
        if [[ "$pass_count" -ne 0 || "$pass_record_count" -ne 0 || \
              "$fail_count" -ne 1 || "$fail_record_count" -ne 1 || \
              "$injected_record_count" -ne 1 ]]; then
            echo "Injected-failure run did not report exactly the intentional sentinel failure" >&2
            exit 4
        fi
        if [[ "$qemu_exit" -ne "$expected_fail_exit" ]]; then
            echo "Guest exit $qemu_exit disagrees with injected-failure protocol" >&2
            exit 5
        fi
        ;;
esac

echo "Serial oracle passed: mode=$mode pass=$pass_count fail=$fail_count qemu_exit=$qemu_exit"
