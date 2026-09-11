#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
xp_source=${XP_FORMAT_SOURCE:-"$repo_root/system/xp-format.lisp"}
xp_stream_source=${XP_STREAM_SOURCE:-"$repo_root/system/xp.lisp"}
format_source=${FORMAT_SOURCE:-"$repo_root/system/format.lisp"}
sbcl=${SBCL:-sbcl}
forms_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-xp-format-floats.XXXXXX.lisp")
test_file=$(mktemp "${TMPDIR:-/tmp}/mezzano-xp-format-floats-test.XXXXXX.lisp")
trap 'rm -f "$forms_file" "$test_file"' EXIT

python3 - "$xp_source" "$forms_file" "$xp_stream_source" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
xp_stream_source = Path(sys.argv[3]).read_text(encoding="utf-8")

def extract(prefix):
    start = source.index(prefix)
    depth = 0
    in_string = False
    escaped = False
    in_line_comment = False
    for i in range(start, len(source)):
        char = source[i]
        if in_line_comment:
            if char == "\n":
                in_line_comment = False
            continue
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == ";":
            in_line_comment = True
            continue
        if char == '"':
            in_string = True
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    raise SystemExit(f"unbalanced form for {prefix}")

def require(description, text, pattern):
    if not re.search(pattern, text, re.S):
        raise SystemExit(f"missing XP format contract: {description}")

handler_contracts = {
    "~F defaults and modifier order": (
        "(def-format-handler #\\F",
        r"parse-params start '\(nil nil 0 nil #\\Space\).*"
        r"format-float XP ,\(get-arg\) the-params ',atsign ',colon"),
    "~E defaults and modifier order": (
        "(def-format-handler #\\E",
        r"parse-params start '\(nil nil nil 1 nil nil nil\).*"
        r"format-exponent XP ,\(get-arg\) the-params ',atsign ',colon"),
    "~G defaults and modifier order": (
        "(def-format-handler #\\G",
        r"parse-params start '\(nil nil nil 1 nil nil nil\).*"
        r"format-general-float XP ,\(get-arg\) the-params ',atsign ',colon"),
    "~$ defaults and modifier order": (
        "(def-format-handler #\\$",
        r"parse-params start '\(2 1 0 #\\Space\).*"
        r"format-monetary XP ,\(get-arg\) the-params ',atsign ',colon"),
}
for description, (prefix, pattern) in handler_contracts.items():
    require(description, extract(prefix), pattern)

require("XP character stream write-char delegation", xp_stream_source,
        r"defmethod mezzano\.gray:stream-write-char \(\(stream xp-structure\) char\).*"
        r"\(write-char\+ char stream\)")
require("XP character stream write-string delegation", xp_stream_source,
        r"defmethod mezzano\.gray:stream-write-string \(\(stream xp-structure\) string.*"
        r"\(write-string\+ string stream start \(or end \(length string\)\)\)")

forms = [
    extract("(defun format-float"),
    extract("(defun format-exponent"),
    extract("(defun format-general-float"),
    extract("(defun format-monetary"),
]
Path(sys.argv[2]).write_text("\n\n".join(forms) + "\n", encoding="utf-8")
PY

cat >"$test_file" <<'LISP'
(require :asdf)
(sb-ext:unlock-package :cl)
(setf sb-ext:*on-package-variance* '(:warn nil))

(defpackage :mezzano.gray
  (:use :cl)
  (:export #:stream-line-column #:stream-line-length))
(in-package :mezzano.gray)
(defun stream-line-column (stream)
  (declare (ignore stream))
  nil)
(defun stream-line-length (stream)
  (declare (ignore stream))
  72)

(defpackage :mezzano.internals (:use :cl))
(in-package :mezzano.internals)
(declaim (declaration lambda-name))

;; The real source implements CL:FORMAT, which cannot be redefined on the
;; host, so this scaffold shadows it.  That intentionally differs from the
;; source's own DEFPACKAGE; downgrade the resulting variance report so the
;; difference does not have to be papered over in the target source.
(setf sb-ext:*on-package-variance* '(:warn t))
(defpackage :mezzano.format
  (:use :cl)
  (:shadow #:format #:formatter))
(load (sb-ext:posix-getenv "FORMAT_SOURCE"))

(defpackage :mezzano.xp (:use :cl))
(in-package :mezzano.xp)
(load (sb-ext:posix-getenv "XP_FLOAT_FORMS"))

(in-package :cl-user)
(defun assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S, got ~S" description expected actual)))

(defun render (function object params atsign colon)
  (with-output-to-string (stream)
    (funcall function stream object params atsign colon)))

(assert-equal "    1.25"
              (render #'mezzano.xp::format-float 1.25 '(8 2 0 nil #\Space) nil nil)
              "XP ~F honors width and precision")
(assert-equal "    1.250E+0"
              (render #'mezzano.xp::format-exponent 1.25 '(12 3 nil 1 nil #\Space nil) nil nil)
              "XP ~E honors width and precision")
(assert-equal "  9.999e-4"
              (render #'mezzano.xp::format-general-float 9.999e-4 '(10 3 nil 1 nil #\Space nil) nil nil)
              "XP ~G selects exponential rendering")
(assert-equal "-___001.25"
              (render #'mezzano.xp::format-monetary -1.25 '(2 3 10 #\_) nil t)
              "XP ~$ honors colon sign placement and padding")
(assert-equal "       FOO"
              (render #'mezzano.xp::format-monetary 'foo '(2 1 10 #\_) nil nil)
              "XP ~$ preserves non-real fallback width")

(format t "XP FORMAT float delegation semantics passed~%")
LISP

FORMAT_SOURCE="$format_source" \
XP_FLOAT_FORMS="$forms_file" \
  "$sbcl" --noinform --disable-debugger --script "$test_file"

if [[ ${XP_FLOAT_MUTATION_RUN:-0} != 1 ]]; then
  mutant_dir=$(mktemp -d "${TMPDIR:-/tmp}/mezzano-xp-format-float-mutants.XXXXXX")
  trap 'rm -f "$forms_file" "$test_file"; rm -rf "$mutant_dir"' EXIT
  python3 - "$xp_source" "$mutant_dir" <<'MUTANT_PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutants = {
    "fixed": ("mezzano.format::format-fixed-float", "mezzano.format::format-integer"),
    "exponent": ("mezzano.format::format-exponent-float", "mezzano.format::format-integer"),
    "general": ("mezzano.format::format-general-float", "mezzano.format::format-integer"),
    "monetary": ("mezzano.format::format-monetary-float", "mezzano.format::format-integer"),
}
for name, (original, replacement) in mutants.items():
    mutant = source.replace(original, replacement, 1)
    if mutant == source:
        raise SystemExit(f"unable to create {name} mutant")
    Path(sys.argv[2], f"{name}.lisp").write_text(mutant, encoding="utf-8")

handler_mutants = {
    "fixed-defaults": ("(def-format-handler #\\F", "parse-params start '(nil nil 0 nil #\\Space)",
                       "parse-params start '(99 88 77 #\\! #\\_)"),
    "exponent-defaults": ("(def-format-handler #\\E", "parse-params start '(nil nil nil 1 nil nil nil)",
                          "parse-params start '(99 88 77 66 #\\! #\\_ #\\Q)"),
    "general-defaults": ("(def-format-handler #\\G", "parse-params start '(nil nil nil 1 nil nil nil)",
                         "parse-params start '(99 88 77 66 #\\! #\\_ #\\Q)"),
    "monetary-defaults": ("(def-format-handler #\\$", "parse-params start '(2 1 0 #\\Space)",
                          "parse-params start '(9 8 7 #\\_)"),
    "fixed-modifiers": ("(def-format-handler #\\F", "format-float XP ,(get-arg) the-params ',atsign ',colon",
                        "format-float XP ,(get-arg) the-params ',colon ',atsign"),
    "exponent-modifiers": ("(def-format-handler #\\E", "format-exponent XP ,(get-arg) the-params ',atsign ',colon",
                           "format-exponent XP ,(get-arg) the-params ',colon ',atsign"),
    "general-modifiers": ("(def-format-handler #\\G", "format-general-float XP ,(get-arg) the-params ',atsign ',colon",
                          "format-general-float XP ,(get-arg) the-params ',colon ',atsign"),
    "monetary-modifiers": ("(def-format-handler #\\$", "format-monetary XP ,(get-arg) the-params ',atsign ',colon",
                           "format-monetary XP ,(get-arg) the-params ',colon ',atsign"),
}
for name, (prefix, original, replacement) in handler_mutants.items():
    start = source.index(prefix)
    end = source.find("(def-format-handler", start + len(prefix))
    if end == -1:
        end = len(source)
    handler = source[start:end]
    mutated_handler = handler.replace(original, replacement, 1)
    if mutated_handler == handler:
        raise SystemExit(f"unable to create {name} mutant")
    mutant = source[:start] + mutated_handler + source[end:]
    Path(sys.argv[2], f"{name}.lisp").write_text(mutant, encoding="utf-8")
MUTANT_PY
  for mutant in "$mutant_dir"/*.lisp; do
    if XP_FLOAT_MUTATION_RUN=1 XP_FORMAT_SOURCE="$mutant" "$0" >/dev/null 2>&1; then
      echo "XP float delegation mutation survived: $mutant" >&2
      exit 1
    fi
  done
  python3 - "$xp_stream_source" "$mutant_dir/xp-stream.lisp" <<'STREAM_MUTANT_PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
mutant = source.replace("(write-char+ char stream)", "(values char)", 1)
if mutant == source:
    raise SystemExit("unable to create XP stream protocol mutant")
Path(sys.argv[2]).write_text(mutant, encoding="utf-8")
STREAM_MUTANT_PY
  if XP_FLOAT_MUTATION_RUN=1 XP_STREAM_SOURCE="$mutant_dir/xp-stream.lisp" "$0" >/dev/null 2>&1; then
    echo "XP stream delegation mutation survived" >&2
    exit 1
  fi
  echo "XP FORMAT float delegation mutation negatives passed"
fi
