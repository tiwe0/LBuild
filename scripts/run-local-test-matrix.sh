#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lbuild_root=$(cd "$script_dir/.." && pwd)

suite=integration
lambda64_root=
image=
manifest=
fixture_root=
results_root="$lbuild_root/test-results"
timeout_seconds=${LOCAL_TEST_TIMEOUT_SECONDS:-4800}
stress_repetitions=${STRESS_REPETITIONS:-3}
sbcl_bin=${SBCL:-sbcl}
list_only=false

usage() {
    cat <<'EOF'
Usage: run-local-test-matrix.sh [options]

Options:
  --suite integration|stress
  --lambda64-root PATH
  --image PATH
  --manifest PATH
  --fixture-root PATH
  --results-root PATH
  --timeout SECONDS
  --stress-repetitions COUNT
  --sbcl PATH
  --list                 Print the resolved scenario matrix without running it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite) suite=${2-}; shift 2 ;;
        --lambda64-root) lambda64_root=${2-}; shift 2 ;;
        --image) image=${2-}; shift 2 ;;
        --manifest) manifest=${2-}; shift 2 ;;
        --fixture-root) fixture_root=${2-}; shift 2 ;;
        --results-root) results_root=${2-}; shift 2 ;;
        --timeout) timeout_seconds=${2-}; shift 2 ;;
        --stress-repetitions) stress_repetitions=${2-}; shift 2 ;;
        --sbcl) sbcl_bin=${2-}; shift 2 ;;
        --list) list_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$suite" in integration|stress) ;; *) echo "Invalid suite: $suite" >&2; exit 2 ;; esac
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout: $timeout_seconds" >&2; exit 2; }
[[ "$stress_repetitions" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid stress repetition count: $stress_repetitions" >&2; exit 2; }

scenarios=()
if [[ "$suite" == integration ]]; then
    scenarios+=("positive-smp|positive|4|2G")
    scenarios+=("injected-failure|injected-failure|4|2G")
else
    for ((iteration = 1; iteration <= stress_repetitions; iteration++)); do
        scenarios+=("repeat-smp-${iteration}|positive|4|2G")
    done
    scenarios+=("single-cpu|positive|1|2G")
    scenarios+=("low-memory|positive|4|1536M")
    scenarios+=("injected-failure|injected-failure|4|2G")
fi

if $list_only; then
    printf 'name\tmode\tcpus\tmemory\n'
    for scenario in "${scenarios[@]}"; do
        IFS='|' read -r name mode cpus memory <<< "$scenario"
        printf '%s\t%s\t%s\t%s\n' "$name" "$mode" "$cpus" "$memory"
    done
    exit 0
fi

for required in lambda64_root image manifest fixture_root; do
    eval "value=\${$required}"
    [[ -n "$value" ]] || { echo "Missing --${required//_/-}" >&2; exit 2; }
done

lambda64_root=$(cd "$lambda64_root" && pwd)
image=$(cd "$(dirname "$image")" && pwd)/$(basename "$image")
manifest=$(cd "$(dirname "$manifest")" && pwd)/$(basename "$manifest")
fixture_root=$(cd "$fixture_root" && pwd)
smoke_runner="$lambda64_root/tools/ci/run-arm64-smoke.sh"

[[ -x "$smoke_runner" ]] || { echo "Smoke runner is missing: $smoke_runner" >&2; exit 2; }
[[ -s "$image" ]] || { echo "Test image is missing: $image" >&2; exit 2; }
[[ -s "$manifest" ]] || { echo "Test manifest is missing: $manifest" >&2; exit 2; }
command -v "$sbcl_bin" >/dev/null 2>&1 || { echo "SBCL is not available: $sbcl_bin" >&2; exit 2; }
command -v lsof >/dev/null 2>&1 || { echo "lsof is required for local file-server readiness checks" >&2; exit 2; }

run_id="$(date -u +%Y%m%dT%H%M%SZ)-${suite}-$$"
results_dir="$results_root/$run_id"
mkdir -p "$results_dir"
summary="$results_dir/summary.tsv"
report="$results_dir/report.md"
server_log="$results_dir/file-server.log"
printf 'scenario\tmode\tcpus\tmemory\tstatus\texit\tserial_log\tevidence\n' > "$summary"

if lsof -nP -iTCP:2599 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "TCP port 2599 is already in use; refusing to stop an unowned file server" >&2
    exit 2
fi

server_pid=
cleanup() {
    if [[ -n "${server_pid:-}" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

make -C "$lbuild_root" --no-print-directory \
    LAMBDA64_DIR="$lambda64_root" \
    SBCL="$sbcl_bin" \
    run-file-server > "$server_log" 2>&1 &
server_pid=$!

ready=false
for _ in {1..30}; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "Lambda64 file server exited before becoming ready" >&2
        cat "$server_log" >&2
        exit 2
    fi
    if lsof -nP -iTCP:2599 -sTCP:LISTEN >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 1
done
$ready || { echo "Timed out waiting for Lambda64 file server on TCP 2599" >&2; exit 2; }

repository_sha=$(git -C "$lbuild_root" rev-parse HEAD)
failed=0

for scenario in "${scenarios[@]}"; do
    IFS='|' read -r name mode cpus memory <<< "$scenario"
    serial_log="$results_dir/${name}.serial.log"
    evidence="$results_dir/${name}.evidence.txt"
    console_log="$results_dir/${name}.console.log"
    echo "==> local ${suite}: ${name} (mode=${mode}, cpus=${cpus}, memory=${memory})"
    set +e
    "$smoke_runner" \
        --mode "$mode" \
        --image "$image" \
        --manifest "$manifest" \
        --fixture-root "$fixture_root" \
        --serial-log "$serial_log" \
        --evidence "$evidence" \
        --timeout "$timeout_seconds" \
        --cpus "$cpus" \
        --memory "$memory" \
        --expected-repository-sha "$repository_sha" \
        --allow-dirty \
        2>&1 | tee "$console_log"
    scenario_exit=${PIPESTATUS[0]}
    set -e
    if [[ "$scenario_exit" -eq 0 ]]; then
        status=pass
    else
        status=fail
        failed=$((failed + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$mode" "$cpus" "$memory" "$status" "$scenario_exit" \
        "$(basename "$serial_log")" "$(basename "$evidence")" >> "$summary"
done

{
    printf '# Lambda64 local %s report\n\n' "$suite"
    printf -- '- Run ID: `%s`\n' "$run_id"
    printf -- '- Repository: `%s`\n' "$repository_sha"
    printf -- '- Image: `%s`\n' "$image"
    printf -- '- Manifest: `%s`\n' "$manifest"
    printf -- '- Scenarios: %s\n' "${#scenarios[@]}"
    printf -- '- Failures: %s\n\n' "$failed"
    printf '| Scenario | Mode | CPUs | Memory | Result | Exit |\n'
    printf '|---|---:|---:|---:|---:|---:|\n'
    tail -n +2 "$summary" | while IFS=$'\t' read -r name mode cpus memory status scenario_exit _; do
        printf '| %s | %s | %s | %s | %s | %s |\n' \
            "$name" "$mode" "$cpus" "$memory" "$status" "$scenario_exit"
    done
} > "$report"

echo "Local test report: $report"
echo "RESULTS_DIR=$results_dir"
[[ "$failed" -eq 0 ]]
