#!/usr/bin/env python3
"""Check Common Lisp delimiter balance without evaluating source files."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

LISP_SUFFIXES = {".lisp", ".lsp", ".cl"}


def check_file(path: Path) -> list[tuple[int, int, str]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    stack: list[tuple[int, int]] = []
    errors: list[tuple[int, int, str]] = []
    state = "code"
    block_depth = 0
    line, column, index = 1, 0, 0

    def advance(fragment: str) -> None:
        nonlocal line, column
        for character in fragment:
            if character == "\n":
                line, column = line + 1, 0
            else:
                column += 1

    while index < len(text):
        character = text[index]

        if state == "string":
            if character == "\\" and index + 1 < len(text):
                advance(text[index : index + 2])
                index += 2
                continue
            if character == '"':
                state = "code"
            advance(character)
            index += 1
            continue

        if state == "multiple-escape":
            if character == "\\" and index + 1 < len(text):
                advance(text[index : index + 2])
                index += 2
                continue
            if character == "|":
                state = "code"
            advance(character)
            index += 1
            continue

        if state == "line-comment":
            if character == "\n":
                state = "code"
            advance(character)
            index += 1
            continue

        if state == "block-comment":
            if text.startswith("#|", index):
                block_depth += 1
                advance("#|")
                index += 2
            elif text.startswith("|#", index):
                block_depth -= 1
                advance("|#")
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                advance(character)
                index += 1
            continue

        # Code state. Reader syntax below prevents delimiters in literals and
        # escaped symbols from being mistaken for structural parentheses.
        if text.startswith("#|", index):
            state, block_depth = "block-comment", 1
            advance("#|")
            index += 2
        elif character == ";":
            state = "line-comment"
            advance(character)
            index += 1
        elif character == '"':
            state = "string"
            advance(character)
            index += 1
        elif character == "|":
            state = "multiple-escape"
            advance(character)
            index += 1
        elif text.startswith("#\\", index):
            # A character literal is either one delimiter character or a
            # named token such as #\\Newline.
            end = index + 2
            if end < len(text) and text[end] in '()[]{}";| \t\r\n':
                end += 1
            else:
                while end < len(text) and text[end] not in '()[]{}";| \t\r\n':
                    end += 1
            advance(text[index:end])
            index = end
        elif character == "\\" and index + 1 < len(text):
            # Single escape in a symbol (for example :\| or \()).
            advance(text[index : index + 2])
            index += 2
        elif character == "(":
            stack.append((line, column))
            advance(character)
            index += 1
        elif character == ")":
            if stack:
                stack.pop()
            else:
                errors.append((line, column, "unexpected )"))
            advance(character)
            index += 1
        else:
            advance(character)
            index += 1

    if state == "string":
        errors.append((line, column, "unterminated string"))
    elif state == "multiple-escape":
        errors.append((line, column, "unterminated multiple-escape symbol"))
    elif state == "block-comment":
        errors.append((line, column, "unterminated block comment"))
    errors.extend((opened_line, opened_column, "unclosed (") for opened_line, opened_column in reversed(stack))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path("."))
    args = parser.parse_args()
    files = sorted(
        path
        for path in args.root.rglob("*")
        if path.is_file() and path.suffix.lower() in LISP_SUFFIXES and ".git" not in path.parts
    )
    failed = 0
    for path in files:
        errors = check_file(path)
        if errors:
            failed += 1
            for line, column, message in errors:
                print(f"{path}:{line}:{column}: {message}")
    print(f"checked={len(files)} files, files_with_errors={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
