#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
pager=${PAGER_SOURCE:-"$repo_root/supervisor/pager.lisp"}
python3 - "$pager" <<'PY'
from pathlib import Path
import sys
import re
text = Path(sys.argv[1]).read_text()

def form(marker):
    start = text.index(marker)
    depth = 0
    string = False
    escape = False
    comment = False
    for i in range(start, len(text)):
        c = text[i]
        if comment:
            if c == '\n':
                comment = False
        elif string:
            if escape:
                escape = False
            elif c == '\\':
                escape = True
            elif c == '"':
                string = False
        elif c == ';':
            comment = True
        elif c == '"':
            string = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise RuntimeError(marker)

if '(defun block-info-map-level' not in text:
    raise SystemExit('missing static block-map helper')
helper = form('(defun block-info-map-level')
entry = form('(defun block-info-for-virtual-address-1')
if '(flet ' in entry.lower() or '(labels ' in entry.lower():
    raise SystemExit('pager block-map lookup still creates a local closure')
if 'block-info-map-level' not in entry:
    raise SystemExit('block-map lookup does not route through the static helper')
if '(make-simple-vector' in helper.lower():
    raise SystemExit('pager block-map helper explicitly allocates a heap vector')
for name in ('allocate-new-block-for-virtual-address', 'map-new-wired-page'):
    start = text.index(f'(defun {name}')
    header = text[start:text.index(')', start) + 1]
    if '&key' in header.lower():
        raise SystemExit(f'{name} still exposes a keyword lambda list on the pager path')
if '(defun %pager-allocate-page' not in text:
    raise SystemExit('missing positional pager page-allocation core')
page_core = form('(defun %pager-allocate-page')
if '%allocate-physical-pages' not in page_core:
    raise SystemExit('pager page-allocation core does not use the bootstrap-safe physical allocator')
if '(allocate-physical-pages 1 :type new-type)' in page_core:
    raise SystemExit('pager page-allocation core still invokes keyword physical allocation')
if '(:eager t)' in text:
    raise SystemExit('pager card-map allocation still uses keyword eager invocation')
if re.search(r'(?<!%)\(make-pte\s', text):
    raise SystemExit('pager sources still invoke keyword MAKE-PTE on a critical path')
if re.search(r'(?<!%)\(update-pte(?:-atomic)?\s', text):
    raise SystemExit('pager sources still invoke keyword PTE update helpers on a critical path')
hosted = form('(defun initialize-hosted-paging-system')
store_init = hosted.index('(initialize-store-freelist')
for diagnostic in ('(debug-print-line "BML4', '(debug-print-line "Running read-only.'):
    if hosted.find(diagnostic) < store_init:
        raise SystemExit(f'{diagnostic} runs before store metadata is published')
pager_init = form('(defun initialize-pager')
cold_reset = pager_init.index('(when defer-request-latch-p')
for flag in ('*pager-lazy-block-allocation-enabled*', '*pager-fast-path-enabled*'):
    if pager_init.find(flag, cold_reset) < 0:
        raise SystemExit(f'{flag} is not reset for cold pager bootstrap')
print('pager no-heap-closure contract passed')
PY
