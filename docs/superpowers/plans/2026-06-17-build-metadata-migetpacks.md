# Build Metadata — migetpacks Implementation Plan (1 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make migetpacks emit build metadata (git provenance + builder facts) on every build as a `result.json` `build` block, OCI image labels, an in-image `/.miget/build.json`, and `MIGET_*` build-args, sourced by model-C precedence (`$BUILD_META` envelope, then `MIGET_GIT_*`/`SOURCE_VERSION` env, then `.git`).

**Architecture:** Pure, unit-testable helpers in `lib/common.sh` build a single compact JSON blob (`BUILD_META_JSON`). `bin/build` computes it once (memoized) and projects it onto four surfaces. No runtime ENV is baked — the platform injects that downstream (separate plans).

**Tech Stack:** Bash, `jq`, Docker BuildKit (`docker buildx`), the existing `test/*.sh` assert harness.

## Global Constraints

- Helpers live in `lib/common.sh` and are pure (no global reads) so `test/*.sh` can source and call them, mirroring `is_valid_build_arg_name`.
- Empty/unknown fields are **omitted** from JSON and skipped as labels/build-args — never emitted as empty strings.
- Precedence per field, highest first: `$BUILD_META` envelope → direct `MIGET_GIT_*`/`SOURCE_VERSION` env → `.git` autodetection. Every git call is guarded; shallow clone / detached HEAD / no-`.git` degrade to omitted, never error.
- `repository` is normalized to a full HTTPS URL (`https://host/org/repo`): strip trailing `.git`, strip embedded credentials, convert `git@host:org/repo` form.
- No runtime ENV baked by migetpacks. No rewriting user-authored Dockerfiles (Dockerfile/Compose get labels + `MIGET_*` build-args only).
- OCI labels: `org.opencontainers.image.revision|source|created` + `com.miget.git.branch`, `com.miget.git.description`, `com.miget.builder.version`. No `image.version` (release is deploy context, unknown to the builder).
- Docs follow `docs/CLAUDE.md` (Mintlify): frontmatter, second-person voice, relative links, language tags. No em-dashes, no AI slop.

---

## File Structure

- `lib/common.sh` — add pure helpers: `normalize_git_repository`, `resolve_meta_field`, `gather_build_meta`, `build_meta_label_flags`, `build_meta_arg_flags`, `stage_build_json`.
- `bin/build` — add `ensure_build_meta_json` wrapper + global `BUILD_META_JSON`; wire labels/build-args/build.json into the three buildx paths; add `build` block in `write_result_file`.
- `Dockerfile`, `Dockerfile.alpine` — bake `MIGETPACKS_VERSION`.
- `.github/workflows/release.yml` — pass `--build-arg MIGETPACKS_VERSION`.
- `test/test-build-meta.sh` — new unit test file (sources `lib/common.sh`).
- `Makefile` — register `test-build-meta`.
- `docs/reference/result-json.mdx`, `docs/configuration/build-metadata.mdx`, `docs/configuration/environment-variables.mdx`, `docs/docs.json` — docs.

---

### Task 1: `normalize_git_repository` helper

**Files:**
- Modify: `lib/common.sh` (append helper after `is_valid_build_arg_name`, line 44)
- Test: `test/test-build-meta.sh` (create)

**Interfaces:**
- Produces: `normalize_git_repository <url>` → echoes canonical `https://host/org/repo` (empty in → empty out).

- [ ] **Step 1: Write the failing test**

Create `test/test-build-meta.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x test/test-build-meta.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/test-build-meta.sh`
Expected: FAIL — `normalize_git_repository: command not found` (helper not defined).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/common.sh`:

```bash
# Normalize a git repository reference to a canonical https URL:
#   - convert scp-style git@host:org/repo to https://host/org/repo
#   - strip a leading ssh:// or git@
#   - strip embedded credentials (https://user:pass@host/... -> https://host/...)
#   - ensure an https scheme
#   - strip a trailing ".git"
# Empty input yields empty output.
normalize_git_repository() {
  local url="$1"
  [ -z "$url" ] && return 0
  if [[ "$url" =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9._-]+):(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  url="${url#ssh://}"
  url="${url#git@}"
  url="$(printf '%s' "$url" | sed -E 's#^(https?://)[^@/]+@#\1#')"
  [[ "$url" =~ ^https?:// ]] || url="https://$url"
  url="${url%.git}"
  printf '%s' "$url"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test/test-build-meta.sh`
Expected: PASS — 4/4 passed.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh test/test-build-meta.sh
git commit -m "feat(build-meta): add normalize_git_repository helper"
```

---

### Task 2: `resolve_meta_field` + `gather_build_meta`

**Files:**
- Modify: `lib/common.sh` (append after `normalize_git_repository`)
- Test: `test/test-build-meta.sh` (extend)

**Interfaces:**
- Consumes: `normalize_git_repository` (Task 1).
- Produces:
  - `resolve_meta_field <key> <envelope_json> <env_var_name> <git_value>` → echoes first non-empty by precedence.
  - `gather_build_meta <src_dir> <built_at> <builder_version> <language>` → echoes a compact JSON object (empty fields omitted). Reads `$BUILD_META`, `MIGET_GIT_*`, `SOURCE_VERSION`.

- [ ] **Step 1: Write the failing test**

Insert before the final `echo ""` results block in `test/test-build-meta.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/test-build-meta.sh`
Expected: FAIL — `resolve_meta_field: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/common.sh`:

```bash
# Resolve one build-meta field by precedence:
#   1. the BUILD_META JSON envelope ($2), keyed by $1
#   2. a direct environment variable named $3
#   3. a git fallback value ($4)
# Echoes the first non-empty source (or empty).
resolve_meta_field() {
  local key="$1" envelope="$2" env_name="$3" git_value="$4" v=""
  if [ -n "$envelope" ] && [ "$envelope" != "{}" ]; then
    v=$(printf '%s' "$envelope" | jq -r --arg k "$key" '.[$k] // empty')
  fi
  if [ -z "$v" ] && [ -n "$env_name" ]; then
    v="${!env_name}"
  fi
  [ -z "$v" ] && v="$git_value"
  printf '%s' "$v"
}

# Gather build metadata into a compact JSON object on stdout. Precedence per
# field: $BUILD_META envelope, then MIGET_GIT_*/SOURCE_VERSION env, then git in
# $1. Builder-known fields are passed in ($2 built_at, $3 builder_version,
# $4 language). Empty fields are omitted. All git calls are guarded.
gather_build_meta() {
  local src_dir="$1" built_at="$2" builder_version="$3" language="$4"
  local envelope="${BUILD_META:-}"
  local g_commit="" g_branch="" g_desc="" g_committed="" g_repo=""

  if [ -d "$src_dir/.git" ] && command -v git >/dev/null 2>&1; then
    g_commit=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || true)
    g_branch=$(git -C "$src_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ "$g_branch" = "HEAD" ] && g_branch=""
    g_desc=$(git -C "$src_dir" log -1 --pretty=%s 2>/dev/null || true)
    g_committed=$(git -C "$src_dir" log -1 --date=format:'%Y-%m-%dT%H:%M:%SZ' --pretty=%cd 2>/dev/null || true)
    g_repo=$(normalize_git_repository "$(git -C "$src_dir" remote get-url origin 2>/dev/null || true)")
  fi

  local commit branch desc committed repo
  commit=$(resolve_meta_field commit "$envelope" MIGET_GIT_COMMIT "$g_commit")
  [ -z "$commit" ] && commit="${SOURCE_VERSION:-}"
  branch=$(resolve_meta_field branch "$envelope" MIGET_GIT_BRANCH "$g_branch")
  desc=$(resolve_meta_field description "$envelope" MIGET_GIT_DESCRIPTION "$g_desc")
  committed=$(resolve_meta_field committed_at "$envelope" MIGET_GIT_COMMITTED_AT "$g_committed")
  repo=$(resolve_meta_field repository "$envelope" MIGET_GIT_REPOSITORY "$g_repo")

  local commit_short=""
  [ -n "$commit" ] && commit_short="${commit:0:7}"

  jq -nc \
    --arg commit "$commit" \
    --arg commit_short "$commit_short" \
    --arg branch "$branch" \
    --arg description "$desc" \
    --arg committed_at "$committed" \
    --arg built_at "$built_at" \
    --arg builder_version "$builder_version" \
    --arg language "$language" \
    --arg repository "$repo" \
    '{commit:$commit, commit_short:$commit_short, branch:$branch,
      description:$description, committed_at:$committed_at, built_at:$built_at,
      builder_version:$builder_version, language:$language, repository:$repository}
     | with_entries(select(.value != ""))'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./test/test-build-meta.sh`
Expected: PASS — all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh test/test-build-meta.sh
git commit -m "feat(build-meta): add resolve_meta_field + gather_build_meta"
```

---

### Task 3: Register `test-build-meta` in Makefile + `result.json` `build` block

**Files:**
- Modify: `Makefile:1` (`.PHONY`), test target list, and the `test:` aggregate target
- Modify: `bin/build` — add global `BUILD_META_JSON`, `ensure_build_meta_json`, and the `build` merge in `write_result_file` (`bin/build:711-734`)

**Interfaces:**
- Consumes: `gather_build_meta` (Task 2).
- Produces:
  - global `BUILD_META_JSON` (compact JSON, memoized).
  - `ensure_build_meta_json <language>` — computes `BUILD_META_JSON` once.
  - `write_result_file` output includes `"build": {...}` when non-empty.

- [ ] **Step 1: Register the test target (Makefile)**

In `Makefile`, add `test-build-meta` to the `.PHONY` line (line 1) and add this target near `test-build-vars`:

```makefile
test-build-meta:
	@echo "Running build-metadata helper tests..."
	./test/test-build-meta.sh
```

Update the aggregate target:

```makefile
test: test-detect test-generate-secret test-build-vars test-build-meta
	@echo "All tests passed ✓"
```

- [ ] **Step 2: Add the global + wrapper in `bin/build`**

After the `RESULT_FILE=...` line (`bin/build:29`), add:

```bash
BUILD_META_JSON=""  # compact JSON build-metadata blob (memoized by ensure_build_meta_json)
```

After the `KNOWN_BUILDER_VARS` array closes (around `bin/build:135`), add:

```bash
# Compute BUILD_META_JSON once. Safe to call from every build path; later calls
# are no-ops. built_at is stamped at first call (just before buildx), which is
# within seconds of completion.
ensure_build_meta_json() {
  local language="${1:-unknown}"
  if [ -z "$BUILD_META_JSON" ]; then
    BUILD_META_JSON=$(gather_build_meta "$EFFECTIVE_SOURCE_DIR" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MIGETPACKS_VERSION:-}" "$language")
  fi
}
```

- [ ] **Step 3: Add the `build` merge in `write_result_file`**

In `bin/build`, immediately after the `CUSTOM_DATA` merge block (`bin/build:731-734`) and before `echo "$result_json" > "$RESULT_FILE"`, add:

```bash
  # Add build metadata (git provenance + builder facts)
  ensure_build_meta_json "$language"
  if [ -n "$BUILD_META_JSON" ] && [ "$BUILD_META_JSON" != "{}" ]; then
    result_json=$(echo "$result_json" | jq --argjson b "$BUILD_META_JSON" '. + {build: $b}')
  fi
```

- [ ] **Step 4: Verify with a smoke build**

Run from a git checkout (any example app):

```bash
RESULT_FILE=/tmp/r.json BUILD_META='{"commit":"9f3c1a7b8e2d","branch":"main"}' \
  bash -c 'source lib/common.sh; EFFECTIVE_SOURCE_DIR=.; MIGETPACKS_VERSION=0.0.264;
    ensure_build_meta_json(){ BUILD_META_JSON=$(gather_build_meta "$EFFECTIVE_SOURCE_DIR" 2026-06-17T20:00:00Z "$MIGETPACKS_VERSION" ruby); };
    ensure_build_meta_json; echo "$BUILD_META_JSON" | jq .'
```

Expected: JSON with `commit: "9f3c1a7b8e2d"`, `commit_short: "9f3c1a7"`, `branch: "main"`, `builder_version: "0.0.264"`, `language: "ruby"`.

Then run the full unit suite:

Run: `make test`
Expected: PASS, including `test-build-meta`.

- [ ] **Step 5: Commit**

```bash
git add Makefile bin/build
git commit -m "feat(build-meta): emit build block in result.json"
```

---

### Task 4: OCI labels on all three buildx paths

**Files:**
- Modify: `lib/common.sh` (append `build_meta_label_flags`)
- Modify: `bin/build` — buildpack buildx (`bin/build:2357-2358`), Dockerfile buildx (`bin/build:991-992`), Compose buildx (`bin/build:1108-1112`)
- Test: `test/test-build-meta.sh` (extend)

**Interfaces:**
- Consumes: `BUILD_META_JSON` (Task 3).
- Produces: `build_meta_label_flags <meta_json>` — fills array `BUILD_LABEL_FLAGS` with `--label k=v` pairs (empty values skipped).

- [ ] **Step 1: Write the failing test**

Insert before the results block in `test/test-build-meta.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/test-build-meta.sh`
Expected: FAIL — `build_meta_label_flags: command not found`.

- [ ] **Step 3: Implement the helper**

Append to `lib/common.sh`:

```bash
# Fill the BUILD_LABEL_FLAGS array with OCI + miget --label pairs from a
# build-meta JSON object ($1). Labels with empty values are skipped.
build_meta_label_flags() {
  local meta="$1"
  BUILD_LABEL_FLAGS=()
  [ -z "$meta" ] && return 0
  local commit branch desc repo built builder
  commit=$(printf '%s' "$meta" | jq -r '.commit // empty')
  branch=$(printf '%s' "$meta" | jq -r '.branch // empty')
  desc=$(printf '%s' "$meta" | jq -r '.description // empty')
  repo=$(printf '%s' "$meta" | jq -r '.repository // empty')
  built=$(printf '%s' "$meta" | jq -r '.built_at // empty')
  builder=$(printf '%s' "$meta" | jq -r '.builder_version // empty')
  [ -n "$commit" ]  && BUILD_LABEL_FLAGS+=(--label "org.opencontainers.image.revision=$commit")
  [ -n "$repo" ]    && BUILD_LABEL_FLAGS+=(--label "org.opencontainers.image.source=$repo")
  [ -n "$built" ]   && BUILD_LABEL_FLAGS+=(--label "org.opencontainers.image.created=$built")
  [ -n "$branch" ]  && BUILD_LABEL_FLAGS+=(--label "com.miget.git.branch=$branch")
  [ -n "$desc" ]    && BUILD_LABEL_FLAGS+=(--label "com.miget.git.description=$desc")
  [ -n "$builder" ] && BUILD_LABEL_FLAGS+=(--label "com.miget.builder.version=$builder")
}
```

- [ ] **Step 4: Run helper test to verify it passes**

Run: `./test/test-build-meta.sh`
Expected: PASS.

- [ ] **Step 5: Wire labels into the three buildx invocations**

Buildpack path — before `build_latest_tag_flag "$OUTPUT_IMAGE"` at `bin/build:2357`, add:

```bash
ensure_build_meta_json "$LANG_NORMALIZED"
build_meta_label_flags "$BUILD_META_JSON"
```

Then add `"${BUILD_LABEL_FLAGS[@]}"` to the buildx command at `bin/build:2358`, right after `"${BUILD_ARGS[@]}"`:

```bash
docker buildx build --progress=plain --network=host --platform "$DOCKER_PLATFORM" $CACHE_FLAGS "${SSH_FLAGS[@]}" "${BUILD_ARGS[@]}" "${BUILD_LABEL_FLAGS[@]}" -f "$RUNTIME_DOCKERFILE" -t "$OUTPUT_IMAGE" $LATEST_TAG_FLAG $BUILD_OUTPUT_FLAG "$EFFECTIVE_SOURCE_DIR" 2>&1 | tee "$BUILD_OUTPUT" | filter_buildx_output
```

Dockerfile path — before `build_latest_tag_flag "$OUTPUT_IMAGE"` at `bin/build:991`, add:

```bash
ensure_build_meta_json "dockerfile"
build_meta_label_flags "$BUILD_META_JSON"
```

Add `"${BUILD_LABEL_FLAGS[@]}"` after `"${BUILD_ARGS[@]}"` in the buildx at `bin/build:992`.

Compose path — before the per-service `build_latest_tag_flag "$SERVICE_IMAGE"` at `bin/build:1108`, add (inside the loop, after `BUILD_ARGS` is set):

```bash
    ensure_build_meta_json "compose"
    build_meta_label_flags "$BUILD_META_JSON"
```

Add `"${BUILD_LABEL_FLAGS[@]}"` after `"${BUILD_ARGS[@]}"` in the buildx at `bin/build:1109`.

- [ ] **Step 6: Verify labels on a real build**

```bash
make test
# Optional integration (requires Docker): build an example, then:
# docker inspect <image> --format '{{json .Config.Labels}}' | jq .
```

Expected: unit tests PASS; `docker inspect` shows `org.opencontainers.image.revision` and `com.miget.git.branch` when built from a git checkout.

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh bin/build test/test-build-meta.sh
git commit -m "feat(build-meta): add OCI labels to all build paths"
```

---

### Task 5: `/.miget/build.json` for buildpack builds

**Files:**
- Modify: `lib/common.sh` (append `stage_build_json`)
- Modify: `bin/build` — after the runtime Dockerfile footer is written, before the buildpack buildx (`bin/build:~2356`)
- Modify: `.dockerignore` generation block (`bin/build:~786-793`) — ensure `.miget-build.json` is not ignored
- Test: `test/test-build-meta.sh` (extend)

**Interfaces:**
- Consumes: `BUILD_META_JSON` (Task 3).
- Produces: `stage_build_json <dockerfile> <context_dir> <meta_json>` — writes `<context_dir>/.miget-build.json` and appends a `COPY --chmod=0644 .miget-build.json /.miget/build.json` line; no-op on empty meta or read-only context.

- [ ] **Step 1: Write the failing test**

Insert before the results block in `test/test-build-meta.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/test-build-meta.sh`
Expected: FAIL — `stage_build_json: command not found`.

- [ ] **Step 3: Implement the helper**

Append to `lib/common.sh`:

```bash
# Stage /.miget/build.json into the image via the build context. COPY works on
# distroless (DHI) too, unlike RUN. No-op when meta is empty or the context is
# read-only (a `-v src:ro` mount); labels + result.json still carry the data.
stage_build_json() {
  local dockerfile="$1" ctx="$2" meta="$3"
  { [ -z "$meta" ] || [ "$meta" = "{}" ]; } && return 0
  if ! ( : > "$ctx/.miget-build.json" ) 2>/dev/null; then
    warning "Build context read-only; skipping /.miget/build.json (labels + result.json still set)"
    return 0
  fi
  printf '%s' "$meta" > "$ctx/.miget-build.json"
  {
    echo ""
    echo "# Build metadata (miget)"
    echo "COPY --chmod=0644 .miget-build.json /.miget/build.json"
  } >> "$dockerfile"
}
```

- [ ] **Step 4: Run helper test to verify it passes**

Run: `./test/test-build-meta.sh`
Expected: PASS.

- [ ] **Step 5: Wire into the buildpack path + protect from .dockerignore**

In `bin/build`, right after Task 4's buildpack `build_meta_label_flags "$BUILD_META_JSON"` (just before `build_latest_tag_flag` at `bin/build:2357`), add:

```bash
stage_build_json "$RUNTIME_DOCKERFILE" "$EFFECTIVE_SOURCE_DIR" "$BUILD_META_JSON"
```

In the `.dockerignore` generation block (`bin/build:~786-793`), append a negation so the staged file is not excluded. After the block writes its ignore entries, add:

```bash
echo '!.miget-build.json' >> "$EFFECTIVE_SOURCE_DIR/.dockerignore"
```

(If the build writes `.dockerignore` elsewhere or conditionally, add the negation to the same file actually used as the build-context `.dockerignore`.)

- [ ] **Step 6: Verify on a real build (optional integration)**

```bash
make test
# Optional (requires Docker):
# build an example image, then:
# docker run --rm <image> cat /.miget/build.json | jq .   # standard image
# docker inspect <image> ... # confirm COPY layer present for DHI
```

Expected: unit tests PASS; `/.miget/build.json` present and valid JSON in a buildpack image.

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh bin/build test/test-build-meta.sh
git commit -m "feat(build-meta): write /.miget/build.json for buildpack builds"
```

---

### Task 6: `MIGET_*` build-args for Dockerfile/Compose opt-in

**Files:**
- Modify: `lib/common.sh` (append `build_meta_arg_flags`)
- Modify: `bin/build` — Dockerfile buildx (`bin/build:992`), Compose buildx (`bin/build:1109`)
- Test: `test/test-build-meta.sh` (extend)

**Interfaces:**
- Consumes: `BUILD_META_JSON` (Task 3).
- Produces: `build_meta_arg_flags <meta_json>` — fills array `BUILD_META_ARG_FLAGS` with `--build-arg MIGET_*=v` (empty values skipped).

- [ ] **Step 1: Write the failing test**

Insert before the results block in `test/test-build-meta.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./test/test-build-meta.sh`
Expected: FAIL — `build_meta_arg_flags: command not found`.

- [ ] **Step 3: Implement the helper**

Append to `lib/common.sh`:

```bash
# Fill BUILD_META_ARG_FLAGS with MIGET_* --build-arg pairs from a build-meta
# JSON object ($1), for Dockerfile/Compose opt-in. Empty values are skipped.
build_meta_arg_flags() {
  local meta="$1"
  BUILD_META_ARG_FLAGS=()
  [ -z "$meta" ] && return 0
  local pairs=(
    "commit:MIGET_GIT_COMMIT" "commit_short:MIGET_GIT_COMMIT_SHORT"
    "branch:MIGET_GIT_BRANCH" "description:MIGET_GIT_DESCRIPTION"
    "committed_at:MIGET_GIT_COMMITTED_AT" "repository:MIGET_GIT_REPOSITORY"
    "built_at:MIGET_BUILD_AT" "builder_version:MIGET_BUILDER_VERSION"
    "language:MIGET_LANGUAGE"
  )
  local pair key argname val
  for pair in "${pairs[@]}"; do
    key="${pair%%:*}"; argname="${pair#*:}"
    val=$(printf '%s' "$meta" | jq -r --arg k "$key" '.[$k] // empty')
    [ -n "$val" ] && BUILD_META_ARG_FLAGS+=(--build-arg "$argname=$val")
  done
}
```

- [ ] **Step 4: Run helper test to verify it passes**

Run: `./test/test-build-meta.sh`
Expected: PASS.

- [ ] **Step 5: Wire into Dockerfile + Compose buildx**

Dockerfile path — after Task 4's `build_meta_label_flags "$BUILD_META_JSON"` (added before `bin/build:991`), add:

```bash
build_meta_arg_flags "$BUILD_META_JSON"
```

Then add `"${BUILD_META_ARG_FLAGS[@]}"` to the Dockerfile buildx (`bin/build:992`) after `"${BUILD_LABEL_FLAGS[@]}"`.

Compose path — after Task 4's per-service `build_meta_label_flags "$BUILD_META_JSON"` (added before `bin/build:1108`), add:

```bash
    build_meta_arg_flags "$BUILD_META_JSON"
```

Then add `"${BUILD_META_ARG_FLAGS[@]}"` to the Compose buildx (`bin/build:1109`) after `"${BUILD_LABEL_FLAGS[@]}"`.

- [ ] **Step 6: Run the suite**

Run: `make test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh bin/build test/test-build-meta.sh
git commit -m "feat(build-meta): pass MIGET_* build-args to Dockerfile/Compose builds"
```

---

### Task 7: Bake `MIGETPACKS_VERSION` into the builder image

**Files:**
- Modify: `Dockerfile` (add `ARG`/`ENV` near `bin/build:29-30` ENV block)
- Modify: `Dockerfile.alpine` (same)
- Modify: `.github/workflows/release.yml` (`build-args` on both build-push steps, `:55-78`)

**Interfaces:**
- Produces: `$MIGETPACKS_VERSION` available in the builder runtime, consumed by `ensure_build_meta_json` (Task 3) → `build.builder_version` / `MIGET_BUILDER_VERSION`.

- [ ] **Step 1: Add ARG/ENV to `Dockerfile`**

In `Dockerfile`, after the existing `ENV BUILDPACK_DIR=/buildpack` / `ENV PORT=5000` block (around line 29-30), add:

```dockerfile
ARG MIGETPACKS_VERSION=""
ENV MIGETPACKS_VERSION=${MIGETPACKS_VERSION}
```

- [ ] **Step 2: Add ARG/ENV to `Dockerfile.alpine`**

Add the same two lines to `Dockerfile.alpine` in the equivalent ENV section.

- [ ] **Step 3: Pass the build-arg in `release.yml`**

In `.github/workflows/release.yml`, add a `build-args` block to the "Build and push main image" step (after `platforms:`, `:60`) and the alpine step (`:70`):

```yaml
          build-args: |
            MIGETPACKS_VERSION=${{ steps.version.outputs.version }}
```

- [ ] **Step 4: Verify the wiring locally**

```bash
docker build --build-arg MIGETPACKS_VERSION=0.0.264 -t migetpacks-test -f Dockerfile . >/dev/null
docker run --rm --entrypoint sh migetpacks-test -c 'echo $MIGETPACKS_VERSION'
```

Expected: prints `0.0.264`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile Dockerfile.alpine .github/workflows/release.yml
git commit -m "feat(build-meta): bake MIGETPACKS_VERSION into builder image"
```

---

### Task 8: Documentation (migetpacks `docs/`)

**Files:**
- Modify: `docs/reference/result-json.mdx` (new `build` field row + section)
- Create: `docs/configuration/build-metadata.mdx`
- Modify: `docs/configuration/environment-variables.mdx` (cross-link)
- Modify: `docs/docs.json` (register the new page in nav)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add the `build` row + section to `result-json.mdx`**

In `docs/reference/result-json.mdx`, add a row to the Schema table:

```markdown
| `build` | object | Git provenance and builder facts (commit, branch, description, repository, build time, builder version) |
```

Add a section after the `env` section:

````markdown
### build

Git provenance and builder facts, present on every build:

```json
{
  "build": {
    "commit": "9f3c1a7b8e2d4f5a6c7b8e2d4f5a6c7b8e2d4f5a",
    "commit_short": "9f3c1a7",
    "branch": "main",
    "description": "Fix build-vars call order",
    "committed_at": "2026-06-17T19:40:00Z",
    "built_at": "2026-06-17T20:00:00Z",
    "builder_version": "0.0.264",
    "language": "ruby",
    "repository": "https://github.com/acme/my-api"
  }
}
```

Unknown fields are omitted. Values resolve by precedence: the `build-meta`
input envelope, then `MIGET_GIT_*` / `SOURCE_VERSION` environment variables,
then `.git` autodetection of the source directory.
````

- [ ] **Step 2: Create `docs/configuration/build-metadata.mdx`**

```mdx
---
title: "Build Metadata"
description: "Git provenance and builder facts emitted on every build"
---

## Overview

migetpacks records who built an image and from which commit, then exposes that
on four surfaces:

- The `build` block in the [result JSON](/reference/result-json).
- OCI image labels you can read with `docker inspect` without running the image.
- An in-image file `/.miget/build.json` (buildpack builds).
- `MIGET_*` build args for custom Dockerfile and Compose builds.

## Sources

Each field resolves by precedence, highest first:

1. The `build-meta` input envelope (set by the platform).
2. `MIGET_GIT_*` or `SOURCE_VERSION` environment variables, for standalone
   `docker run` or CI builds.
3. `.git` autodetection of the source directory.

Unknown fields are omitted rather than set to empty strings.

## OCI labels

| Label | Value |
|-------|-------|
| `org.opencontainers.image.revision` | Full commit SHA |
| `org.opencontainers.image.source` | Repository URL |
| `org.opencontainers.image.created` | Build time (ISO 8601) |
| `com.miget.git.branch` | Branch |
| `com.miget.git.description` | Commit subject |
| `com.miget.builder.version` | migetpacks version |

```bash
docker inspect my-app:latest --format '{{json .Config.Labels}}'
```

## In-image file

Buildpack builds include `/.miget/build.json`, useful when you prefer a file
over environment variables or run a distroless image with no shell:

```bash
docker run --rm my-app:latest cat /.miget/build.json
```

## Custom Dockerfile and Compose builds

migetpacks does not modify a Dockerfile it does not own, so it passes the values
as build args. Opt in from your Dockerfile:

```dockerfile
ARG MIGET_GIT_COMMIT
ENV MIGET_GIT_COMMIT=${MIGET_GIT_COMMIT}
```
````

- [ ] **Step 3: Register the page in `docs.json` and cross-link**

In `docs/docs.json`, add `"configuration/build-metadata"` to the Configuration nav group (next to `configuration/environment-variables`).

In `docs/configuration/environment-variables.mdx`, add a line under "Custom Environment Variables" pointing to the new page:

```markdown
For build provenance variables (`MIGET_GIT_COMMIT`, etc.) see [Build Metadata](/configuration/build-metadata).
```

- [ ] **Step 4: Verify docs build (if Mintlify CLI available)**

Run: `cd docs && mintlify dev` (or the repo's documented preview command)
Expected: the new page renders, nav shows it, links resolve. If the CLI is unavailable, verify frontmatter and relative links by inspection.

- [ ] **Step 5: Commit**

```bash
git add docs/reference/result-json.mdx docs/configuration/build-metadata.mdx docs/configuration/environment-variables.mdx docs/docs.json
git commit -m "docs(build-meta): document build block, labels, /.miget/build.json"
```

---

## Self-Review

**Spec coverage (section 1 of the design):**
- 1a gather (model C precedence, `.git` guards, repo normalization) → Tasks 1, 2.
- 1b `result.json` `build` block → Task 3.
- 1c OCI labels (all build types) → Task 4.
- 1d `/.miget/build.json` (buildpack) → Task 5.
- 1e `MIGET_*` build-args (Dockerfile/Compose) → Task 6.
- 1f builder version baked → Task 7.
- 1g docs → Task 8.

**Type/name consistency:** `BUILD_META_JSON` (global), `ensure_build_meta_json`, `gather_build_meta`, `resolve_meta_field`, `normalize_git_repository`, `build_meta_label_flags`/`BUILD_LABEL_FLAGS`, `build_meta_arg_flags`/`BUILD_META_ARG_FLAGS`, `stage_build_json` — used consistently across tasks.

**Notes for downstream plans (do not implement here):**
- The `build-meta` Shipwright param is assembled by the daemon (plan 2) and reaches migetpacks as `$BUILD_META`. This plan only consumes `$BUILD_META`.
- Runtime ENV injection, `<app>-meta`/`<app>-build` ConfigMaps, reserved-namespace guards, and `MIGET_APP_ID`/release vars are all downstream (plans 2-4).
