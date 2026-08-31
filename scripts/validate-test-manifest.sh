#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 MANIFEST" >&2
    exit 2
fi

manifest=$1
[[ -s $manifest ]] || { echo "Test manifest is missing or empty: $manifest" >&2; exit 2; }

expected_keys=(
    format profile image_sha256 lambda64_sha lambda64_dirty lbuild_sha lbuild_dirty
    build_command sbcl_version qemu_version created_utc
)
values=()
index=0

while IFS=$'\t' read -r key value extra || [[ -n ${key:-}${value:-}${extra:-} ]]; do
    if [[ $index -ge ${#expected_keys[@]} ]]; then
        echo "Unexpected extra manifest field: ${key:-<empty>}" >&2
        exit 2
    fi
    if [[ -n ${extra:-} || $key != "${expected_keys[$index]}" || -z ${value:-} ]]; then
        echo "Malformed manifest field at line $((index + 1)): expected ${expected_keys[$index]}" >&2
        exit 2
    fi
    if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$value"; then
        echo "Manifest field contains control characters: $key" >&2
        exit 2
    fi
    values+=("$value")
    index=$((index + 1))
done < "$manifest"

[[ $index -eq ${#expected_keys[@]} ]] || { echo "Test manifest is incomplete" >&2; exit 2; }
[[ ${values[0]} == lambda64-test-manifest-v1 ]] || { echo "Unsupported manifest format" >&2; exit 2; }
[[ ${values[1]} == test ]] || { echo "Manifest profile must be test" >&2; exit 2; }
[[ ${values[2]} =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid image SHA-256" >&2; exit 2; }
[[ ${values[3]} =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid Lambda64 Git SHA" >&2; exit 2; }
[[ ${values[4]} == true || ${values[4]} == false ]] || { echo "Invalid Lambda64 dirty flag" >&2; exit 2; }
[[ ${values[5]} =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid LBuild Git SHA" >&2; exit 2; }
[[ ${values[6]} == true || ${values[6]} == false ]] || { echo "Invalid LBuild dirty flag" >&2; exit 2; }
[[ ${values[10]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    echo "Invalid manifest timestamp" >&2
    exit 2
}
