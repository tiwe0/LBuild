#!/usr/bin/env bash
# Regression coverage for thread-pool pending-work priority scheduling.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
source_file=${THREAD_POOL_SOURCE:-"$repo_root/system/thread-pool.lisp"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-thread-pool-priority.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

python3 - "$source_file" "$tmp_dir/thread-pool.lisp" "${THREAD_POOL_PRIORITY_MUTATION_RUN:-}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

if '(declare (ignore priority))' in source:
    raise SystemExit('thread-pool priority is ignored')

def extract(start_marker):
    start = source.index(start_marker)
    depth = 0
    in_string = False
    in_comment = False
    escaped = False
    for index in range(start, len(source)):
        character = source[index]
        if in_comment:
            if character == "\n":
                in_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == ';':
            in_comment = True
        elif character == '"':
            in_string = True
        elif character == '(':
            depth += 1
        elif character == ')':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f'unterminated form starting at {start_marker!r}')

text = "\n\n".join((
    extract('(defclass thread-pool'),
    extract('(defclass work-item'),
    extract('(defun work-item-priority-rank'),
    extract('(defun enqueue-thread-pool-work-item'),
))

if sys.argv[3]:
    old = '(:high 2)'
    if old not in text:
        raise SystemExit('thread-pool priority mutation anchor missing')
    text = text.replace(old, '(:high 1)', 1)

Path(sys.argv[2]).write_text(text + '\n', encoding='utf-8')
PY

cat > "$tmp_dir/run.lisp" <<'EOF_LISP'
(defpackage :mezzano.supervisor (:use :cl))
(defpackage :mezzano.sync.thread-pool
  (:use :cl)
  (:local-nicknames (:sup :mezzano.supervisor)))
(in-package :mezzano.sync.thread-pool)

(load (or (sb-ext:posix-getenv "THREAD_POOL_FORMS")
          (error "THREAD_POOL_FORMS is not set")))

(defun check (value control &rest arguments)
  (unless value
    (apply #'error control arguments)))

(let* ((pool (make-instance 'thread-pool))
       (low (make-instance 'work-item :name :low :function (lambda ())
                           :thread-pool pool :priority :low))
       (normal-1 (make-instance 'work-item :name :normal-1 :function (lambda ())
                                :thread-pool pool :priority nil))
       (high-1 (make-instance 'work-item :name :high-1 :function (lambda ())
                              :thread-pool pool :priority :high))
       (high-2 (make-instance 'work-item :name :high-2 :function (lambda ())
                              :thread-pool pool :priority :high))
       (normal-2 (make-instance 'work-item :name :normal-2 :function (lambda ())
                                :thread-pool pool :priority :normal)))
  (dolist (item (list low normal-1 high-1 high-2 normal-2))
    (enqueue-thread-pool-work-item pool item))
  (check (equal (mapcar #'work-item-name (thread-pool-pending pool))
                '(:high-1 :high-2 :normal-1 :normal-2 :low))
         "thread-pool priority/FIFO order was not preserved: ~S"
         (mapcar #'work-item-name (thread-pool-pending pool))))

(format t "thread-pool priority queue semantics passed~%")
EOF_LISP

THREAD_POOL_FORMS="$tmp_dir/thread-pool.lisp" \
  sbcl --noinform --disable-debugger --script "$tmp_dir/run.lisp"

if [[ -z "${THREAD_POOL_PRIORITY_MUTATION_RUN:-}" ]]; then
  if THREAD_POOL_PRIORITY_MUTATION_RUN=1 bash "$0" >/dev/null 2>&1; then
    echo "thread-pool priority mutation unexpectedly survived" >&2
    exit 1
  fi
  echo "thread-pool priority mutation rejected"
fi
