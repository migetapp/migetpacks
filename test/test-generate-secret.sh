#!/usr/bin/env bash
# Test for generate_secret() in bin/build
# Regression test: when openssl is unavailable, the fallback must produce
# a single-line hex string (no embedded newlines) so it can be safely
# interpolated into a generated Dockerfile ENV directive.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Extract the generate_secret function definition from bin/build and
# evaluate it in this shell so we exercise the real implementation.
GENERATE_SECRET_SRC=$(sed -n '/^generate_secret()/,/^}/p' "$ROOT_DIR/bin/build")
if [ -z "$GENERATE_SECRET_SRC" ]; then
  echo -e "${RED}FAILED${NC}: could not extract generate_secret() from bin/build"
  exit 1
fi
eval "$GENERATE_SECRET_SRC"

assert() {
  local test_name="$1"
  local condition="$2"
  local detail="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -n "Testing $test_name... "
  if eval "$condition"; then
    echo -e "${GREEN}PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAILED${NC}"
    [ -n "$detail" ] && echo "  $detail"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# Force the fallback path by shadowing openssl with a failing function.
# `command -v openssl` will still see the system openssl, but the function
# definition takes precedence when the name is invoked as a command.
openssl() { return 127; }

result=$(generate_secret)

# Property 1: no embedded newlines (this is the bug — xxd -p wraps at 60 cols)
assert "fallback output contains no embedded newline" \
  '[ "$(printf "%s" "$result" | wc -l | tr -d " ")" = "0" ]' \
  "got multi-line output:
$result"

# Property 2: exactly 64 lowercase hex chars (32 bytes of randomness)
assert "fallback output is 64 lowercase hex chars" \
  '[[ "$result" =~ ^[0-9a-f]{64}$ ]]' \
  "got: '$result' (length ${#result})"

echo
echo "==========================="
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
  exit 1
fi
echo "All tests passed ✓"
