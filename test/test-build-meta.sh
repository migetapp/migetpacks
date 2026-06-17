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
assert "envelope wins over populated env" \
  '[ "$(MIGET_GIT_COMMIT=ENVVAL resolve_meta_field commit "{\"commit\":\"AAA\"}" MIGET_GIT_COMMIT gitval)" = "AAA" ]'
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

# --- build_meta_label_flags ---
build_meta_label_flags '{"commit":"AAA","repository":"https://github.com/acme/my-api","built_at":"T","builder_version":"0.0.264","branch":"main"}'
LABELS_JOINED="$(printf '%s\n' "${BUILD_LABEL_FLAGS[@]}")"
assert "label: revision present" \
  'printf "%s" "$LABELS_JOINED" | grep -q "org.opencontainers.image.revision=AAA"'
assert "label: source present" \
  'printf "%s" "$LABELS_JOINED" | grep -q "org.opencontainers.image.source=https://github.com/acme/my-api"'
assert "label: branch present" \
  'printf "%s" "$LABELS_JOINED" | grep -q "com.miget.git.branch=main"'
build_meta_label_flags '{"language":"ruby"}'
assert "label: empty meta yields no revision" \
  '! printf "%s\n" "${BUILD_LABEL_FLAGS[@]}" | grep -q "image.revision"'

# --- build_meta_arg_flags ---
build_meta_arg_flags '{"commit":"AAA","commit_short":"AAA1234","branch":"main","language":"ruby"}'
ARGS_JOINED="$(printf '%s\n' "${BUILD_META_ARG_FLAGS[@]}")"
assert "arg: MIGET_GIT_COMMIT present" \
  'printf "%s" "$ARGS_JOINED" | grep -q "MIGET_GIT_COMMIT=AAA"'
assert "arg: MIGET_LANGUAGE present" \
  'printf "%s" "$ARGS_JOINED" | grep -q "MIGET_LANGUAGE=ruby"'
build_meta_arg_flags '{"language":"go"}'
assert "arg: missing commit skipped" \
  '! printf "%s\n" "${BUILD_META_ARG_FLAGS[@]}" | grep -q "MIGET_GIT_COMMIT="'

# --- stage_build_json ---
TMPCTX="$(mktemp -d)"; TMPDF="$(mktemp)"
stage_build_json "$TMPDF" "$TMPCTX" '{"commit":"AAA","language":"ruby"}'
assert "stage: context file written" \
  '[ "$(jq -r .commit "$TMPCTX/.miget-build.json")" = "AAA" ]'
assert "stage: COPY line appended" \
  'grep -q "COPY --chmod=0644 .miget-build.json /.miget/build.json" "$TMPDF"'
TMPDF2="$(mktemp)"
stage_build_json "$TMPDF2" "$TMPCTX" '{}'
assert "stage: empty meta is no-op" \
  '[ ! -s "$TMPDF2" ]'
rm -rf "$TMPCTX" "$TMPDF" "$TMPDF2"

# --- SOURCE_VERSION as env-tier alias for commit ---
# SOURCE_VERSION is an env-tier alias for commit, ABOVE .git autodetection
SV_OUT="$(SOURCE_VERSION=ccccccc1234 gather_build_meta /nonexistent 2026-06-17T20:00:00Z 0.0.264 ruby)"
assert "gather: SOURCE_VERSION sets commit" \
  '[ "$(printf "%s" "$SV_OUT" | jq -r .commit)" = "ccccccc1234" ]'
assert "gather: SOURCE_VERSION drives commit_short" \
  '[ "$(printf "%s" "$SV_OUT" | jq -r .commit_short)" = "ccccccc" ]'
# MIGET_GIT_COMMIT outranks SOURCE_VERSION
MG_OUT="$(MIGET_GIT_COMMIT=mmmmmmm SOURCE_VERSION=ccccccc gather_build_meta /nonexistent 2026-06-17T20:00:00Z 0.0.264 ruby)"
assert "gather: MIGET_GIT_COMMIT outranks SOURCE_VERSION" \
  '[ "$(printf "%s" "$MG_OUT" | jq -r .commit)" = "mmmmmmm" ]'

# --- stage_build_json re-includes via .dockerignore ---
TMPCTX2="$(mktemp -d)"; TMPDF3="$(mktemp)"; printf '*\n' > "$TMPCTX2/.dockerignore"
stage_build_json "$TMPDF3" "$TMPCTX2" '{"commit":"AAA"}'
assert "stage: appends dockerignore negation" \
  'grep -qxF "!.miget-build.json" "$TMPCTX2/.dockerignore"'
rm -rf "$TMPCTX2" "$TMPDF3"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
