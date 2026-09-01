#!/usr/bin/env python3
"""Validate repository-maintained Markdown documentation without dependencies."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
REQUIRED = {
    "title",
    "status",
    "owner",
    "last-verified",
    "verified-against",
    "review-cycle",
    "source-of-truth",
}
DOC_STATUSES = {"draft", "active", "historical", "deprecated"}
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
PATH_RE = re.compile(
    r"`((?:Lambda64|scripts|home|docs|\.github|Makefile|README\.md|"
    r"run-file-server\.lisp)[^`\n]*)`"
)


def parse_frontmatter(path: Path, text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        raise ValueError("missing YAML frontmatter")
    end = text.find("\n---\n", 4)
    if end < 0:
        raise ValueError("unterminated YAML frontmatter")
    values: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            raise ValueError(f"invalid frontmatter line: {line!r}")
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip()
    return values


def owner_values() -> set[str]:
    text = (DOCS / "meta" / "owners.md").read_text(encoding="utf-8")
    return set(re.findall(r"^\| `([^`]+)` \|", text, flags=re.MULTILINE))


def main() -> int:
    issues: list[str] = []
    owners = owner_values()
    markdown = sorted(DOCS.rglob("*.md"))

    for path in markdown:
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        try:
            metadata = parse_frontmatter(path, text)
        except ValueError as exc:
            issues.append(f"{rel}: {exc}")
            metadata = {}

        missing = REQUIRED - metadata.keys()
        if missing:
            issues.append(f"{rel}: missing metadata: {', '.join(sorted(missing))}")
        if metadata.get("status") not in DOC_STATUSES:
            issues.append(f"{rel}: invalid document status: {metadata.get('status')!r}")
        if metadata.get("owner") not in owners:
            issues.append(f"{rel}: unknown owner: {metadata.get('owner')!r}")

        for target in LINK_RE.findall(text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            raw = target.split("#", 1)[0]
            if raw and not (path.parent / raw).resolve().exists():
                issues.append(f"{rel}: broken Markdown link: {target}")

        for token in PATH_RE.findall(text):
            candidate = token.split(":", 1)[0].rstrip("/,.;")
            if "<" in candidate:
                continue
            if not (ROOT / candidate).exists():
                issues.append(f"{rel}: missing repository path: {token}")

    if issues:
        print("Documentation validation failed:", file=sys.stderr)
        for issue in issues:
            print(f"- {issue}", file=sys.stderr)
        return 1
    print(f"Documentation validation passed: {len(markdown)} Markdown files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
