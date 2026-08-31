#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
runner="$repo_root/tools/ci/run-arm64-smoke.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'immutable test image\n' > "$tmp/lambda64.image"
mkdir -p "$tmp/fixtures"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

write_manifest() {
    local repository_dirty=$1
    cat > "$tmp/lambda64.test-manifest" <<EOF
format	lambda64-test-manifest-v2
profile	test
image_sha256	$(sha256_file "$tmp/lambda64.image")
repository_sha	1111111111111111111111111111111111111111
repository_dirty	$repository_dirty
lambda64_tree	2222222222222222222222222222222222222222
build_command	make test-image
sbcl_version	SBCL test
qemu_version	QEMU test
created_utc	2026-08-31T00:00:00Z
EOF
}

write_launcher() {
    local body=$1
    cat > "$tmp/fake-qemu" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$tmp/launcher.argv"
$body
EOF
    chmod +x "$tmp/fake-qemu"
}

run_expect() {
    local expected=$1
    local mode=$2
    local timeout=${3:-10}
    local allow_dirty=${4:-false}
    local dirty_arg=
    if [[ "$allow_dirty" == true ]]; then
        dirty_arg=--allow-dirty
    fi
    set +e
    LAMBDA64_QEMU_LAUNCHER="$tmp/fake-qemu" \
        "$runner" \
        --mode "$mode" \
        --image "$tmp/lambda64.image" \
        --manifest "$tmp/lambda64.test-manifest" \
        --fixture-root "$tmp/fixtures" \
        --serial-log "$tmp/${mode}.serial.log" \
        --evidence "$tmp/${mode}.evidence" \
        --timeout "$timeout" \
        --expected-repository-sha 1111111111111111111111111111111111111111 \
        --expected-test-count 2 \
        $dirty_arg \
        >/dev/null 2>&1
    local actual=$?
    set -e
    if [[ "$actual" -ne "$expected" ]]; then
        echo "Expected smoke exit $expected, got $actual in mode $mode" >&2
        [[ -f "$tmp/${mode}.serial.log" ]] && cat "$tmp/${mode}.serial.log" >&2
        [[ -f "$tmp/${mode}.evidence" ]] && cat "$tmp/${mode}.evidence" >&2
        exit 1
    fi
}

# Regression for the completed-log race: the fake guest emits a panic and
# exits before the polling loop can necessarily observe it.
write_manifest false
write_launcher "printf '%s\\n' 'Cold image coming up...' 'Initializing package system.' 'First GC.' '----- PANIC -----'; exit 1"
run_expect 3 diagnostic
grep -Fxq 'forbidden_seen=true' "$tmp/diagnostic.evidence"
grep -Fxq 'base_image_unchanged=true' "$tmp/diagnostic.evidence"

write_launcher "printf '%s\\n' 'Cold image coming up...' 'Initializing package system.' 'First GC.' 'Cold load complete.' 'Loading warm modules.' 'Post load GC.' 'Hello, world.' 'LAMBDA64_TEST_PASS gc.one' 'LAMBDA64_TEST_PASS gc.two' 'LAMBDA64_TEST_SUMMARY pass=2 fail=0' 'CI build completed successfully!'; exit 0"
run_expect 0 positive
cat > "$tmp/expected-launcher.argv" <<EOF
--image
$tmp/lambda64.image
--headless
--accel
tcg
--cpus
4
--memory
2G
--
-snapshot
EOF
diff -u "$tmp/expected-launcher.argv" "$tmp/launcher.argv"

write_launcher "printf '%s\\n' 'Cold image coming up...' 'Initializing package system.' 'First GC.' 'Cold load complete.' 'Loading warm modules.' 'Post load GC.' 'Hello, world.' 'LAMBDA64_TEST_FAIL harness.injected intentional' 'LAMBDA64_TEST_SUMMARY pass=0 fail=1'; exit 1"
run_expect 0 injected-failure
[[ ! -e "$tmp/fixtures/LAMBDA64-CI-INJECT-FAIL.SENTINEL" ]]

# A guest that ignores TERM must be escalated to KILL and reported as timeout,
# while cleanup still removes the injected sentinel and preserves the image.
write_launcher "trap '' TERM; sleep 30"
run_expect 124 diagnostic 1
grep -Fxq 'timed_out=true' "$tmp/diagnostic.evidence"
grep -Fxq 'base_image_unchanged=true' "$tmp/diagnostic.evidence"
[[ ! -e "$tmp/fixtures/LAMBDA64-CI-INJECT-FAIL.SENTINEL" ]]

# Release integration is fail-closed for dirty provenance.  Diagnostic mode
# remains available for exact historical or locally patched artifact replay.
write_manifest true
run_expect 2 positive
write_launcher "printf '%s\\n' 'Cold image coming up...' 'Initializing package system.' 'First GC.' 'Cold load complete.' 'Loading warm modules.' 'Post load GC.' 'Hello, world.' 'LAMBDA64_TEST_PASS local.dirty-one' 'LAMBDA64_TEST_PASS local.dirty-two' 'LAMBDA64_TEST_SUMMARY pass=2 fail=0' 'CI build completed successfully!'; exit 0"
run_expect 0 positive 10 true
grep -Fxq 'allow_dirty=true' "$tmp/positive.evidence"
write_launcher "printf '%s\\n' 'Cold image coming up...' 'Initializing package system.' 'First GC.' '----- PANIC -----'; exit 1"
run_expect 3 diagnostic
grep -Fxq 'repository_dirty=true' "$tmp/diagnostic.evidence"

write_manifest false
grep -v '^repository_dirty' "$tmp/lambda64.test-manifest" > "$tmp/incomplete.manifest"
mv "$tmp/incomplete.manifest" "$tmp/lambda64.test-manifest"
run_expect 2 diagnostic

echo "ARM64 smoke runner tests passed"
