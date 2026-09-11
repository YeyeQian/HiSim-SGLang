#!/usr/bin/env python3
"""Reject broken or unpublished local links in tracked Markdown files."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import urllib.parse


INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
REFERENCE_DEFINITION = re.compile(
    r"^[ \t]{0,3}\[[^\]]+\]:[ \t]*(?:<([^>]+)>|(\S+))", re.MULTILINE
)
EXTERNAL_PREFIXES = ("#", "http://", "https://", "mailto:")


def git_output(root: pathlib.Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), *args], text=True
    )


def local_targets(markdown: str):
    for raw in INLINE_LINK.findall(markdown):
        yield raw.strip().split(maxsplit=1)[0].strip("<>")
    for angle_target, plain_target in REFERENCE_DEFINITION.findall(markdown):
        yield angle_target or plain_target


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    tracked_docs = git_output(root, "ls-files", "*.md").splitlines()
    index_rows = git_output(root, "ls-files", "-s").splitlines()
    tracked = set()
    gitlinks = set()
    for row in index_rows:
        metadata, path = row.split("\t", 1)
        mode = metadata.split()[0]
        tracked.add(path)
        if mode == "160000":
            gitlinks.add(path)

    errors = []
    for document_relative in tracked_docs:
        document = root / document_relative
        for raw_target in local_targets(document.read_text(encoding="utf-8")):
            if not raw_target or raw_target.startswith(EXTERNAL_PREFIXES):
                continue
            target = urllib.parse.unquote(raw_target.split("#", 1)[0])
            if not target:
                continue
            resolved = (document.parent / target).resolve()
            try:
                relative = resolved.relative_to(root).as_posix()
            except ValueError:
                errors.append(
                    f"{document_relative}: link escapes repository: {raw_target}"
                )
                continue

            containing_gitlink = next(
                (
                    gitlink
                    for gitlink in gitlinks
                    if relative == gitlink or relative.startswith(gitlink + "/")
                ),
                None,
            )
            if containing_gitlink:
                if not resolved.exists():
                    errors.append(
                        f"{document_relative}: missing submodule link target: {raw_target}"
                    )
                continue

            published = relative in tracked or any(
                path.startswith(relative.rstrip("/") + "/") for path in tracked
            )
            if not resolved.exists():
                errors.append(f"{document_relative}: missing link target: {raw_target}")
            elif not published:
                errors.append(
                    f"{document_relative}: local link target is not tracked: {raw_target}"
                )

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Markdown links: PASS ({len(tracked_docs)} tracked documents)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
