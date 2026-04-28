#!/usr/bin/env python3
"""Check simple clean-architecture boundary rules.

Two rule types:
- `forbid_usage`: pattern must not appear inside any file under the listed
  `paths`. Optional `except_paths` overrides allow specific files within
  those paths.
- `only_allowed_usage`: pattern may only appear inside files under the
  listed `allowed_paths`.

Matching is substring-based but comments (Rust/JS/TS style `//` and
`/* */`) are stripped first so that doc comments mentioning a forbidden
name do not trip the rule.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    print("Python 3.11+ is required for tomllib.", file=sys.stderr)
    sys.exit(2)


DEFAULT_EXTENSIONS = [".rs", ".js", ".ts", ".tsx", ".jsx"]
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

_LINE_COMMENT = re.compile(r"//[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)


@dataclass(frozen=True)
class RuleViolation:
    rule_name: str
    relative_path: str
    pattern: str
    message: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Repository root to scan.")
    parser.add_argument(
        "--rules",
        required=True,
        help="TOML file defining architecture usage rules.",
    )
    return parser.parse_args()


def normalize_path(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def load_rules(path: Path) -> dict[str, Any]:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def matches_any_glob(relative_path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch(relative_path, pattern) for pattern in patterns)


def path_matches_prefix(relative_path: str, candidate: str) -> bool:
    candidate = candidate.strip().strip("/")
    return relative_path == candidate or relative_path.startswith(f"{candidate}/")


def path_matches_any_prefix(relative_path: str, candidates: list[str]) -> bool:
    return any(path_matches_prefix(relative_path, candidate) for candidate in candidates)


def _prune_prefixes(exclude_globs: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(p[:-3] for p in exclude_globs if p.endswith("/**"))


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
            if Path(name).suffix not in extensions:
                continue
            rel = f"{rel_dir}/{name}" if rel_dir else name
            if matches_any_glob(rel, exclude_globs):
                continue
            yield dirpath / name


def _strip_comments(text: str) -> str:
    # Block comments first so that `// /* */` inside a line comment is left alone.
    text = _BLOCK_COMMENT.sub(" ", text)
    text = _LINE_COMMENT.sub("", text)
    return text


def file_contains_pattern(path: Path, pattern: str, cache: dict[Path, str]) -> bool:
    stripped = cache.get(path)
    if stripped is None:
        raw = path.read_text(encoding="utf-8", errors="ignore")
        stripped = _strip_comments(raw)
        cache[path] = stripped
    return pattern in stripped


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    rules_path = Path(args.rules)
    if not rules_path.is_absolute():
        rules_path = (root / rules_path).resolve()

    config = load_rules(rules_path)
    extensions = frozenset(config.get("include_extensions", DEFAULT_EXTENSIONS))
    exclude_globs = tuple(
        dict.fromkeys([*DEFAULT_EXCLUDES, *config.get("exclude_globs", [])])
    )
    files = list(iter_source_files(root, extensions, exclude_globs))

    violations: list[RuleViolation] = []
    strip_cache: dict[Path, str] = {}

    for rule in config.get("forbid_usage", []):
        name = str(rule["name"])
        message = str(rule.get("message", "Forbidden dependency usage."))
        paths = [str(item) for item in rule["paths"]]
        except_paths = [str(item) for item in rule.get("except_paths", [])]
        patterns = [str(item) for item in rule["patterns"]]
        for path in files:
            rel = normalize_path(path, root)
            if not path_matches_any_prefix(rel, paths):
                continue
            if except_paths and path_matches_any_prefix(rel, except_paths):
                continue
            for pattern in patterns:
                if file_contains_pattern(path, pattern, strip_cache):
                    violations.append(RuleViolation(name, rel, pattern, message))

    for rule in config.get("only_allowed_usage", []):
        name = str(rule["name"])
        message = str(rule.get("message", "Usage is only allowed in specific boundary files."))
        allowed_paths = [str(item) for item in rule["allowed_paths"]]
        patterns = [str(item) for item in rule["patterns"]]
        for path in files:
            rel = normalize_path(path, root)
            if path_matches_any_prefix(rel, allowed_paths):
                continue
            for pattern in patterns:
                if file_contains_pattern(path, pattern, strip_cache):
                    violations.append(RuleViolation(name, rel, pattern, message))

    if violations:
        print("architecture QA failed:")
        for violation in violations:
            print(
                f"  - [{violation.rule_name}] {violation.relative_path} "
                f"matched `{violation.pattern}`. {violation.message}"
            )
        return 1

    forbid_count = len(config.get("forbid_usage", []))
    allow_count = len(config.get("only_allowed_usage", []))
    print(
        f"architecture QA passed: {forbid_count} forbid rule(s), "
        f"{allow_count} allow rule(s), {len(files)} file(s) scanned."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
