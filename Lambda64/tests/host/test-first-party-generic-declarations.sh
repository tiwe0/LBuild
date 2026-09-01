#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

first_match_line() {
    local file=$1
    local text=$2
    local match

    match=$(grep -nF "$text" "$file" | head -n1 || true)
    printf '%s' "${match%%:*}"
}

assert_contains() {
    local file=$1
    local text=$2

    [[ -n "$(first_match_line "$file" "$text")" ]] || {
        echo "Missing required form in ${file#"$repo_root/"}: $text" >&2
        exit 1
    }
}

assert_precedes() {
    local file=$1
    local declaration=$2
    local method=$3
    local declaration_line
    local method_line

    declaration_line=$(first_match_line "$file" "$declaration")
    method_line=$(first_match_line "$file" "$method")

    [[ -n "$declaration_line" ]] || {
        echo "Missing generic declaration in ${file#"$repo_root/"}: $declaration" >&2
        exit 1
    }
    [[ -n "$method_line" ]] || {
        echo "Missing specialized method in ${file#"$repo_root/"}: $method" >&2
        exit 1
    }
    (( declaration_line < method_line )) || {
        echo "Generic declaration must precede its method in ${file#"$repo_root/"}: $declaration" >&2
        exit 1
    }
}

assert_load_order() {
    local declaration_file=$1
    local first_use_file=$2
    local manifest="$repo_root/tools/cold-generator2/cold-generator.lisp"
    local declaration_line
    local first_use_line

    declaration_line=$(first_match_line "$manifest" "\"$declaration_file\"")
    first_use_line=$(first_match_line "$manifest" "\"$first_use_file\"")

    [[ -n "$declaration_line" && -n "$first_use_line" ]] || {
        echo "Cold-image load manifest is missing a generic declaration or first-use file" >&2
        exit 1
    }
    (( declaration_line < first_use_line )) || {
        echo "Generic declaration file must load before its first method user" >&2
        exit 1
    }
}

assert_contains "$repo_root/system/clos/closette.lisp" \
    '(defgeneric make-load-form (object &optional environment))'
assert_contains "$repo_root/system/clos/closette.lisp" \
    '(warn "Implicit definition of generic function ~S." gf-name))'
if grep -Fq 'Implicit defintion of generic function' "$repo_root/system/clos/closette.lisp"; then
    echo 'Implicit generic warning text contains the historical spelling error' >&2
    exit 1
fi
assert_load_order 'system/clos/closette.lisp' 'runtime/simd.lisp'

if grep -Fq '(defgeneric make-load-form (object &optional environment))' \
    "$repo_root/system/file-compiler.lisp"; then
    echo 'MAKE-LOAD-FORM must have one early CLOS declaration, not a late duplicate' >&2
    exit 1
fi

assert_precedes "$repo_root/net/dhcp.lisp" \
    '(defgeneric renew-lease (lease))' \
    '(defmethod renew-lease ((lease dhcp-lease))'

assert_precedes "$repo_root/gui/keymaps.lisp" \
    '(defvar *current-keymap*)' \
    '(defmethod initialize-instance :after ((map simple-keymap) &key)'
assert_contains "$repo_root/gui/package.lisp" '(defvar mezzano.internals::*desktop*)'

ipl_file="$repo_root/ipl.lisp"
assert_precedes "$ipl_file" \
    '(sys.int::cal "sys:source;gui;package.lisp")' \
    '(sys.int::cal "sys:source;gui;theme.lisp")'

fat_file="$repo_root/file/fat32.lisp"
assert_precedes "$fat_file" \
    '(defgeneric read-fat (disk filesystem &optional fat-array))' \
    '(defmethod read-fat (disk (fat12 fat12) &optional fat-array)'
assert_precedes "$fat_file" \
    '(defgeneric write-fat (disk filesystem fat))' \
    '(defmethod write-fat (disk (fat12 fat12) fat)'
assert_precedes "$fat_file" \
    '(defgeneric (setf fat-value) (value filesystem fat index))' \
    '(defmethod (setf fat-value) (value (fat12 fat12) fat idx)'
assert_precedes "$fat_file" \
    '(defgeneric root-dir-sectors (filesystem))' \
    '(defmethod root-dir-sectors ((fat12 fat12))'
assert_precedes "$fat_file" \
    '(defgeneric last-cluster-value (filesystem))' \
    '(defmethod last-cluster-value ((fat12 fat12))'
assert_precedes "$fat_file" \
    '(defgeneric read-root-directory (disk filesystem fat))' \
    '(defmethod read-root-directory (disk (fat12 fat12) fat)'

trentino_file="$repo_root/gui/trentino.lisp"
assert_precedes "$trentino_file" \
    '(defgeneric play-audio-stream (container))' \
    '(defmethod play-audio-stream ((container cl-video:av-container))'
assert_precedes "$trentino_file" \
    '(defgeneric play-video-stream (container))' \
    '(defmethod play-video-stream ((container cl-video:av-container))'

echo 'first-party generic declaration contract passed'
