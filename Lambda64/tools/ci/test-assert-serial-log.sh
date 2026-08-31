#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
oracle="$script_dir/assert-serial-log.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

base_log() {
    cat <<'EOF'
Cold image coming up...
Initializing package system.
First GC.
EOF
}

warm_log() {
    base_log
    cat <<'EOF'
Cold load complete.
EOF
}

interleaved_warm_log() {
    base_log
    cat <<'EOF'
Cold load complete.
Loading waBegin snapshot.
rm modules.
EOF
}

run_expect() {
    local expected=$1
    shift
    set +e
    "$oracle" "$@" >/dev/null 2>&1
    local actual=$?
    set -e
    if [[ "$actual" -ne "$expected" ]]; then
        echo "Expected oracle exit $expected, got $actual: $*" >&2
        exit 1
    fi
}

base_log > "$tmp/panic.log"
echo '----- PANIC -----' >> "$tmp/panic.log"
run_expect 3 --mode diagnostic --log "$tmp/panic.log" --qemu-exit 143

base_log > "$tmp/timeout.log"
run_expect 124 --mode diagnostic --log "$tmp/timeout.log" --qemu-exit 143 --timed-out true

warm_log > "$tmp/pass.log"
echo 'LAMBDA64_TEST_PASS gc.one' >> "$tmp/pass.log"
echo 'LAMBDA64_TEST_PASS gc.two' >> "$tmp/pass.log"
echo 'LAMBDA64_TEST_SUMMARY pass=2 fail=0' >> "$tmp/pass.log"
echo 'CI build completed successfully!' >> "$tmp/pass.log"
run_expect 0 --mode positive --log "$tmp/pass.log" --qemu-exit 0 --expected-test-count 2

interleaved_warm_log > "$tmp/interleaved-pass.log"
echo 'LAMBDA64_TEST_PASS gc.one' >> "$tmp/interleaved-pass.log"
echo 'LAMBDA64_TEST_SUMMARY pass=1 fail=0' >> "$tmp/interleaved-pass.log"
echo 'CI build completed successfully!' >> "$tmp/interleaved-pass.log"
run_expect 0 --mode positive --log "$tmp/interleaved-pass.log" --qemu-exit 0 --expected-test-count 1

warm_log > "$tmp/missing.log"
run_expect 4 --mode positive --log "$tmp/missing.log" --qemu-exit 1

warm_log > "$tmp/exit-mismatch.log"
echo 'LAMBDA64_TEST_PASS gc.one' >> "$tmp/exit-mismatch.log"
echo 'LAMBDA64_TEST_SUMMARY pass=1 fail=0' >> "$tmp/exit-mismatch.log"
echo 'CI build completed successfully!' >> "$tmp/exit-mismatch.log"
run_expect 5 --mode positive --log "$tmp/exit-mismatch.log" --qemu-exit 1 --expected-test-count 1

warm_log > "$tmp/injected.log"
echo 'LAMBDA64_TEST_FAIL harness.injected intentional' >> "$tmp/injected.log"
echo 'LAMBDA64_TEST_SUMMARY pass=0 fail=1' >> "$tmp/injected.log"
run_expect 0 --mode injected-failure --log "$tmp/injected.log" --qemu-exit 1

# Real QEMU serial captures use CRLF.  The canonical protocol must accept
# those logs without weakening its exact record validation.
sed 's/$/\r/' "$tmp/injected.log" > "$tmp/injected-crlf.log"
run_expect 0 --mode injected-failure --log "$tmp/injected-crlf.log" --qemu-exit 1

sed 's/$/\r/' "$tmp/pass.log" > "$tmp/pass-crlf.log"
run_expect 0 --mode positive --log "$tmp/pass-crlf.log" --qemu-exit 0 --expected-test-count 2

cp "$tmp/injected.log" "$tmp/injected-with-success.log"
echo 'CI build completed successfully!' >> "$tmp/injected-with-success.log"
run_expect 4 --mode injected-failure --log "$tmp/injected-with-success.log" --qemu-exit 1

warm_log > "$tmp/empty-positive.log"
echo 'LAMBDA64_TEST_SUMMARY pass=0 fail=0' >> "$tmp/empty-positive.log"
echo 'CI build completed successfully!' >> "$tmp/empty-positive.log"
run_expect 4 --mode positive --log "$tmp/empty-positive.log" --qemu-exit 0

warm_log > "$tmp/wrong-injected.log"
echo 'LAMBDA64_TEST_FAIL harness.load harness-load' >> "$tmp/wrong-injected.log"
echo 'LAMBDA64_TEST_SUMMARY pass=0 fail=1' >> "$tmp/wrong-injected.log"
run_expect 4 --mode injected-failure --log "$tmp/wrong-injected.log" --qemu-exit 1

echo "serial oracle tests passed"
