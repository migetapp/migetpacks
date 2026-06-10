#!/usr/bin/env bash
# Tests for build-var name validation.
#
# Contract (see docs/configuration/environment-variables.mdx): only keys that
# are POSIX environment-variable identifiers (IEEE Std 1003.1 §8.1 -> the same
# rule Docker enforces on `ARG`/`ENV`) may be projected as Docker build args /
# `ARG` lines. Runtime-only settings with dotted names (e.g. the Elasticsearch
# `discovery.seed_hosts` style) are valid container env vars but are NOT valid
# build args, so they must be skipped from the build-arg projection -- otherwise
# they emit `ARG discovery.seed_hosts`, which is an invalid Dockerfile
# instruction and fails the build.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Load the real helper from the shared lib.
source "$ROOT_DIR/lib/common.sh"

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

# --- predicate: POSIX env-var / Docker ARG identifier rule ---
assert "accepts UPPER_SNAKE"        'is_valid_build_arg_name NODE_ENV'
assert "accepts leading underscore" 'is_valid_build_arg_name _PRIVATE'
assert "accepts lower + digits"     'is_valid_build_arg_name port5000'
assert "rejects dotted key"         '! is_valid_build_arg_name discovery.seed_hosts'
assert "rejects hyphen"             '! is_valid_build_arg_name my-var'
assert "rejects leading digit"      '! is_valid_build_arg_name 9lives'
assert "rejects empty"              '! is_valid_build_arg_name ""'

# --- regression: the guard's deps come from lib/common.sh, so the call site
# must run AFTER the source line. When it ran before (call ~line 216, source
# ~line 373), is_valid_build_arg_name/warning were undefined at call time:
# every key returned 127 from the not-found check and ALL build args were
# silently dropped ("is_valid_build_arg_name: command not found" in builds). ---
call_line=$(grep -n '^build_arg_flags_from_build_vars$' "$ROOT_DIR/bin/build" | head -1 | cut -d: -f1)
source_line=$(grep -n 'source .*lib/common\.sh' "$ROOT_DIR/bin/build" | head -1 | cut -d: -f1)
assert "build-vars call runs after lib/common.sh is sourced" \
  '[ -n "$call_line" ] && [ -n "$source_line" ] && [ "$call_line" -gt "$source_line" ]' \
  "call at line ${call_line:-?}, common.sh sourced at line ${source_line:-?}"

# --- integration: build_arg_flags_from_build_vars() skips invalid keys ---
# Exercise the real implementation extracted from bin/build (same technique as
# test-generate-secret.sh) so the guard is proven at the actual call site.
if command -v jq >/dev/null 2>&1; then
  FN_SRC=$(sed -n '/^build_arg_flags_from_build_vars()/,/^}/p' "$ROOT_DIR/bin/build")
  if [ -z "$FN_SRC" ]; then
    echo -e "${RED}FAILED${NC}: could not extract build_arg_flags_from_build_vars() from bin/build"
    exit 1
  fi
  eval "$FN_SRC"

  BUILD_VARS='{"BUILD_VAR_NODE_ENV":"production","BUILD_VAR_discovery.seed_hosts":"a,b,c"}'
  build_arg_flags_from_build_vars
  flags="${BUILD_ARGS[*]}"

  assert "keeps valid build arg"  '[[ "$flags" == *"NODE_ENV=production"* ]]' "flags=$flags"
  assert "drops dotted build arg" '[[ "$flags" != *"discovery.seed_hosts"* ]]' "flags=$flags"
else
  echo "  (skipping jq integration tests: jq not found)"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
