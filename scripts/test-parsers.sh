#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

make build >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/.claude/projects/-tmp-claude-fixture"
CACHE_DIR="$TMP_DIR/cache"
mkdir -p "$PROJECT_DIR" "$CACHE_DIR/claude-code"
cp tests/fixtures/claude-code-session.jsonl "$PROJECT_DIR/session.jsonl"

cat > "$CACHE_DIR/claude-code/statusline-snapshot.json" <<'JSON'
{
  "schemaVersion": 1,
  "capturedAt": "2026-07-07T07:00:00.000Z",
  "rateLimits": {
    "fiveHour": {
      "usedPercentage": 25,
      "resetsAt": "2026-07-07T10:00:00.000Z"
    },
    "sevenDay": {
      "usedPercentage": 40,
      "resetsAt": "2026-07-14T07:00:00.000Z"
    }
  }
}
JSON

OUTPUT="$TMP_DIR/out.json"
CODEXU_HOME_OVERRIDE="$TMP_DIR" \
CODEXU_CACHE_OVERRIDE="$CACHE_DIR" \
CODEXU_RUNTIME_FILTER="claude-code" \
  build/codexU.app/Contents/MacOS/codexU --dump-json > "$OUTPUT"

grep -q '"schemaVersion" : 2' "$OUTPUT"
grep -q '"id" : "claude-code"' "$OUTPUT"
grep -q '"name" : "Read"' "$OUTPUT"
grep -q '"remainingPercent" : 75' "$OUTPUT"
grep -q '"visibleTotalTokens" : 1900' "$OUTPUT"

echo "parser fixture checks passed"
