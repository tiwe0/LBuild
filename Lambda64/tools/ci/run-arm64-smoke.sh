#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
launcher=${LAMBDA64_QEMU_LAUNCHER:-"$repo_root/tools/run-qemu-arm64"}

mode=
image=
manifest=
fixture_root=
serial_log=
evidence=
timeout_seconds=${LAMBDA64_SMOKE_TIMEOUT_SECONDS:-}
expected_lbuild_sha=
expected_lambda64_sha=
expected_pass_exit=0
expected_fail_exit=1
expected_test_count=26
cpus=4
memory=2G
allow_dirty=false

usage() {
    cat <<'EOF'
Usage: run-arm64-smoke.sh --mode MODE --image PATH --manifest PATH \
       --fixture-root PATH --serial-log PATH --evidence PATH [options]

Modes: diagnostic, positive, injected-failure
Options:
  --timeout SECONDS
  --expected-lbuild-sha SHA
  --expected-lambda64-sha SHA
  --expected-pass-exit CODE
  --expected-fail-exit CODE
  --expected-test-count COUNT
  --cpus COUNT
  --memory SIZE
  --allow-dirty
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) mode=${2-}; shift 2 ;;
        --image) image=${2-}; shift 2 ;;
        --manifest) manifest=${2-}; shift 2 ;;
        --fixture-root) fixture_root=${2-}; shift 2 ;;
        --serial-log) serial_log=${2-}; shift 2 ;;
        --evidence) evidence=${2-}; shift 2 ;;
        --timeout) timeout_seconds=${2-}; shift 2 ;;
        --expected-lbuild-sha) expected_lbuild_sha=${2-}; shift 2 ;;
        --expected-lambda64-sha) expected_lambda64_sha=${2-}; shift 2 ;;
        --expected-pass-exit) expected_pass_exit=${2-}; shift 2 ;;
        --expected-fail-exit) expected_fail_exit=${2-}; shift 2 ;;
        --expected-test-count) expected_test_count=${2-}; shift 2 ;;
        --cpus) cpus=${2-}; shift 2 ;;
        --memory) memory=${2-}; shift 2 ;;
        --allow-dirty) allow_dirty=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$mode" in
    diagnostic) default_timeout=900 ;;
    positive|injected-failure) default_timeout=4800 ;;
    *) echo "Invalid mode: $mode" >&2; exit 2 ;;
esac
timeout_seconds=${timeout_seconds:-$default_timeout}
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout: $timeout_seconds" >&2; exit 2; }
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid CPU count: $cpus" >&2; exit 2; }
[[ "$memory" =~ ^[1-9][0-9]*[MG]$ ]] || { echo "Invalid memory size: $memory" >&2; exit 2; }
[[ "$expected_test_count" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid expected test count: $expected_test_count" >&2; exit 2; }

for required in image manifest fixture_root serial_log evidence; do
    eval "value=\${$required}"
    [[ -n "$value" ]] || { echo "Missing --${required//_/-}" >&2; exit 2; }
done
[[ -f "$image" ]] || { echo "Image not found: $image" >&2; exit 2; }
[[ -f "$manifest" ]] || { echo "Manifest not found: $manifest" >&2; exit 2; }
[[ -d "$fixture_root" ]] || { echo "Fixture root not found: $fixture_root" >&2; exit 2; }

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

manifest_format=
manifest_profile=
manifest_image_sha256=
manifest_lambda64_sha=
manifest_lbuild_sha=
manifest_lambda64_dirty=
manifest_lbuild_dirty=
manifest_build_command=
manifest_sbcl_version=
manifest_qemu_version=
manifest_created_utc=
expected_manifest_keys=(
    format profile image_sha256 lambda64_sha lambda64_dirty lbuild_sha lbuild_dirty
    build_command sbcl_version qemu_version created_utc
)
manifest_index=0

while IFS=$'\t' read -r key value extra || [[ -n "${key:-}" ]]; do
    [[ -n "$key" && -n "$value" && -z "${extra:-}" ]] || { echo "Invalid manifest row" >&2; exit 2; }
    if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$value"; then
        echo "Manifest field contains control characters: $key" >&2
        exit 2
    fi
    if [[ "$manifest_index" -ge "${#expected_manifest_keys[@]}" || "$key" != "${expected_manifest_keys[$manifest_index]}" ]]; then
        echo "Unexpected manifest field at line $((manifest_index + 1)): $key" >&2
        exit 2
    fi
    case "$key" in
        format) slot=manifest_format ;;
        profile) slot=manifest_profile ;;
        image_sha256) slot=manifest_image_sha256 ;;
        lambda64_sha) slot=manifest_lambda64_sha ;;
        lbuild_sha) slot=manifest_lbuild_sha ;;
        lambda64_dirty) slot=manifest_lambda64_dirty ;;
        lbuild_dirty) slot=manifest_lbuild_dirty ;;
        build_command) slot=manifest_build_command ;;
        sbcl_version) slot=manifest_sbcl_version ;;
        qemu_version) slot=manifest_qemu_version ;;
        created_utc) slot=manifest_created_utc ;;
        *) echo "Unknown manifest key: $key" >&2; exit 2 ;;
    esac
    eval "current=\${$slot}"
    [[ -z "$current" ]] || { echo "Duplicate manifest key: $key" >&2; exit 2; }
    printf -v "$slot" '%s' "$value"
    manifest_index=$((manifest_index + 1))
done < "$manifest"

[[ "$manifest_index" -eq "${#expected_manifest_keys[@]}" ]] || { echo "Manifest is incomplete" >&2; exit 2; }

for required in manifest_format manifest_profile manifest_image_sha256 manifest_lambda64_sha \
                manifest_lbuild_sha manifest_lambda64_dirty manifest_lbuild_dirty \
                manifest_build_command manifest_sbcl_version \
                manifest_qemu_version manifest_created_utc; do
    eval "value=\${$required}"
    [[ -n "$value" ]] || { echo "Missing manifest field: ${required#manifest_}" >&2; exit 2; }
done
[[ "$manifest_format" == lambda64-test-manifest-v1 ]] || { echo "Invalid manifest format" >&2; exit 2; }
[[ "$manifest_profile" == test ]] || { echo "Image is not a test profile" >&2; exit 2; }
[[ "$manifest_image_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid image SHA256" >&2; exit 2; }
[[ "$manifest_lambda64_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid Lambda64 SHA" >&2; exit 2; }
[[ "$manifest_lbuild_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid LBuild SHA" >&2; exit 2; }
case "$manifest_lambda64_dirty" in true|false) ;; *) echo "Invalid Lambda64 dirty flag" >&2; exit 2 ;; esac
case "$manifest_lbuild_dirty" in true|false) ;; *) echo "Invalid LBuild dirty flag" >&2; exit 2 ;; esac
[[ "$manifest_created_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    echo "Invalid manifest timestamp" >&2
    exit 2
}
if [[ "$mode" != diagnostic && "$allow_dirty" != true && \
      ( "$manifest_lambda64_dirty" != false || "$manifest_lbuild_dirty" != false ) ]]; then
    echo "Integration smoke requires clean Lambda64 and LBuild checkouts" >&2
    exit 2
fi
actual_image_sha256=$(sha256_file "$image")
[[ "$actual_image_sha256" == "$manifest_image_sha256" ]] || { echo "Image SHA256 does not match manifest" >&2; exit 2; }
if [[ -n "$expected_lbuild_sha" && "$manifest_lbuild_sha" != "$expected_lbuild_sha" ]]; then
    echo "LBuild SHA does not match the pinned workflow SHA" >&2
    exit 2
fi
if [[ -n "$expected_lambda64_sha" && "$manifest_lambda64_sha" != "$expected_lambda64_sha" ]]; then
    echo "Lambda64 SHA does not match the checked-out workflow revision" >&2
    exit 2
fi

sentinel="$fixture_root/LAMBDA64-CI-INJECT-FAIL.SENTINEL"
qemu_pid=
tail_pid=
cleanup() {
    rm -f "$sentinel"
    if [[ -n "${tail_pid:-}" ]]; then kill "$tail_pid" 2>/dev/null || true; fi
    if [[ -n "${qemu_pid:-}" ]]; then kill "$qemu_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

rm -f "$sentinel"
if [[ "$mode" == injected-failure ]]; then
    printf 'intentional guest failure\n' > "$sentinel"
fi

mkdir -p "$(dirname "$serial_log")" "$(dirname "$evidence")"
: > "$serial_log"
start_epoch=$(date +%s)
{
    printf 'mode=%s\n' "$mode"
    printf 'timeout_seconds=%s\n' "$timeout_seconds"
    printf 'cpus=%s\n' "$cpus"
    printf 'memory=%s\n' "$memory"
    printf 'allow_dirty=%s\n' "$allow_dirty"
    printf 'expected_test_count=%s\n' "$expected_test_count"
    printf 'image=%s\n' "$image"
    printf 'image_sha256=%s\n' "$actual_image_sha256"
    printf 'lambda64_sha=%s\n' "$manifest_lambda64_sha"
    printf 'lbuild_sha=%s\n' "$manifest_lbuild_sha"
    printf 'lambda64_dirty=%s\n' "$manifest_lambda64_dirty"
    printf 'lbuild_dirty=%s\n' "$manifest_lbuild_dirty"
    printf 'sentinel=%s\n' "$sentinel"
    printf 'sentinel_present_at_boot=%s\n' "$([[ -f "$sentinel" ]] && echo true || echo false)"
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$evidence"

"$launcher" \
    --image "$image" \
    --headless \
    --accel tcg \
    --cpus "$cpus" \
    --memory "$memory" \
    -- -snapshot \
    > "$serial_log" 2>&1 &
qemu_pid=$!
tail -n +1 -f "$serial_log" &
tail_pid=$!

timed_out=false
forbidden_seen=false
while kill -0 "$qemu_pid" 2>/dev/null; do
    if grep -E -q -- '----- PANIC -----|Allocating during GC!|Unhandled condition|Entering the debugger|global debugger invoked' "$serial_log"; then
        forbidden_seen=true
        kill "$qemu_pid" 2>/dev/null || true
        sleep 5
        kill -9 "$qemu_pid" 2>/dev/null || true
        break
    fi
    now=$(date +%s)
    if (( now - start_epoch >= timeout_seconds )); then
        timed_out=true
        kill "$qemu_pid" 2>/dev/null || true
        sleep 5
        kill -9 "$qemu_pid" 2>/dev/null || true
        break
    fi
    sleep 1
done

set +e
wait "$qemu_pid"
qemu_exit=$?
set -e
qemu_pid=
kill "$tail_pid" 2>/dev/null || true
tail_pid=

# QEMU may print a panic and exit between polling iterations.  Derive the
# evidence from the completed log as well as the live monitor so an immediate
# guest exit cannot incorrectly record forbidden_seen=false.
if grep -E -q -- '----- PANIC -----|Allocating during GC!|Unhandled condition|Entering the debugger|global debugger invoked' "$serial_log"; then
    forbidden_seen=true
fi

end_image_sha256=$(sha256_file "$image")
{
    printf 'finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'qemu_exit=%s\n' "$qemu_exit"
    printf 'timed_out=%s\n' "$timed_out"
    printf 'forbidden_seen=%s\n' "$forbidden_seen"
    printf 'image_sha256_after=%s\n' "$end_image_sha256"
    printf 'base_image_unchanged=%s\n' "$([[ "$end_image_sha256" == "$actual_image_sha256" ]] && echo true || echo false)"
} >> "$evidence"

[[ "$end_image_sha256" == "$actual_image_sha256" ]] || { echo "Base image changed during smoke run" >&2; exit 2; }

set +e
"$script_dir/assert-serial-log.sh" \
    --mode "$mode" \
    --log "$serial_log" \
    --qemu-exit "$qemu_exit" \
    --timed-out "$timed_out" \
    --expected-pass-exit "$expected_pass_exit" \
    --expected-fail-exit "$expected_fail_exit" \
    --expected-test-count "$expected_test_count"
oracle_exit=$?
set -e
printf 'oracle_exit=%s\n' "$oracle_exit" >> "$evidence"
exit "$oracle_exit"
