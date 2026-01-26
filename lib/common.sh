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

# Detect language
detect_language() {
  local build_dir=$1
  "$BUILDPACK_DIR/bin/detect" "$build_dir" 2>/dev/null || echo ""
}
