#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${1:-$script_dir/../..}" && pwd)
quicklisp_setup=${LAMBDA64_QUICKLISP_SETUP:-"$HOME/quicklisp/setup.lisp"}

[[ -s "$quicklisp_setup" ]] || {
    echo "Quicklisp setup not found: $quicklisp_setup" >&2
    exit 2
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-arm64-codegen.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/trace.lisp" <<'EOF'
(require :asdf)
(load (uiop:getenv "LAMBDA64_QUICKLISP_SETUP"))
(push (pathname (uiop:getenv "LAMBDA64_REPO_ROOT")) asdf:*central-registry*)
(asdf:load-system :lispos)
(cold-generator:set-up-cross-compiler :architecture :arm64)
(let ((mezzano.compiler::*trace-asm* :full)
      (mezzano.compiler::*target-architecture* :arm64))
  (mezzano.compiler::cross-compile-file
   (merge-pathnames "system/gc.lisp" (pathname (uiop:getenv "LAMBDA64_REPO_ROOT")))
   :output-file (pathname (uiop:getenv "LAMBDA64_TRACE_OUTPUT"))))
(sb-ext:quit)
EOF

(
    cd "$repo_root"
    LAMBDA64_QUICKLISP_SETUP="$quicklisp_setup" \
    LAMBDA64_REPO_ROOT="$repo_root/" \
    LAMBDA64_TRACE_OUTPUT="$tmp/gc.llf" \
        sbcl --script "$tmp/trace.lisp" > "$tmp/full-trace.log" 2>&1
)

awk '
  /^SCAVENGE-OBJECT:$/ { emit=1 }
  /^SCAN-ERROR:$/      { exit }
  emit
' "$tmp/full-trace.log" > "$tmp/scavenge-object.trace"

[[ -s "$tmp/scavenge-object.trace" ]] || {
    echo "SCAVENGE-OBJECT was not found in the ARM64 compiler trace" >&2
    exit 1
}

grep -Fq '(CYCLE-KIND 0 :VALUE)' "$tmp/scavenge-object.trace" || {
    echo "SCAVENGE-OBJECT no longer preserves CYCLE-KIND in its spill slot" >&2
    exit 1
}
grep -Eq 'LDR .*\(:X29 -8\)' "$tmp/scavenge-object.trace" || {
    echo "SCAVENGE-OBJECT does not reload CYCLE-KIND from its spill slot" >&2
    exit 1
}
grep -Fq ':MAJOR' "$tmp/scavenge-object.trace" || {
    echo "SCAVENGE-OBJECT trace does not contain the major-cycle dispatch" >&2
    exit 1
}

# Regression for the first-GC miscompile: when X13/X14 were admitted as
# experimental callee-saved value registers, ADDRESS occupied X13 at a CFG
# join and the allocator emitted STR X13,[X29,#-8], overwriting CYCLE-KIND.
if grep -Eq '\(ADDRESS :X1[34] :VALUE\)' "$tmp/scavenge-object.trace"; then
    echo "Unsafe ARM64 CFG allocation: ADDRESS entered experimental X13/X14" >&2
    exit 1
fi

echo "ARM64 SCAVENGE-OBJECT codegen regression passed"
