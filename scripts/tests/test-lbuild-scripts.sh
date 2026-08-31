#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lbuild-script-tests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

mkdir -p "$tmp/repository/Lambda64"
git -C "$tmp/repository" init -q
printf 'tracked\n' > "$tmp/repository/tracked"
printf '(:test)\n' > "$tmp/repository/Lambda64/lispos.asd"
git -C "$tmp/repository" add tracked Lambda64/lispos.asd
git -C "$tmp/repository" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
mkdir -p "$tmp/bin"
cat > "$tmp/bin/sbcl" <<'EOF'
#!/usr/bin/env bash
printf 'SBCL test-version\n'
EOF
cat > "$tmp/bin/qemu" <<'EOF'
#!/usr/bin/env bash
printf 'QEMU emulator version test-version\n'
EOF
chmod +x "$tmp/bin/sbcl" "$tmp/bin/qemu"

printf 'image\n' > "$tmp/lambda64.image"
printf 'map\n' > "$tmp/lambda64.map"
printf 'symbols\n' > "$tmp/lambda64.symbol-table"

"$script_dir/assert-test-image-artifacts.sh" \
    "$tmp/lambda64.image" "$tmp/lambda64.map" "$tmp/lambda64.symbol-table"
: > "$tmp/lambda64.map"
expect_failure "$script_dir/assert-test-image-artifacts.sh" \
    "$tmp/lambda64.image" "$tmp/lambda64.map" "$tmp/lambda64.symbol-table"
printf 'map\n' > "$tmp/lambda64.map"

manifest="$tmp/repository/lambda64.test-manifest"
"$script_dir/write-test-manifest.sh" \
    "$tmp/lambda64.image" "$manifest" "$tmp/repository" \
    "$tmp/bin/sbcl" "$tmp/bin/qemu" 'make test-image' >/dev/null
"$script_dir/validate-test-manifest.sh" "$manifest"
grep -q $'^repository_dirty\tfalse$' "$manifest" || fail "clean repository marked dirty"
"$script_dir/write-test-manifest.sh" \
    "$tmp/lambda64.image" "$manifest" "$tmp/repository" \
    "$tmp/bin/sbcl" "$tmp/bin/qemu" 'make test-image' >/dev/null
grep -q $'^repository_dirty\tfalse$' "$manifest" || fail "generated manifest made a clean repository dirty"

printf 'untracked\n' > "$tmp/repository/Lambda64/untracked"
"$script_dir/write-test-manifest.sh" \
    "$tmp/lambda64.image" "$manifest" "$tmp/repository" \
    "$tmp/bin/sbcl" "$tmp/bin/qemu" 'make test-image' >/dev/null
grep -q $'^repository_dirty\ttrue$' "$manifest" || fail "dirty repository not recorded"

cp "$manifest" "$tmp/malformed.test-manifest"
sed -i.bak '/^image_sha256/d' "$tmp/malformed.test-manifest"
rm -f "$tmp/malformed.test-manifest.bak"
expect_failure "$script_dir/validate-test-manifest.sh" "$tmp/malformed.test-manifest"
printf 'unexpected\tfield\n' >> "$manifest"
expect_failure "$script_dir/validate-test-manifest.sh" "$manifest"
: > "$tmp/lambda64.image"
expect_failure "$script_dir/write-test-manifest.sh" \
    "$tmp/lambda64.image" "$manifest" "$tmp/repository" \
    "$tmp/bin/sbcl" "$tmp/bin/qemu" 'make test-image'

config="$tmp/config.lisp"
printf 'original config\n' > "$config"
original_sha=$(shasum -a 256 "$config" | awk '{print $1}')
"$script_dir/with-temporary-config.sh" \
    "$config" 10.0.2.2 /tmp/home/ /tmp/source/ -- \
    bash -c 'grep -q "REMOTE:/tmp/home/" "$1"' bash "$config"
[[ $(shasum -a 256 "$config" | awk '{print $1}') == "$original_sha" ]] || fail "config not restored after success"

expect_failure "$script_dir/with-temporary-config.sh" \
    "$config" 10.0.2.2 /tmp/home/ /tmp/source/ -- false
[[ $(shasum -a 256 "$config" | awk '{print $1}') == "$original_sha" ]] || fail "config not restored after failure"

missing_config="$tmp/missing/config.lisp"
mkdir -p "$(dirname "$missing_config")"
"$script_dir/with-temporary-config.sh" \
    "$missing_config" 10.0.2.2 /tmp/home/ /tmp/source/ -- true
[[ ! -e $missing_config ]] || fail "previously absent config was not removed"

# A caller-provided CI=false must not override the test profile.  Command-line
# make variables propagate through MAKEFLAGS, so test-image must pass CI=true
# as a recursive make command-line variable rather than an environment prefix.
dry_run=$(make -C "$script_dir/.." -n \
    CI=false \
    LAMBDA64_DIR=Lambda64 \
    IMAGE=lambda64.image \
    test-image)
grep -Eq 'bash ".*/Lambda64" "true" ".*/lambda64"' <<< "$dry_run" || \
    fail "test-image did not force CI=true against a caller override"

matrix=$($script_dir/run-local-test-matrix.sh \
    --suite integration --stress-repetitions 2 --list)
[[ $(wc -l <<< "$matrix" | tr -d ' ') -eq 3 ]] || fail "integration matrix does not contain two scenarios"
grep -q $'^positive-smp\tpositive\t4\t2G$' <<< "$matrix" || fail "integration matrix lacks positive SMP"
grep -q $'^injected-failure\tinjected-failure\t4\t2G$' <<< "$matrix" || fail "integration matrix lacks injected failure"

matrix=$($script_dir/run-local-test-matrix.sh \
    --suite stress --stress-repetitions 2 --list)
[[ $(wc -l <<< "$matrix" | tr -d ' ') -eq 6 ]] || fail "stress matrix scenario count is wrong"
grep -q $'^repeat-smp-2\tpositive\t4\t2G$' <<< "$matrix" || fail "stress matrix lacks repetition"
grep -q $'^single-cpu\tpositive\t1\t2G$' <<< "$matrix" || fail "stress matrix lacks single CPU"
grep -q $'^low-memory\tpositive\t4\t1536M$' <<< "$matrix" || fail "stress matrix lacks constrained memory"
expect_failure "$script_dir/run-local-test-matrix.sh" --suite stress --stress-repetitions 0 --list

echo "LBuild script tests passed"
