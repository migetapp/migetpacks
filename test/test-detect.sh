#!/usr/bin/env bash
# Test script for detect functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/fixtures"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test function
test_detect() {
  local test_name=$1
  local fixture_dir=$2
  local expected_exit=$3
  local expected_output=$4
  local exit_code=0

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -n "Testing $test_name... "

  output=$("$ROOT_DIR/bin/detect" "$fixture_dir" 2>&1) || exit_code=$?

  if [ "$exit_code" -eq "$expected_exit" ]; then
    if [ -z "$expected_output" ] || echo "$output" | grep -q "$expected_output"; then
      echo -e "${GREEN}PASSED${NC}"
      TESTS_PASSED=$((TESTS_PASSED + 1))
      return 0
    fi
  fi

  echo -e "${RED}FAILED${NC}"
  echo "  Expected exit code: $expected_exit, got: $exit_code"
  if [ -n "$expected_output" ]; then
    echo "  Expected output to contain: $expected_output"
    echo "  Got: $output"
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
  return 1
}

# Test detection with environment variables
test_detect_with_env() {
  local test_name=$1
  local fixture_dir=$2
  local expected_exit=$3
  local expected_output=$4
  shift 4
  local env_vars=("$@")

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -n "Testing $test_name... "

  local exit_code=0
  output=$(env "${env_vars[@]}" "$ROOT_DIR/bin/detect" "$fixture_dir" 2>&1) || exit_code=$?

  if [ "$exit_code" -eq "$expected_exit" ]; then
    if [ -z "$expected_output" ] || echo "$output" | grep -q "$expected_output"; then
      echo -e "${GREEN}PASSED${NC}"
      TESTS_PASSED=$((TESTS_PASSED + 1))
      return 0
    fi
  fi

  echo -e "${RED}FAILED${NC}"
  echo "  Expected exit code: $expected_exit, got: $exit_code"
  if [ -n "$expected_output" ]; then
    echo "  Expected output to contain: $expected_output"
    echo "  Got: $output"
  fi
  TESTS_FAILED=$((TESTS_FAILED + 1))
  return 1
}

# Test version detection
test_version_detect() {
  local test_name=$1
  local fixture_dir=$2
  local language=$3
  local expected_version=$4

  TESTS_RUN=$((TESTS_RUN + 1))

  echo -n "Testing $test_name... "

  output=$(LANGUAGE="$language" "$ROOT_DIR/bin/detect-version" "$fixture_dir" 2>&1)

  if echo "$output" | grep -q "$expected_version"; then
    echo -e "${GREEN}PASSED${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  fi

  echo -e "${RED}FAILED${NC}"
  echo "  Expected version: $expected_version"
  echo "  Got: $output"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  return 1
}

# Create test fixtures
setup_fixtures() {
  echo -e "${YELLOW}Setting up test fixtures...${NC}"
  mkdir -p "$TEST_DIR"

  # Node.js fixture
  mkdir -p "$TEST_DIR/nodejs-app"
  echo '{"name": "test", "engines": {"node": "20.x"}}' > "$TEST_DIR/nodejs-app/package.json"
  echo "22.16.0" > "$TEST_DIR/nodejs-app/.node-version"

  # Bun fixture
  mkdir -p "$TEST_DIR/bun-app"
  echo '{"name": "test-bun"}' > "$TEST_DIR/bun-app/package.json"
  touch "$TEST_DIR/bun-app/bun.lockb"
  echo "1.3.4" > "$TEST_DIR/bun-app/.bun-version"

  # Ruby fixture
  mkdir -p "$TEST_DIR/ruby-app"
  echo "gem 'rails'" > "$TEST_DIR/ruby-app/Gemfile"
  echo "3.4.4" > "$TEST_DIR/ruby-app/.ruby-version"

  # Python fixture
  mkdir -p "$TEST_DIR/python-app"
  echo "flask==2.0.0" > "$TEST_DIR/python-app/requirements.txt"
  echo "3.13.4" > "$TEST_DIR/python-app/.python-version"

  # Go fixture
  mkdir -p "$TEST_DIR/go-app"
  echo -e "module test\n\ngo 1.25" > "$TEST_DIR/go-app/go.mod"

  # Rust fixture
  mkdir -p "$TEST_DIR/rust-app"
  echo -e '[package]\nname = "test"\nversion = "0.1.0"' > "$TEST_DIR/rust-app/Cargo.toml"
  echo "stable" > "$TEST_DIR/rust-app/rust-toolchain"

  # Elixir fixture
  mkdir -p "$TEST_DIR/elixir-app"
  echo "defmodule Test.MixProject do" > "$TEST_DIR/elixir-app/mix.exs"
  echo "1.18.4" > "$TEST_DIR/elixir-app/.elixir-version"

  # Scala fixture
  mkdir -p "$TEST_DIR/scala-app"
  echo 'scalaVersion := "3.5.2"' > "$TEST_DIR/scala-app/build.sbt"
  echo "3.5.2" > "$TEST_DIR/scala-app/.scala-version"

  # Deno fixture
  mkdir -p "$TEST_DIR/deno-app"
  echo '{"tasks": {"start": "deno run main.ts"}}' > "$TEST_DIR/deno-app/deno.json"
  echo "2.6.1" > "$TEST_DIR/deno-app/.deno-version"

  # Kotlin fixture
  mkdir -p "$TEST_DIR/kotlin-app"
  echo 'plugins { kotlin("jvm") version "2.1.0" }' > "$TEST_DIR/kotlin-app/build.gradle.kts"
  echo "2.1.0" > "$TEST_DIR/kotlin-app/.kotlin-version"

  # Dockerfile fixture (no other language files - pure Dockerfile project)
  mkdir -p "$TEST_DIR/dockerfile-app"
  echo "FROM alpine:3.21" > "$TEST_DIR/dockerfile-app/Dockerfile"
  echo "CMD echo hello" >> "$TEST_DIR/dockerfile-app/Dockerfile"

  # Compose fixture
  mkdir -p "$TEST_DIR/compose-app/api" "$TEST_DIR/compose-app/web"
  cat > "$TEST_DIR/compose-app/compose.yaml" <<EOF
services:
  api:
    build: ./api
  web:
    build:
      context: ./web
      dockerfile: Dockerfile
EOF
  echo "FROM node:22-slim" > "$TEST_DIR/compose-app/api/Dockerfile"
  echo "FROM node:22-slim" > "$TEST_DIR/compose-app/web/Dockerfile"

  # Monorepo fixture for PROJECT_PATH testing
  mkdir -p "$TEST_DIR/monorepo/services/api"
  echo '{"name": "api"}' > "$TEST_DIR/monorepo/services/api/package.json"
  mkdir -p "$TEST_DIR/monorepo/services/web"
  echo "FROM nginx" > "$TEST_DIR/monorepo/services/web/Dockerfile"

  # Unknown app (no recognizable files)
  mkdir -p "$TEST_DIR/unknown-app"
  echo "nothing" > "$TEST_DIR/unknown-app/README.md"
}

# Cleanup fixtures
cleanup_fixtures() {
  echo -e "${YELLOW}Cleaning up test fixtures...${NC}"
  rm -rf "$TEST_DIR"
}

# Run tests
run_tests() {
  echo -e "${YELLOW}Running detection tests...${NC}"

  # Detection tests
  test_detect "Deno detection" "$TEST_DIR/deno-app" 0 "Deno"
  test_detect "Bun detection" "$TEST_DIR/bun-app" 0 "Bun"
  test_detect "Node.js detection" "$TEST_DIR/nodejs-app" 0 "Node.js"
  test_detect "Ruby detection" "$TEST_DIR/ruby-app" 0 "Ruby"
  test_detect "Python detection" "$TEST_DIR/python-app" 0 "Python"
  test_detect "Go detection" "$TEST_DIR/go-app" 0 "Go"
  test_detect "Rust detection" "$TEST_DIR/rust-app" 0 "Rust"
  test_detect "Scala detection" "$TEST_DIR/scala-app" 0 "Scala"
  test_detect "Kotlin detection" "$TEST_DIR/kotlin-app" 0 "Kotlin"
  test_detect "Elixir detection" "$TEST_DIR/elixir-app" 0 "Elixir"
  test_detect "Dockerfile detection" "$TEST_DIR/dockerfile-app" 0 "Dockerfile"
  # Compose auto-detection disabled - use LANGUAGE=compose or COMPOSE_FILE env var
  # test_detect "Compose detection" "$TEST_DIR/compose-app" 0 "Compose"
  test_detect "Unknown app detection" "$TEST_DIR/unknown-app" 1 ""

  # PROJECT_PATH tests (monorepo support)
  echo ""
  echo -e "${YELLOW}Testing PROJECT_PATH support...${NC}"
  test_detect_with_env "PROJECT_PATH Node.js detection" "$TEST_DIR/monorepo" 0 "Node.js" "PROJECT_PATH=services/api"
  test_detect_with_env "PROJECT_PATH Dockerfile detection" "$TEST_DIR/monorepo" 0 "Dockerfile" "PROJECT_PATH=services/web"

  # DOCKERFILE_PATH tests
  echo ""
  echo -e "${YELLOW}Testing DOCKERFILE_PATH support...${NC}"
  test_detect_with_env "DOCKERFILE_PATH override" "$TEST_DIR/nodejs-app" 0 "Dockerfile" "DOCKERFILE_PATH=$TEST_DIR/dockerfile-app/Dockerfile"

  # COMPOSE_FILE tests
  echo ""
  echo -e "${YELLOW}Testing COMPOSE_FILE support...${NC}"
  test_detect_with_env "COMPOSE_FILE override" "$TEST_DIR/nodejs-app" 0 "Compose" "COMPOSE_FILE=$TEST_DIR/compose-app/compose.yaml"

  # Version detection tests
  test_version_detect "Node.js version from .node-version" "$TEST_DIR/nodejs-app" "nodejs" "22.16.0"
  test_version_detect "Bun version from .bun-version" "$TEST_DIR/bun-app" "bun" "1.3.4"
  test_version_detect "Deno version from .deno-version" "$TEST_DIR/deno-app" "deno" "2.6.1"
  test_version_detect "Ruby version from .ruby-version" "$TEST_DIR/ruby-app" "ruby" "3.4.4"
  test_version_detect "Python version from .python-version" "$TEST_DIR/python-app" "python" "3.13.4"
  test_version_detect "Go version from go.mod" "$TEST_DIR/go-app" "go" "1.25"
  test_version_detect "Rust version from rust-toolchain" "$TEST_DIR/rust-app" "rust" "stable"
  test_version_detect "Scala version from .scala-version" "$TEST_DIR/scala-app" "scala" "3.5.2"
  test_version_detect "Kotlin version from .kotlin-version" "$TEST_DIR/kotlin-app" "kotlin" "2.1.0"
  test_version_detect "Elixir version from .elixir-version" "$TEST_DIR/elixir-app" "elixir" "1.18.4"

  # Node.js package manager detection tests
  echo ""
  echo -e "${YELLOW}Testing Node.js package manager detection...${NC}"
  # Create yarn project
  mkdir -p "$TEST_DIR/nodejs-yarn"
  echo '{"name": "test-yarn"}' > "$TEST_DIR/nodejs-yarn/package.json"
  touch "$TEST_DIR/nodejs-yarn/yarn.lock"
  test_detect "Node.js (yarn) detection" "$TEST_DIR/nodejs-yarn" 0 "Node.js (yarn)"

  # Create pnpm project
  mkdir -p "$TEST_DIR/nodejs-pnpm"
  echo '{"name": "test-pnpm"}' > "$TEST_DIR/nodejs-pnpm/package.json"
  touch "$TEST_DIR/nodejs-pnpm/pnpm-lock.yaml"
  test_detect "Node.js (pnpm) detection" "$TEST_DIR/nodejs-pnpm" 0 "Node.js (pnpm)"

  # Create npm project with packageManager field (Corepack)
  mkdir -p "$TEST_DIR/nodejs-corepack-yarn"
  echo '{"name": "test-corepack", "packageManager": "yarn@4.0.0"}' > "$TEST_DIR/nodejs-corepack-yarn/package.json"
  test_detect "Node.js (yarn) via packageManager" "$TEST_DIR/nodejs-corepack-yarn" 0 "Node.js (yarn)"

  # Test default versions when no version file exists
  echo ""
  echo -e "${YELLOW}Testing default versions...${NC}"
  test_version_detect "Node.js default version" "$TEST_DIR/unknown-app" "nodejs" "22.16.0"
  test_version_detect "Bun default version" "$TEST_DIR/unknown-app" "bun" "1.3.4"
  test_version_detect "Deno default version" "$TEST_DIR/unknown-app" "deno" "2.6.1"
  test_version_detect "Ruby default version" "$TEST_DIR/unknown-app" "ruby" "3.4.4"
  test_version_detect "Python default version" "$TEST_DIR/unknown-app" "python" "3.12.8"
  test_version_detect "Go default version" "$TEST_DIR/unknown-app" "go" "1.25.0"
  test_version_detect "Rust default version" "$TEST_DIR/unknown-app" "rust" "1.92.0"
  test_version_detect "Scala default version" "$TEST_DIR/unknown-app" "scala" "3.5.2"
  test_version_detect "Kotlin default version" "$TEST_DIR/unknown-app" "kotlin" "2.1.0"
  test_version_detect "Elixir default version" "$TEST_DIR/unknown-app" "elixir" "1.18.4"
  test_version_detect "PHP default version" "$TEST_DIR/unknown-app" "php" "8.3"
}

# Main
main() {
  echo -e "${YELLOW}migetpacks Detect Test Suite${NC}\n"

  setup_fixtures
  run_tests
  cleanup_fixtures

  echo ""
  echo -e "${YELLOW}Test Results:${NC}"
  echo "  Tests run: $TESTS_RUN"
  echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"

  if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
    exit 1
  else
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
  fi
}

main
