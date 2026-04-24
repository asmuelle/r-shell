#!/usr/bin/env bash
# Mutation-testing ratchet.
#
# Compares today's survivor count for the booster + math + model::mod
# scope against `scripts/qa/mutants_baseline.txt`. Fails the gate when
# the count grows — i.e. when a new code path lands without a test that
# would catch it being mutated. Shrinks (the count drops below the
# baseline) succeed and emit a reminder to refresh the baseline.
#
# Usage:
#   scripts/qa/mutants_ratchet.sh
#
# Run after `make mutants` has populated `mutants.out/missed.txt`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

BASELINE="scripts/qa/mutants_baseline.txt"
CURRENT="mutants.out/missed.txt"

if [ ! -f "$CURRENT" ]; then
    printf '[mutants-ratchet] %s missing — run `make mutants` first.\n' "$CURRENT" >&2
    exit 2
fi
if [ ! -f "$BASELINE" ]; then
    printf '[mutants-ratchet] %s missing — first run? Copy current survivors:\n' "$BASELINE" >&2
    printf '    cp mutants.out/missed.txt %s\n' "$BASELINE" >&2
    exit 2
fi

baseline_n=$(grep -c . "$BASELINE" || true)
current_n=$(grep -c . "$CURRENT" || true)

printf '[mutants-ratchet] baseline=%d current=%d\n' "$baseline_n" "$current_n"

if [ "$current_n" -gt "$baseline_n" ]; then
    printf '[mutants-ratchet] FAIL: %d new survivor(s).\n' "$((current_n - baseline_n))" >&2
    printf '[mutants-ratchet] New survivors not in baseline:\n' >&2
    diff <(sort "$BASELINE") <(sort "$CURRENT") | grep '^>' | sed 's/^> /  /' >&2
    exit 1
fi

if [ "$current_n" -lt "$baseline_n" ]; then
    printf '[mutants-ratchet] OK: shrunk by %d. Tighten the baseline:\n' \
        "$((baseline_n - current_n))"
    printf '    cp %s %s\n' "$CURRENT" "$BASELINE"
fi

exit 0
