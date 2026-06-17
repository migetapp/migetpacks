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

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
