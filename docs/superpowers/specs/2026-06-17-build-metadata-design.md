# Build Metadata (Dyno-Metadata Equivalent) — Design

**Date:** 2026-06-17
**Status:** Approved (pending spec review)
**Repos touched:** `migetpacks` (producer of git provenance), `migetapp`/Rails (identity + git
inputs, branch `feature/introduce-compose-stacks`), `migets-k8s-daemon` (consumer/injector, branch
`feature/compose-part2`), `miget-kube-api` (namespace guard)

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
   migetapp (Rails) ── add_app ──► app identity {app_uuid, app_name, heroku_compat}
          │                              │ (static, once per app — all deploy methods)
          │ git provenance               ▼
          │ (github/public_git)   migets-k8s-daemon: persist in <app>-meta ConfigMap
          ▼
                 ┌─────────────────────── migetpacks (producer) ───────────────────────┐
   .git/  ─────► │ gather metadata (model C: platform git inputs win, .git fallback)    │
   platform ───► │   → OCI labels        (all build types)                              │
   git inputs    │   → result.json.build (all build types)   ◄── per-build provenance   │
                 │   → /.miget/build.json (buildpack builds only)                       │
                 │   → MIGET_* build-args (Dockerfile/Compose opt-in)                   │
                 └──────────────────────────────────┬──────────────────────────────────┘
                                                     │ result.json (RabbitMQ build-completed event)
                                                     ▼
                 ┌──────────────── migets-k8s-daemon (consumer) ───────────────────────┐
                 │ compose MIGET_* from THREE sources:                                  │
                 │   1. result.json.build  → git provenance + builder facts             │
                 │   2. <app>-meta CM      → app_uuid / app_name / heroku_compat        │
                 │   3. per-build context  → release_version / release_created_at (opt) │
                 │ (+ HEROKU_* aliases if compat) → write <app>-build ConfigMap          │
                 │ second envFrom on every web/worker/release pod template              │
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

`result.json.build` carries **per-build git provenance + builder facts only**. App identity and
release info are *not* here — migetpacks doesn't know them; the daemon adds them at injection time
from other sources (see "Three sources" below).

```json
"build": {
  "commit":          "9f3c1a7b8e2d4f5a6c7b8e2d4f5a6c7b8e2d4f5a",
  "commit_short":    "9f3c1a7",
  "branch":          "main",
  "description":     "Fix build-vars call order",
  "committed_at":    "2026-06-17T19:40:00Z",
  "built_at":        "2026-06-17T20:00:00Z",
  "builder_version": "0.0.264",
  "language":        "ruby",
  "repository":      "github.com/acme/my-api"
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

Release info (`release_version`, `release_created_at`) and app identity (`app_uuid`, `app_name`)
are **not** in this block — see the env-var table and "Three sources" below.

## Runtime env vars (injected by the daemon)

Mapped 1:1 from the `build` block. Heroku equivalents shown for reference.

| Env var | Source | Heroku equivalent |
|---------|--------|-------------------|
| `MIGET_GIT_COMMIT` | `result.json.build.commit` | `HEROKU_SLUG_COMMIT` |
| `MIGET_GIT_COMMIT_SHORT` | `result.json.build.commit_short` | — |
| `MIGET_GIT_BRANCH` | `result.json.build.branch` | — |
| `MIGET_GIT_DESCRIPTION` | `result.json.build.description` | `HEROKU_SLUG_DESCRIPTION` |
| `MIGET_GIT_COMMITTED_AT` | `result.json.build.committed_at` | — |
| `MIGET_GIT_REPOSITORY` | `result.json.build.repository` | — |
| `MIGET_BUILD_AT` | `result.json.build.built_at` | — |
| `MIGET_BUILDER_VERSION` | `result.json.build.builder_version` | `STACK` (loosely) |
| `MIGET_LANGUAGE` | `result.json.build.language` | — |
| `MIGET_APP_NAME` | `<app>-meta` ConfigMap (add_app) | `HEROKU_APP_NAME` |
| `MIGET_APP_ID` | `<app>-meta` ConfigMap (add_app) — `app.uuid` | `HEROKU_APP_ID` |
| `MIGET_RELEASE_VERSION` | per-build deploy context (omit if absent) | `HEROKU_RELEASE_VERSION` |
| `MIGET_RELEASE_CREATED_AT` | per-build deploy context (omit if absent) | `HEROKU_RELEASE_CREATED_AT` |

### Three sources the daemon merges

The daemon composes the `MIGET_*` set at build-completed time from three places, by the *nature*
of each datum:

1. **`result.json.build`** — *per-build git provenance + builder facts* (commit, branch,
   description, committed_at, built_at, builder_version, language, repository). Produced by
   migetpacks; baked into the image's labels and `/.miget/build.json` too.
2. **`<app>-meta` ConfigMap** — *static per-app identity* (app UUID, app name, heroku-compat flag),
   written once at **add_app** (see "App identity via add_app"). Read for every build regardless of
   trigger method (github / public-git push / container registry).
3. **Per-build deploy context** — *release info* (`release_version`, `release_created_at`), if the
   trigger supplies it; omitted otherwise. Not static, not git provenance — a deploy counter.

**`MIGET_APP_ID` is the app UUID** (`apps.uuid`, `gen_random_uuid()`, unique — it already exists in
Rails). It must **not** reuse the daemon's existing `app_id` (`watcher.miget.com/object.id`,
`builds_trigger.py:182`), which is the **DB record id**. The UUID arrives via `add_app` → source 2,
so it is available for all deploy methods (this is why identity goes through `add_app`, not the
per-build trigger). Omit `MIGET_APP_ID` only if `<app>-meta` is somehow absent.

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
early — **before** the runtime `.git` cleanup. Precedence per field, highest first:
1. The **`$BUILD_META` envelope** (the new Shipwright `build-meta` param — see "Provenance channel";
   parsed exactly like the existing `$BUILD_VARS`). The platform path.
2. Direct `MIGET_GIT_*` / `SOURCE_VERSION` env vars — a convenience for standalone `docker run` /
   GitHub Actions users who have no Shipwright envelope.
3. `git -C "$EFFECTIVE_SOURCE_DIR" …` autodetection when `.git` is present.

Normalize `repository` to a full HTTPS URL in the fallback (see "`repository` format"). Guard every
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
`…image.created=<built_at>`, plus `com.miget.git.branch`, `com.miget.git.description`,
`com.miget.builder.version`. (No `…image.version` — release_version is deploy context, unknown to
the builder.) Omit any label whose value is empty.

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

**2a. Read + map (three sources).** In `lib/k8s/builds/handlers.py` build-completed handler
(~`:441`), compose the `MIGET_*` dict from the three sources above:
- `build_result.get("build", {})` → `MIGET_GIT_*`, `MIGET_BUILD_AT`, `MIGET_BUILDER_VERSION`,
  `MIGET_LANGUAGE`, `MIGET_GIT_REPOSITORY`.
- the `<app>-meta` ConfigMap (2e) → `MIGET_APP_ID` (= `app.uuid`), `MIGET_APP_NAME`, and the
  heroku-compat flag. **Do not** reuse the existing `app_id` (`watcher.miget.com/object.id`) — that
  is the DB record id.
- per-build deploy context (if present) → `MIGET_RELEASE_VERSION`, `MIGET_RELEASE_CREATED_AT`.

Emit `HEROKU_*` aliases when the compat flag (from `<app>-meta`) is on. Omit any key whose source
value is missing.

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
- `MIGET_HEROKU_COMPAT` → **extract** as the heroku-compat flag for this deploy, then **drop**
  from the runtime passthrough (not injected into the container).
- every other `^MIGET_` key → **drop** and log.

The compat flag's source of truth is `<app>-meta` (2e), set at add_app from the Rails app setting.
An inline `MIGET_HEROKU_COMPAT` (UI env / compose env) is the alternative input extracted here; the
daemon treats compat as ON if **either** the `<app>-meta` flag or the extracted inline value is
true. Prevents apps from spoofing/overriding build metadata while still letting the user toggle
compat.

**2e. `<app>-meta` ConfigMap (static app identity).** At `add_app` (`main.py:580`, which already
receives `app_config`/`deployment_config`), create/update a per-app `<app>-meta` ConfigMap holding
`app_uuid`, `app_name`, and `heroku_compat`. This is written **once per app** (not per build), so
it is available to every subsequent build-completed event regardless of deploy method
(github / public-git push / container registry). 2a reads it. Keeping it separate from the
release-scoped `<app>-build` ConfigMap (2b) cleanly splits *static identity* from *per-release
provenance*. (Annotations on the app's Deployment, mirroring the existing
`watcher.miget.com/object.id`, are an acceptable alternative carrier; a ConfigMap is preferred for
holding several keys.)

**2f. Assemble the `build-meta` param (build-trigger side).** When constructing the BuildRun
(`lib/k8s/builds/shipwright.py`, alongside the existing `build-vars` at `:247-250`), add a
`build-meta` param: a JSON envelope `{commit, branch, description, committed_at, repository}`. Source
per deploy method: github/public_git → from the provenance Rails includes in the deploy message;
git_push → from the daemon's own clone (`lib/git_clone.py`); container_registry → omit. Keep it a
**distinct** param from `build-vars` so it never mixes with the user app-env channel.

### 3. miget-kube-api (namespace guard — checkout a branch if changes needed)

**3a.** Extend the existing reserved-prefix guard in `parse_push_options_header`
(`builds_trigger.py:801`) to reject keys starting with `MIGET_`, mirroring the `BUILD_VAR_` rule —
**except** `MIGET_HEROKU_COMPAT`, which is allowed through (or extracted as the compat flag) rather
than rejected, since it is the user-facing toggle. If any other path lets user-defined env reach
the app-env channel, apply the same rule there. This is the outermost gate; 2d is
defense-in-depth and performs the final extract-then-strip before runtime injection.

App identity (UUID/name/compat) is **not** threaded through the per-build trigger here — it flows
through `add_app` instead (see section 4 + daemon 2e), so it is available for all deploy methods.

### 4. migetapp / Rails (producer of identity + git provenance — branch `feature/introduce-compose-stacks`)

Rails already holds everything needed; no new data to compute, only plumbing:

**4a. App identity at `add_app`.** Include `app_uuid` (= `app.uuid`, which already exists:
`apps.uuid`, `gen_random_uuid()`, unique), `app_name`, and the `heroku_compat` app setting in the
`add_app` payload (`app_config`). The daemon persists these in `<app>-meta` (2e). This is the
single source for `MIGET_APP_ID` / `MIGET_APP_NAME` / compat, and it covers github, public-git
push, and container-registry deploys uniformly — solving "we don't know the app id at git push /
container registry," since identity is registered once at app creation, not per build.

**4b. Git provenance as build input (model C platform side).** Rails already snapshots commit data
in `deployment_config` — `last_deployed_commit_sha` / `last_commit_message` / `last_commit_author`
/ `last_commit_timestamp` / `repository` (`app/services/apps/deploy.rb:48-114`) and the branch.
For `github`/`public_git` deploys, include these in the **deploy message** so the daemon fills the
`build-meta` param (2f) — the platform-authoritative source that wins over `.git` autodetection in
migetpacks. Send `repository` as the full HTTPS URL via the existing `repository_url` helper
(`deployment_configs/github.rb:64`). `git_push` (Gitea) provenance is filled daemon-side from the
clone; `container_registry` has no commit (git fields omitted).

**4c. Heroku-compat toggle (UI).** Surface the per-app `heroku_compat` setting in app settings. It
is **not** a user-typed `MIGET_*` env var (those are reserved/stripped) — it is a first-class app
setting that flows via 4a into `<app>-meta`. (The inline `MIGET_HEROKU_COMPAT` env/compose path of
2d/3a is a secondary convenience, not the primary UI.)

**4d. Release info (optional).** If `MIGET_RELEASE_VERSION` / `MIGET_RELEASE_CREATED_AT` are wanted,
Rails supplies the release counter (`Deployment` count, `app/models/deployment.rb:68`) per build as
deploy context. Optional — omit to ship without release parity initially.

**4e. Reserved namespace in the UI.** The env-var editor must reject/hide user-entered `MIGET_*`
keys (except the compat toggle, which is its own setting), matching the kube-api (3a) and daemon
(2d) guards. Build-metadata vars are never shown as editable config.

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
- **daemon** (`tests/`): `add_app` writes `<app>-meta` with `app_uuid`/`app_name`/`heroku_compat`.
  Given a `build_result` with a `build` block + an `<app>-meta` ConfigMap, assert the `<app>-build`
  ConfigMap is composed from all three sources with the mapped `MIGET_*` keys (incl. `MIGET_APP_ID`
  = the uuid, **not** `object.id`), the second `envFrom` is baked into pod templates, `HEROKU_*`
  appears only when compat is on, `send_var_detected` is **not** called for `MIGET_*`, user
  `MIGET_*` keys are stripped, and `MIGET_HEROKU_COMPAT` is extracted (enabling `HEROKU_*`) yet not
  injected into the container.
- **kube-api** (`tests/`): `parse_push_options_header` rejects `MIGET_*` keys **except**
  `MIGET_HEROKU_COMPAT`, which is allowed through / extracted.
- **migetapp** (`spec/`): `add_app` payload includes `app_uuid`/`app_name`/`heroku_compat`; git
  provenance is passed as `MIGET_*` build inputs for github/public_git deploys; the env-var editor
  rejects user-entered `MIGET_*` keys.

## Resolved decisions (formerly open questions)

### `repository` format → full HTTPS URL

Surface `repository` as `https://<host>/<owner>/<repo>` (e.g. `https://github.com/acme/my-api`),
**not** the bare `owner/repo`. This is the OCI convention for `org.opencontainers.image.source` (a
fetchable URL) and the value GitHub/GHCR read to auto-link an image to its repo. Rails already has
the helper: `deployment_configs/github.rb:64` `repository_url` = `"https://github.com/#{repository}"`
(`repository` is stored as `owner/repo`, `github.rb:4`). Normalization (Rails for
github/public_git; migetpacks for the `.git` fallback): strip `.git`, strip embedded credentials,
convert `git@host:org/repo` → `https://host/org/repo`. Gitea (`git_push`) uses its own host URL.

### Provenance channel → dedicated `build-meta` Shipwright param (JSON envelope)

migetpacks receives git provenance through a **new Shipwright param `build-meta`**, parallel to the
existing `build-vars` (`shipwright.py:247-250`):

```
build-meta = {"commit": "...", "branch": "...", "description": "...",
              "committed_at": "...", "repository": "https://github.com/acme/my-api"}
```

migetpacks reads it as `$BUILD_META` (exactly as it already reads `$BUILD_VARS`) and uses it as the
model-C **platform-input** source — highest precedence, `.git` autodetection below it. Rationale:
- A **separate envelope from `build-vars`** makes it a platform-internal channel, distinct from the
  user app-env channel. The reserved-namespace guards (2d/3a) protect the *user* channel only, so
  there is **no collision and no spoofing** — users cannot write into `build-meta` (daemon-assembled
  server-side).
- **Not `custom-data`**: that is an opaque daemon round-trip blob echoed back to
  `result.json.custom`; overloading it with inputs migetpacks must parse couples unrelated concerns.
- **Assembly per method:** github/public_git → Rails passes provenance in the deploy message → the
  daemon fills `build-meta`. git_push → the daemon already clones (`lib/git_clone.py`) and fills
  `build-meta` from the clone. container_registry → omitted (no git).

## Open questions

None blocking. (Optional future nicety: a `MIGET_GIT_COMMIT_URL` derived from Rails' existing
`commit_url` helper — deferred, YAGNI.)
