#!/usr/bin/env python3
"""Fail the build when a new source file exceeds the line limit or an
oversized file grows beyond its baseline allowance.

Responsibilities:
- Enforce a hard per-file line cap (default 600) for new files.
- Allow pre-existing oversized files to live at their recorded baseline,
  but not to grow further.
- Prune well-known noisy directories (target/, node_modules/, …) early
  instead of walking them and excluding per-file.
- Warn about stale baseline entries (files that no longer exist) and
  about shrink opportunities (files that now live well below their
  allowance).
- Validate the baseline JSON schema so that a typo does not silently
  default to a permissive limit.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path


DEFAULT_EXTENSIONS = [".rs", ".js", ".ts", ".tsx", ".jsx", ".css", ".html"]
DEFAULT_EXCLUDES = [
    ".git/**",
    ".cargo/**",
    ".cache/**",
    "target/**",
    "server/target/**",
    "static/wasm/**",
    ".claude/**",
]
_ALWAYS_PRUNE = {
    ".git",
    ".cargo",
    ".cache",
    "target",
    "node_modules",
    "__pycache__",
    ".claude",
}
# Ratchet tolerance: if a file's current size is this many lines below its
# baseline, the baseline is considered loose and we emit a non-blocking
# reminder to tighten it.
_SHRINK_NOTICE_SLACK = 50


@dataclass(frozen=True)
class BaselineConfig:
    max_lines: int
    include_extensions: frozenset[str]
    exclude_globs: tuple[str, ...]
    allowances: dict[str, int]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Repository root to scan.")
    parser.add_argument(
        "--max-lines",
        type=int,
        default=600,
        help="Maximum allowed lines for files not present in the baseline.",
    )
    parser.add_argument(
        "--baseline",
        required=True,
        help="JSON file containing current oversized-file allowances.",
    )
    parser.add_argument(
        "--extension",
        action="append",
        dest="extensions",
        help=(
            "File extension to scan (overrides baseline.include_extensions "
            "and DEFAULT_EXTENSIONS). Can be passed multiple times."
        ),
    )
    return parser.parse_args()


def count_lines(path: Path) -> int:
    text = path.read_text(encoding="utf-8", errors="ignore")
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def normalize_path(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def matches_any_glob(relative_path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch(relative_path, pattern) for pattern in patterns)


def _prune_prefixes(exclude_globs: tuple[str, ...]) -> tuple[str, ...]:
    prefixes: list[str] = []
    for pattern in exclude_globs:
        if pattern.endswith("/**"):
            prefixes.append(pattern[:-3])
    return tuple(prefixes)


def _is_pruned_dir(rel_dir: str, prune_prefixes: tuple[str, ...]) -> bool:
    return any(
        rel_dir == prefix or rel_dir.startswith(prefix + "/")
        for prefix in prune_prefixes
    )


def iter_source_files(
    root: Path,
    extensions: frozenset[str],
    exclude_globs: tuple[str, ...],
):
    prune_prefixes = _prune_prefixes(exclude_globs)
    for dirpath_str, dirnames, filenames in os.walk(root):
        dirpath = Path(dirpath_str)
        rel_dir = "" if dirpath == root else dirpath.relative_to(root).as_posix()

        if rel_dir and _is_pruned_dir(rel_dir, prune_prefixes):
            dirnames[:] = []
            continue

        dirnames[:] = sorted(
            d
            for d in dirnames
            if d not in _ALWAYS_PRUNE
            and not _is_pruned_dir(f"{rel_dir}/{d}" if rel_dir else d, prune_prefixes)
        )

        for name in filenames:
            suffix = Path(name).suffix
            if suffix not in extensions:
                continue
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if matches_any_glob(rel, exclude_globs):
                continue
            yield dirpath / name


def load_baseline(baseline_path: Path, cli_max_lines: int, cli_extensions: list[str] | None) -> BaselineConfig:
    raw = json.loads(baseline_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError(f"baseline {baseline_path} must be a JSON object")

    max_lines = raw.get("max_lines", cli_max_lines)
    if not isinstance(max_lines, int) or max_lines <= 0:
        raise ValueError(f"baseline.max_lines must be a positive integer, got {max_lines!r}")

    raw_extensions = cli_extensions or raw.get("include_extensions") or DEFAULT_EXTENSIONS
    if not isinstance(raw_extensions, list) or not all(isinstance(e, str) for e in raw_extensions):
        raise ValueError("baseline.include_extensions must be a list of strings")

    raw_excludes = raw.get("exclude_globs", [])
    if not isinstance(raw_excludes, list) or not all(isinstance(g, str) for g in raw_excludes):
        raise ValueError("baseline.exclude_globs must be a list of strings")

    raw_allowances = raw.get("allowances", {})
    if not isinstance(raw_allowances, dict):
        raise ValueError("baseline.allowances must be a mapping of path -> int")
    allowances: dict[str, int] = {}
    for path, limit in raw_allowances.items():
        if not isinstance(path, str) or not isinstance(limit, int) or limit <= 0:
            raise ValueError(
                f"baseline.allowances entry {path!r} -> {limit!r} is invalid"
            )
        allowances[path] = limit

    merged_excludes = tuple(dict.fromkeys([*DEFAULT_EXCLUDES, *raw_excludes]))
    return BaselineConfig(
        max_lines=max_lines,
        include_extensions=frozenset(raw_extensions),
        exclude_globs=merged_excludes,
        allowances=allowances,
    )


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    baseline_path = Path(args.baseline)
    if not baseline_path.is_absolute():
        baseline_path = (root / baseline_path).resolve()

    config = load_baseline(baseline_path, args.max_lines, args.extensions)

    violations: list[str] = []
    notices: list[str] = []
    oversized_files: list[tuple[str, int]] = []
    observed_paths: set[str] = set()

    for path in iter_source_files(root, config.include_extensions, config.exclude_globs):
        rel = normalize_path(path, root)
        observed_paths.add(rel)
        line_count = count_lines(path)

        allowed_limit = config.allowances.get(rel)
        if line_count > config.max_lines:
            oversized_files.append((rel, line_count))

        if line_count <= config.max_lines:
            if allowed_limit is not None:
                # File is now inside the hard limit — baseline entry is stale.
                notices.append(
                    f"baseline entry no longer needed: {rel} is {line_count} "
                    f"lines (<= {config.max_lines}); remove from allowances."
                )
            continue

        if allowed_limit is None:
            violations.append(
                f"new oversized file: {rel} has {line_count} lines "
                f"(limit {config.max_lines})"
            )
            continue

        if line_count > allowed_limit:
            violations.append(
                f"oversized file grew: {rel} has {line_count} lines "
                f"(baseline {allowed_limit}, limit {config.max_lines})"
            )
        elif line_count + _SHRINK_NOTICE_SLACK <= allowed_limit:
            notices.append(
                f"shrink opportunity: {rel} is {line_count} lines but baseline "
                f"allows {allowed_limit}; tighten to {line_count}."
            )

    for rel, limit in config.allowances.items():
        if rel not in observed_paths:
            notices.append(
                f"stale baseline entry: {rel} (allowance {limit}) "
                "no longer exists on disk; remove from allowances."
            )

    if violations:
        print("file-length QA failed:")
        for violation in violations:
            print(f"  - {violation}")
        print("\nCurrent oversized files:")
        for rel, line_count in sorted(oversized_files, key=lambda item: (-item[1], item[0])):
            suffix = ""
            allowed = config.allowances.get(rel)
            if allowed is not None:
                suffix = f" (baseline {allowed})"
            print(f"  - {rel}: {line_count} lines{suffix}")
        if notices:
            print("\nNotices:")
            for notice in notices:
                print(f"  - {notice}")
        return 1

    if notices:
        print("file-length QA notices:")
        for notice in notices:
            print(f"  - {notice}")
    print(
        f"file-length QA passed: no new files exceed {config.max_lines} lines "
        "and no oversized baseline file grew."
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ValueError as exc:
        print(f"file-length QA error: {exc}", file=sys.stderr)
        sys.exit(2)
