# Build Metadata (Dyno-Metadata Equivalent) — Design

**Date:** 2026-06-17
**Status:** Approved (pending spec review)
**Repos touched:** `migetpacks` (producer), `migets-k8s-daemon` (consumer), `miget-kube-api` (namespace guard)

## Problem

Apps deployed through Miget have no way to know, at runtime, *which build they are* — the
commit they were built from, the branch, the commit message, when they were built, or the
release version. Heroku exposes this via [dyno metadata](https://devcenter.heroku.com/articles/dyno-metadata)
(`HEROKU_SLUG_COMMIT`, `HEROKU_RELEASE_VERSION`, …); Render and Railway expose equivalents.
Today migetpacks discards `.git/` from the runtime image (`docs/reference/runtime-container.mdx`),
so the information is lost.

We want the same capability without shipping the whole `.git/` directory: capture build
metadata once at build time, carry it through the existing build pipeline, and surface it to
the app at runtime — plus to tooling that inspects images without running them.

## Goals

- App can read its own build identity at runtime (commit, branch, description, build time,
  release version).
- Image carries provenance readable **without** running it (OCI labels, registry-inspectable).
- The Miget deploy pipeline (daemon) injects the metadata uniformly across **all** build types
  (buildpack, custom Dockerfile, Compose).
- Heroku-migrating apps work with zero code change (opt-in `HEROKU_*` aliases).
- The `MIGET_*` namespace is **reserved**: apps cannot set, spoof, or see these as user config.

## Non-Goals

- Per-running-instance identity (Heroku `HEROKU_DYNO_ID`). That is not known at build time; the
  runtime scheduler can add it later if wanted. We deliberately do **not** bake a static value.
- Rewriting user-authored Dockerfiles to force ENV/files into images migetpacks does not own.

## Architecture

```
                 ┌─────────────────────── migetpacks (producer) ───────────────────────┐
   .git/  ─────► │ gather metadata (model C: platform inputs win, .git fallback)        │
   platform ───► │   → OCI labels        (all build types)                              │
   env inputs    │   → result.json.build (all build types)   ◄── the cross-repo contract│
                 │   → /.miget/build.json (buildpack builds only)                       │
                 │   → MIGET_* build-args (Dockerfile/Compose opt-in)                   │
                 └──────────────────────────────────┬──────────────────────────────────┘
                                                     │ result.json (RabbitMQ build-completed event)
                                                     ▼
                 ┌──────────────── migets-k8s-daemon (consumer) ───────────────────────┐
                 │ read build_result["build"] → map to MIGET_* (+ HEROKU_* if compat)  │
                 │ inject via dedicated <app>-build ConfigMap, second envFrom on every  │
                 │ web/worker/release pod template                                      │
                 │ do NOT send_var_detected (never echoed to Rails / UI)                │
                 │ strip user-supplied MIGET_* from app env paths (reserved namespace)  │
                 └─────────────────────────────────────────────────────────────────────┘

                 ┌──────────────── miget-kube-api (namespace guard) ───────────────────┐
                 │ extend reserved-prefix filter: reject MIGET_* push options/env       │
                 │ (mirrors existing BUILD_VAR_ guard in parse_push_options_header)      │
                 └─────────────────────────────────────────────────────────────────────┘
```

The key decision: **runtime ENV is injected by the platform, not baked by migetpacks.** This
mirrors how Heroku actually works (metadata injected at dyno runtime, not into the slug) and
sidesteps the Dockerfile-ownership problem — the env lands at the k8s pod layer uniformly for
every build type.

## The Contract: `result.json` `build` block

migetpacks adds a `build` object to the result JSON written by `write_result_file()`
(`bin/build:676`). Present for **all** build types. Fields with unknown values are **omitted**
(not set to empty string), so a missing key is meaningful.

```json
"build": {
  "commit":            "9f3c1a7b8e2d4f5a6c7b8e2d4f5a6c7b8e2d4f5a",
  "commit_short":      "9f3c1a7",
  "branch":            "main",
  "description":       "Fix build-vars call order",
  "committed_at":      "2026-06-17T19:40:00Z",
  "built_at":          "2026-06-17T20:00:00Z",
  "builder_version":   "0.0.264",
  "language":          "ruby",
  "repository":        "github.com/acme/my-api",
  "release_version":   "v42",
  "release_created_at": null
}
```

| Field | Source | Notes |
|-------|--------|-------|
| `commit` | platform input → `.git` | full 40-char SHA |
| `commit_short` | derived from `commit` | first 7 chars |
| `branch` | platform input → `.git` | |
| `description` | platform input → `.git` | commit subject line only |
| `committed_at` | platform input → `.git` | ISO-8601 UTC |
| `built_at` | builder | ISO-8601 UTC, build completion |
| `builder_version` | builder image | see "Builder version" task below |
| `language` | builder | already computed (`LANG_NORMALIZED`) |
| `repository` | platform input | omitted if unknown (no reliable `.git` value) |
| `release_version` | platform input | omitted for standalone `docker run`/CI |
| `release_created_at` | platform input | omitted if unknown |

## Runtime env vars (injected by the daemon)

Mapped 1:1 from the `build` block. Heroku equivalents shown for reference.

| Env var | From `build.*` | Heroku equivalent |
|---------|----------------|-------------------|
| `MIGET_GIT_COMMIT` | `commit` | `HEROKU_SLUG_COMMIT` |
| `MIGET_GIT_COMMIT_SHORT` | `commit_short` | — |
| `MIGET_GIT_BRANCH` | `branch` | — |
| `MIGET_GIT_DESCRIPTION` | `description` | `HEROKU_SLUG_DESCRIPTION` |
| `MIGET_GIT_COMMITTED_AT` | `committed_at` | — |
| `MIGET_GIT_REPOSITORY` | `repository` | — |
| `MIGET_BUILD_AT` | `built_at` | — |
| `MIGET_BUILDER_VERSION` | `builder_version` | `STACK` (loosely) |
| `MIGET_LANGUAGE` | `language` | — |
| `MIGET_APP_NAME` | platform | `HEROKU_APP_NAME` |
| `MIGET_APP_ID` | platform | `HEROKU_APP_ID` |
| `MIGET_RELEASE_VERSION` | `release_version` | `HEROKU_RELEASE_VERSION` |
| `MIGET_RELEASE_CREATED_AT` | `release_created_at` | `HEROKU_RELEASE_CREATED_AT` |

`MIGET_APP_NAME` / `MIGET_APP_ID` come from the daemon's deploy context (it already knows
`app_name` / `app_id` in `handlers.py`), not from `result.json`.

### Heroku compatibility aliases

When Heroku-compat is enabled, the daemon **also** emits the `HEROKU_*` aliases above alongside
the `MIGET_*` vars. Off by default to keep a clean namespace; on, it makes Sentry/Rollbar/Datadog
SDKs and Heroku-era initializers that read `HEROKU_SLUG_COMMIT` work with no code change.
(`DYNO=miget` already exists in the runtime Dockerfile — `bin/build:2221` — so Heroku mimicry is
established precedent.)

**The toggle is the one user-settable `MIGET_*` key — recognized as a control flag, not a runtime
env var.** `MIGET_HEROKU_COMPAT` is the single exception to the reserved-namespace strip (specs
2d/3a). A user may set it in the UI env list **or** in a Compose service's `environment:`.
Wherever the reserved-namespace filter runs, this one key is **special-cased**: instead of being
dropped like every other `MIGET_*` key, it is **extracted** (enabling `HEROKU_*` alias injection
for that app/service) and then **consumed** — it is **not** passed through into the container.
Every other `MIGET_*` user key is still rejected. Result: inside the container, the user sees the
platform-managed `MIGET_*` build metadata and the `HEROKU_*` aliases, but never
`MIGET_HEROKU_COMPAT` itself — so the invariant "every `MIGET_*` var present at runtime is
platform-managed" holds.

## How an app reads it

**Inside the container** (the two app-facing surfaces):

- **Env vars** — `process.env.MIGET_GIT_COMMIT`, `ENV["MIGET_GIT_COMMIT"]`,
  `os.environ["MIGET_GIT_COMMIT"]`. The normal path; classic use is a `/version` endpoint.
- **`/.miget/build.json`** — root-anchored file (buildpack builds). The only in-container option
  for distroless/DHI images (no shell, but the process can `open()` a file).

**Outside the container** (tooling surfaces, by design not readable from inside):

- **OCI labels** — `docker inspect` / `skopeo` / registry API, without pulling+running.
- **`result.json`** — consumed by the daemon; never enters the container.

## Component specs

### 1. migetpacks (producer — this repo)

**1a. Gather metadata (model C).** New function in `bin/build` (or `lib/common.sh`), called
early — **before** the runtime `.git` cleanup. Precedence per field: explicit platform input
(`MIGET_GIT_COMMIT` / `SOURCE_VERSION` / `MIGET_*` env, and `BUILD_VARS` envelope) wins;
otherwise fall back to `git -C "$EFFECTIVE_SOURCE_DIR" …` when `.git` is present. Guard every
git call: shallow clones, tarball sources, and detached HEAD must degrade to "field omitted",
never error. Store gathered values in a single JSON blob (`BUILD_META_JSON`) reused by all
surfaces.

**1b. `result.json` `build` block.** Extend `write_result_file()` (`bin/build:676`) to merge
`BUILD_META_JSON` as `{build: …}`, same pattern as the existing `env`/`formation`/`custom`
merges. Emit it on **success and failure** result files (a failed build still has a commit).

**1c. OCI labels (all build types).** Add `--label` flags to every `docker buildx build`
invocation: the buildpack build (`bin/build:~960`), the Dockerfile build (`bin/build:992`), and
each Compose service (`bin/build:1109`). Labels:
`org.opencontainers.image.revision=<commit>`, `…image.source=<repository>`,
`…image.created=<built_at>`, `…image.version=<release_version>`, plus
`com.miget.git.branch`, `com.miget.git.description`, `com.miget.builder.version`. Omit any label
whose value is empty.

**1d. `/.miget/build.json` (buildpack builds only).** In the generated runtime Dockerfile,
before the final `USER` switch, write the blob as root, world-readable:
`RUN mkdir -p /.miget && printf '%s' '<json>' > /.miget/build.json && chmod 0644 /.miget/build.json`.
Works for standard and DHI images. Not added to Dockerfile/Compose builds (migetpacks does not
own those Dockerfiles — graceful degradation).

**1e. `MIGET_*` build-args for Dockerfile/Compose opt-in.** Pass the metadata as `--build-arg
MIGET_*` on the Dockerfile (`bin/build:992`) and Compose (`bin/build:1109`) builds so a user
Dockerfile may opt in (`ARG MIGET_GIT_COMMIT` → `ENV MIGET_GIT_COMMIT=${MIGET_GIT_COMMIT}`).
No auto-ENV, no Dockerfile rewriting.

**1f. Builder version source.** `MIGET_BUILDER_VERSION` / `build.builder_version` must equal the
migetpacks image version (`IMAGE_TAG` in `Makefile`, currently `0.0.264`). The Dockerfile does
not bake this today. Add `ARG MIGETPACKS_VERSION` + `ENV MIGETPACKS_VERSION=${MIGETPACKS_VERSION}`
to `Dockerfile` and `Dockerfile.alpine`, and pass `--build-arg MIGETPACKS_VERSION=<version>` from
`.github/workflows/release.yml`. `bin/build` reads `$MIGETPACKS_VERSION` (omit field if unset, e.g.
local dev image).

**1g. Docs.** Update `docs/reference/result-json.mdx` (new `build` block), add a "Build Metadata"
page documenting the `MIGET_*` vars, `/.miget/build.json`, labels, and `MIGET_HEROKU_COMPAT`.

### 2. migets-k8s-daemon (consumer — branch `feature/compose-part2`)

**2a. Read + map.** In `lib/k8s/builds/handlers.py` build-completed handler (~`:441`), read
`build_result.get("build", {})`, map to the `MIGET_*` dict (+ `HEROKU_*` when the app's heroku-compat
flag is on — the flag is derived by extracting `MIGET_HEROKU_COMPAT` from the user env in 2d/3a;
see Heroku compatibility aliases), and add `MIGET_APP_NAME`/`MIGET_APP_ID` from the existing deploy
context. Omit keys whose source value is missing.

**2b. Inject via dedicated ConfigMap (decision A).** Create/replace an `<app>-build` ConfigMap
holding the `MIGET_*` values (non-secret, release-scoped, overwritten wholesale each build —
*not* `set_env_vars_if_not_present`, because the commit changes every release). Add its name to
`get_env_from_secret_names`' result (or a sibling `env_from` list) so a second `envFrom:
configMapRef: <app>-build` is baked into every web/worker/release pod template alongside the
existing `<app>-env` secret (`handlers.py:586-594`).

**2c. Do not echo to Rails.** Do **not** call `send_var_detected` (`handlers.py:49`) for these.
They must never appear in the UI env list — they are platform-managed, not user config.

**2d. Reserved-namespace strip (with the one compat exception).** Before applying user env to the
runtime (app.json `build_result["env"]` at `handlers.py:510`, the Compose service-env path, and
any Rails-pushed env-update path), handle `MIGET_*` user keys:
- `MIGET_HEROKU_COMPAT` → **extract** as the app/service heroku-compat flag (consumed by 2a),
  then **drop** from the runtime passthrough (not injected into the container).
- every other `^MIGET_` key → **drop** and log.

Prevents apps from spoofing/overriding build metadata while still letting the user toggle compat.

### 3. miget-kube-api (namespace guard — checkout a branch if changes needed)

**3a.** Extend the existing reserved-prefix guard in `parse_push_options_header`
(`builds_trigger.py:801`) to reject keys starting with `MIGET_`, mirroring the `BUILD_VAR_` rule —
**except** `MIGET_HEROKU_COMPAT`, which is allowed through (or extracted as the compat flag) rather
than rejected, since it is the user-facing toggle. If any other path lets user-defined env reach
the app-env channel, apply the same rule there. This is the outermost gate; 2d is
defense-in-depth and performs the final extract-then-strip before runtime injection.

## Edge cases & error handling

- **No `.git`, no platform input** (plain tarball `docker run`): `build` block contains only
  builder-known fields (`built_at`, `builder_version`, `language`). All git/release fields
  omitted. No error.
- **Shallow clone / detached HEAD**: git commands may return partial data; each field guarded
  independently — capture what resolves, omit the rest.
- **Failed build**: result file still gets the `build` block (commit known even when build fails)
  — useful for the pipeline's failure notifications.
- **DHI/distroless**: `/.miget/build.json` is written as root before the `nonroot` `USER` switch;
  readable by the app process. Labels and result.json unaffected.
- **User sets `MIGET_FOO`**: stripped at both kube-api (3a) and daemon (2d); never reaches runtime,
  never shown in UI.
- **Value escaping**: commit `description` may contain quotes/newlines — must be JSON-escaped for
  result.json and `/.miget/build.json`, and shell/label-escaped for `--label` / `--build-arg`
  (reuse the existing escaping helpers used by `inject_custom_env_vars`).

## Testing

- **migetpacks** (`test/`): unit test the gather function — env-override-wins, `.git` fallback,
  missing-`.git` omission, detached HEAD. Assert `result.json` contains a well-formed `build`
  block. Assert `/.miget/build.json` exists and parses in a buildpack image; assert labels via
  `docker inspect` for all three build types.
- **daemon** (`tests/`): given a `build_result` with a `build` block, assert the `<app>-build`
  ConfigMap is created with the mapped `MIGET_*` keys, the second `envFrom` is baked into pod
  templates, `HEROKU_*` appears only when compat is on, `send_var_detected` is **not** called for
  `MIGET_*`, user `MIGET_*` keys are stripped, and `MIGET_HEROKU_COMPAT` is extracted as the compat
  flag (enabling `HEROKU_*`) yet not injected into the container.
- **kube-api** (`tests/`): `parse_push_options_header` rejects `MIGET_*` keys **except**
  `MIGET_HEROKU_COMPAT`, which is allowed through / extracted.

## Open questions

None blocking. `repository` URL format (`github.com/org/repo` vs full clone URL) to be finalized
against whatever the platform already passes the daemon; default to whatever `BUILD_VARS` carries.
