#!/usr/bin/env bash
# Common helper functions for buildpack

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Output functions
header() {
  echo ""
  echo -e "${BLUE}-----> $1${NC}"
}

info() {
  echo "       $1"
}

success() {
  echo -e "${GREEN}-----> $1${NC}"
}

warning() {
  echo -e "${YELLOW}-----> $1${NC}"
}

error() {
  echo -e "${RED}-----> ERROR: $1${NC}" >&2
}

# Validate a name against the POSIX environment-variable identifier rule
# (IEEE Std 1003.1 sec. 8.1): a letter or underscore followed by letters,
# digits, or underscores. This is the same constraint Docker enforces on
# `ARG`/`ENV` keys and shells enforce on `$VAR` expansion.
#
# Build args MUST satisfy it; runtime-only settings with other names (e.g. the
# dotted `discovery.seed_hosts` style used by Elasticsearch/Java) are valid
# container env vars but cannot be Docker build args, so the build-arg
# projection skips them. See docs/configuration/environment-variables.mdx.
is_valid_build_arg_name() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

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

# Detect language
detect_language() {
  local build_dir=$1
  "$BUILDPACK_DIR/bin/detect" "$build_dir" 2>/dev/null || echo ""
}
