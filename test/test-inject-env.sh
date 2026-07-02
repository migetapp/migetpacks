#!/usr/bin/env bash
# Tests for custom env var injection into the generated Dockerfile.
#
# Contract: inject_custom_env_vars() must write each unknown env var as a
# single `ENV name="value"` line whose value survives Docker's double-quote
# parsing byte-for-byte. Inside double quotes Docker unescapes \" \\ and \$,
# so the writer has to escape backslashes, quotes and dollars -- and nothing
# may re-interpret those escapes on the way to the file. The old code flushed
# the buffer with `echo -e`, which collapsed `\\\"` (an escaped quote from a
# JSON payload such as BUILD_META) into `\\"`: Docker then read an escaped
# backslash plus a closing quote, the string ended early, and the build died
# with `Syntax error - can't find = in ...`.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

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

# Extract the real implementation from bin/build (same technique as
# test-build-vars.sh) so the writer is proven, not a copy of it.
KNOWN_SRC=$(sed -n '/^KNOWN_BUILDER_VARS=(/,/^)/p' "$ROOT_DIR/bin/build")
FN_SRC=$(sed -n '/^inject_custom_env_vars()/,/^}/p' "$ROOT_DIR/bin/build")
if [ -z "$KNOWN_SRC" ] || [ -z "$FN_SRC" ]; then
  echo -e "${RED}FAILED${NC}: could not extract inject_custom_env_vars() from bin/build"
  exit 1
fi
eval "$KNOWN_SRC"
eval "$FN_SRC"

DOCKERFILE=$(mktemp)
trap 'rm -f "$DOCKERFILE"' EXIT

# The shape that broke real builds: a compact-JSON BUILD_META whose
# description holds an escaped quote, \n sequences and a dollar sign.
export CUSTOM_TEST_META='{"commit": "0123abc", "description": "a \"quoted\" word — note\n\n$12"}'
export CUSTOM_TEST_PLAIN='back \ slash "quote" $dollar'
inject_custom_env_vars "$DOCKERFILE"

meta_line=$(grep '^ENV CUSTOM_TEST_META=' "$DOCKERFILE" || true)
plain_line=$(grep '^ENV CUSTOM_TEST_PLAIN=' "$DOCKERFILE" || true)

assert "writes exactly one line per var" \
  '[ "$(grep -c "^ENV CUSTOM_TEST_META=" "$DOCKERFILE")" = "1" ]' \
  "$(grep -n 'CUSTOM_TEST_META' "$DOCKERFILE")"

# Every value character Docker unescapes must arrive escaped: \ -> \\,
# " -> \", $ -> \$. A JSON \" therefore has to land as \\\" (four chars).
assert "JSON escaped quote lands as backslash-backslash-backslash-quote" \
  '[[ "$meta_line" == *"quoted\\\\\\\""* ]]' \
  "line=$meta_line"
assert "JSON escaped quote does not collapse to backslash-backslash-quote" \
  '[[ "$meta_line" != *"quoted\\\\\" "* ]]' \
  "line=$meta_line"
assert "newline escape stays literal backslash-backslash-n" \
  '[[ "$meta_line" == *"note\\\\n\\\\n"* ]]' \
  "line=$meta_line"
assert "dollar is escaped" \
  '[[ "$meta_line" == *"\\\$12"* ]]' \
  "line=$meta_line"
assert "plain value escapes fully" \
  '[ "$plain_line" = "ENV CUSTOM_TEST_PLAIN=\"back \\\\ slash \\\"quote\\\" \\\$dollar\"" ]' \
  "line=$plain_line"

# Round-trip: undo Docker's double-quote unescaping (\\ \" \$ -> \ " $) and
# compare against the original value.
meta_value="${meta_line#ENV CUSTOM_TEST_META=\"}"
meta_value="${meta_value%\"}"
meta_value="${meta_value//\\\\/$'\x01'}"
meta_value="${meta_value//\\\"/\"}"
meta_value="${meta_value//\\\$/\$}"
meta_value="${meta_value//$'\x01'/\\}"
assert "value survives Docker unquoting byte-for-byte" \
  '[ "$meta_value" = "$CUSTOM_TEST_META" ]' \
  "got=$meta_value"

# BUILD_META is builder input (consumed into labels, MIGET_* args and
# /.miget/build.json) -- the raw envelope must not become image ENV.
export BUILD_META='{"commit":"9f3c1a7"}'
: > "$DOCKERFILE"
inject_custom_env_vars "$DOCKERFILE"
assert "BUILD_META is not passed through" \
  '! grep -q "^ENV BUILD_META=" "$DOCKERFILE"' \
  "$(grep 'BUILD_META' "$DOCKERFILE")"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
