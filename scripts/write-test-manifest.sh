#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 IMAGE MANIFEST REPOSITORY_ROOT SBCL QEMU BUILD_COMMAND" >&2
    exit 2
fi

image=$1
manifest=$2
repository_root=$3
sbcl_bin=$4
qemu_bin=$5
build_command=$6

[[ -s "$image" ]] || { echo "Test image not found or empty: $image" >&2; exit 2; }
repository_root=$(git -C "$repository_root" rev-parse --show-toplevel 2>/dev/null) || {
    echo "Repository checkout not found: $repository_root" >&2
    exit 2
}
[[ -f "$repository_root/Lambda64/lispos.asd" ]] || {
    echo "Lambda64 source tree not found in repository: $repository_root/Lambda64" >&2
    exit 2
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

one_line() {
    local value=$1
    if [[ -z $value || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
        echo "Manifest values must be non-empty and must not contain control delimiters" >&2
        exit 2
    fi
    printf '%s' "$value"
}

repository_sha=$(git -C "$repository_root" rev-parse HEAD)
lambda64_tree=$(git -C "$repository_root" rev-parse HEAD:Lambda64)
repository_dirty=false

worktree_dirty() {
    local root=$1 generated=$2 root_abs generated_abs generated_rel
    local status_args=(status --porcelain --untracked-files=normal -- .)

    root_abs=$(cd "$root" && pwd -P)
    generated_abs=$(cd "$(dirname "$generated")" && pwd -P)/$(basename "$generated")
    if [[ $generated_abs == "$root_abs/"* ]]; then
        generated_rel=${generated_abs#"$root_abs/"}
        if ! git -C "$root" ls-files --error-unmatch -- "$generated_rel" >/dev/null 2>&1; then
            status_args+=(":(exclude)$generated_rel")
        fi
    fi

    [[ -n $(git -C "$root" "${status_args[@]}") ]]
}

worktree_dirty "$repository_root" "$manifest" && repository_dirty=true
image_sha256=$(sha256_file "$image")
sbcl_version=$("$sbcl_bin" --version | head -n 1)
qemu_version=$("$qemu_bin" --version | head -n 1)
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

tmp="${manifest}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

emit() {
    local key=$1 value=$2
    printf '%s\t%s\n' "$key" "$(one_line "$value")" >> "$tmp"
}

: > "$tmp"
emit format lambda64-test-manifest-v2
emit profile test
emit image_sha256 "$image_sha256"
emit repository_sha "$repository_sha"
emit repository_dirty "$repository_dirty"
emit lambda64_tree "$lambda64_tree"
emit build_command "$build_command"
emit sbcl_version "$sbcl_version"
emit qemu_version "$qemu_version"
emit created_utc "$created_utc"

"$(dirname "$0")/validate-test-manifest.sh" "$tmp"
mv "$tmp" "$manifest"
trap - EXIT
echo "Wrote test-image manifest: $manifest"
