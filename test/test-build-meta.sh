#!/usr/bin/env bash
# Tests for build-metadata helpers (lib/common.sh).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
source "$ROOT_DIR/lib/common.sh"

assert() {
  local name="$1" condition="$2" detail="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -n "Testing $name... "
  if eval "$condition"; then
    echo -e "${GREEN}PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAILED${NC}"; [ -n "$detail" ] && echo "  $detail"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# --- normalize_git_repository ---
assert "https keeps host/org/repo" \
  '[ "$(normalize_git_repository https://github.com/acme/my-api.git)" = "https://github.com/acme/my-api" ]'
assert "scp form to https" \
  '[ "$(normalize_git_repository git@github.com:acme/my-api.git)" = "https://github.com/acme/my-api" ]'
assert "strips credentials" \
  '[ "$(normalize_git_repository https://x-token:secret@github.com/acme/my-api)" = "https://github.com/acme/my-api" ]'
assert "empty stays empty" \
  '[ -z "$(normalize_git_repository "")" ]'

# --- resolve_meta_field precedence ---
assert "envelope wins over env+git" \
  '[ "$(BUILD_X='\''{"commit":"AAA"}'\''; resolve_meta_field commit "{\"commit\":\"AAA\"}" MIGET_GIT_COMMIT gitval)" = "AAA" ]'
assert "env used when envelope empty" \
  '[ "$(MIGET_GIT_COMMIT=BBB resolve_meta_field commit "{}" MIGET_GIT_COMMIT gitval)" = "BBB" ]'
assert "git fallback when both empty" \
  '[ "$(resolve_meta_field commit "{}" MIGET_GIT_COMMIT gitval)" = "gitval" ]'

# --- gather_build_meta from BUILD_META envelope (no git needed) ---
META_OUT="$(BUILD_META='{"commit":"9f3c1a7b8e2d","branch":"main","repository":"https://github.com/acme/my-api"}' \
  gather_build_meta /nonexistent 2026-06-17T20:00:00Z 0.0.264 ruby)"
assert "gather: commit from envelope" \
  '[ "$(printf "%s" "$META_OUT" | jq -r .commit)" = "9f3c1a7b8e2d" ]'
assert "gather: commit_short derived" \
  '[ "$(printf "%s" "$META_OUT" | jq -r .commit_short)" = "9f3c1a7" ]'
assert "gather: built_at + builder_version + language set" \
  '[ "$(printf "%s" "$META_OUT" | jq -r "[.built_at,.builder_version,.language]|join(\",\")")" = "2026-06-17T20:00:00Z,0.0.264,ruby" ]'
assert "gather: empty description omitted" \
  '[ "$(printf "%s" "$META_OUT" | jq -r "has(\"description\")")" = "false" ]'

# --- gather_build_meta with no envelope and no git: only builder fields ---
BARE_OUT="$(gather_build_meta /nonexistent 2026-06-17T20:00:00Z 0.0.264 nodejs)"
assert "gather: bare omits commit" \
  '[ "$(printf "%s" "$BARE_OUT" | jq -r "has(\"commit\")")" = "false" ]'
assert "gather: bare keeps language" \
  '[ "$(printf "%s" "$BARE_OUT" | jq -r .language)" = "nodejs" ]'

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
