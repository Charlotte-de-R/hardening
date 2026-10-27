#!/bin/bash
set -euo pipefail

# Create temporary directory for stubs and temporary file for GITHUB_OUTPUT & CURL_LOG
STUB_DIR=$(mktemp -d)
TEST_GITHUB_OUTPUT=$(mktemp)
CURL_LOG=$(mktemp)
DOCKER_LOG=$(mktemp)

cleanup() {
  rm -rf "$STUB_DIR" "$TEST_GITHUB_OUTPUT" "$CURL_LOG" "$DOCKER_LOG"
}
trap cleanup EXIT

# Create docker stub
cat <<'EOF' > "$STUB_DIR/docker"
#!/bin/bash
echo "$@" >> "$DOCKER_LOG"
if [ "${1:-}" = "pull" ] && [ -n "${DOCKER_PULL_EXIT_CODE:-}" ]; then
  exit "$DOCKER_PULL_EXIT_CODE"
fi
if [ "${1:-}" = "run" ]; then
  if [ -n "${DOCKER_RUN_STDERR:-}" ]; then
    printf "%s\n" "$DOCKER_RUN_STDERR" >&2
  fi
  if [ -n "${DOCKER_RUN_OUTPUT:-}" ]; then
    printf "%s\n" "$DOCKER_RUN_OUTPUT"
  fi
  if [ -n "${DOCKER_RUN_EXIT_CODE:-}" ]; then
    exit "$DOCKER_RUN_EXIT_CODE"
  fi
fi
exit 0
EOF

# Create curl stub that returns endpoint-appropriate fixtures.
cat <<'EOF' > "$STUB_DIR/curl"
#!/bin/bash
echo "$@" >> "$CURL_LOG"
case "$*" in
  *download.docker.com/linux/static/stable/x86_64/*)
    printf '%s\n' '<a href="docker-28.0.0.tgz">docker-28.0.0.tgz</a>' '<a href="docker-27.5.1.tgz">docker-27.5.1.tgz</a>'
    ;;
  *hub.docker.com/v2/repositories/cryptpad/cryptpad/tags*)
    echo '{"results":[{"name":"version-2026.10.0"},{"name":"version-2026.9.0"}]}'
    ;;
  *hub.docker.com/v2/repositories/library/mariadb/tags*)
    echo '{"results":[{"name":"12.0.1"},{"name":"12.1.0"}]}'
    ;;
  *api.github.com/repos/*)
    echo '{"tag_name": "v1.0.0"}'
    ;;
  *)
    echo '{}'
    ;;
esac
exit 0
EOF

chmod +x "$STUB_DIR/docker" "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"
export GITHUB_OUTPUT="$TEST_GITHUB_OUTPUT"
export CURL_LOG="$CURL_LOG"
export DOCKER_LOG="$DOCKER_LOG"

FAILED=0

run_test() {
  local test_name="$1"
  local expected_code="$2"
  local expected_output_pattern="$3"
  shift 3

  echo -n "Running test: $test_name... "
  local output_file
  output_file=$(mktemp)
  local actual_code=0

  set +e
  ./check_update.sh "$@" >"$output_file" 2>&1
  actual_code=$?
  set -e

  if [ "$actual_code" -ne "$expected_code" ]; then
    echo "FAILED (Expected exit code $expected_code, got $actual_code)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if ! grep -q "$expected_output_pattern" "$output_file"; then
    echo "FAILED (Output did not contain pattern '$expected_output_pattern')"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  echo "PASSED"
  rm -f "$output_file"
}

run_mapping_test() {
  local test_name="$1"
  local image_arg="$2"
  local expected_repo="$3"
  local expected_version="$4" # Expected latest_version in GITHUB_OUTPUT ("" if not expecting API call)

  echo -n "Running mapping test: $test_name... "

  # Reset temporary logs
  > "$CURL_LOG"
  > "$TEST_GITHUB_OUTPUT"

  local output_file
  output_file=$(mktemp)
  local actual_code=0

  set +e
  ./check_update.sh "$image_arg" >"$output_file" 2>&1
  actual_code=$?
  set -e

  if [ "$actual_code" -ne 0 ]; then
    echo "FAILED (Expected exit code 0, got $actual_code)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if [ -n "$expected_repo" ]; then
    local expected_url="https://api.github.com/repos/${expected_repo}/releases/latest"
    if ! grep -q "$expected_url" "$CURL_LOG"; then
      echo "FAILED (curl was not called with expected API URL: $expected_url)"
      echo "--- curl log ---"
      cat "$CURL_LOG"
      echo "--- output log ---"
      cat "$output_file"
      FAILED=1
      rm -f "$output_file"
      return
    fi

    if [ -n "$expected_version" ]; then
      local expected_output="latest_version=${expected_version}"
      if ! grep -q "$expected_output" "$TEST_GITHUB_OUTPUT"; then
        echo "FAILED (GITHUB_OUTPUT did not contain '$expected_output')"
        echo "--- GITHUB_OUTPUT ---"
        cat "$TEST_GITHUB_OUTPUT"
        FAILED=1
        rm -f "$output_file"
        return
      fi
    fi
  else
    # If no REPO expected, verify curl was NOT called
    if [ -s "$CURL_LOG" ]; then
      echo "FAILED (curl was called when no REPO was expected)"
      cat "$CURL_LOG"
      FAILED=1
      rm -f "$output_file"
      return
    fi

    if ! grep -q "is not monitored via the GitHub API." "$output_file"; then
      echo "FAILED (Fallback message not found in output)"
      cat "$output_file"
      FAILED=1
      rm -f "$output_file"
      return
    fi
  fi

  echo "PASSED"
  rm -f "$output_file"
}

# --- Existing CLI argument tests ---
run_test "No argument provided" 1 "Usage:"
run_test "Hyphen argument -h" 1 "Invalid image name" "-h"
run_test "Hyphen argument --help" 1 "Invalid image name" "--help"
run_test "Hyphen argument -invalid" 1 "Invalid image name" "-invalid"
run_test "Valid image name" 0 "Checking updates for: ghcr.io/example/owner/repo/image:tag" "ghcr.io/example/owner/repo/image:tag"

run_test "Invalid reference format - space prefix" 1 "Invalid image reference format ' -v /tmp:/tmp alpine'" " -v /tmp:/tmp alpine"
run_test "Invalid reference format - option injection" 1 "Invalid image name '--entrypoint=bash'" "--entrypoint=bash"
run_test "Invalid reference format - command separator" 1 "Invalid image reference format 'alpine;echo'" "alpine;echo"
run_test "Invalid reference format - shell interpolation" 1 "Invalid image reference format 'alpine\$(echo hacked)'" 'alpine$(echo hacked)'
run_test "Invalid reference format - newline" 1 "Invalid image reference format" "alpine"$'\n'"echo"
run_test "Invalid reference format - shell background" 1 "Invalid image reference format 'alpine & echo'" "alpine & echo"
run_test "Invalid reference format - hyphen prefix bypass" 1 "Invalid image name '-alpine'" "-alpine"
run_test "Valid reference format - standard" 0 "Checking updates for: ubuntu" "ubuntu"
run_test "Valid reference format - digest" 0 "Checking updates for: alpine@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" "alpine@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
run_test "Valid reference format - custom port" 0 "Checking updates for: localhost:5000/my-image:latest" "localhost:5000/my-image:latest"

# --- Repository mapping tests ---
# 1. tailscale (STRIP_V=false)
run_mapping_test "tailscale mapping" "tailscale" "tailscale/tailscale" "v1.0.0"

# 2. crowdsec (STRIP_V=false)
run_mapping_test "crowdsec mapping" "crowdsec" "crowdsecurity/crowdsec" "v1.0.0"

# 3. vaultwarden (STRIP_V=true)
run_mapping_test "vaultwarden mapping" "vaultwarden" "dani-garcia/vaultwarden" "1.0.0"

# 4. immich-server (STRIP_V=false)
run_mapping_test "immich-server mapping" "immich-server" "immich-app/immich" "v1.0.0"

# 5. immich-machine-learning (STRIP_V=false)
run_mapping_test "immich-machine-learning mapping" "immich-machine-learning" "immich-app/immich" "v1.0.0"

# 6. tetragon (STRIP_V=false)
run_mapping_test "tetragon mapping" "cilium/tetragon" "cilium/tetragon" "v1.0.0"

# 7. portainer (STRIP_V=true)
run_mapping_test "portainer mapping" "portainer" "portainer/portainer" "1.0.0"

# 8. cryptpad (STRIP_V=false)
run_mapping_test "cryptpad published Docker version" "cryptpad" "cryptpad/cryptpad" "2026.10.0"

# 9. nextcloud (STRIP_V=true)
run_mapping_test "nextcloud minimum version" "nextcloud" "nextcloud/server" "34.0.4"

# 10. Unmonitored image fallback (unknown-app)
run_mapping_test "unknown-app unmonitored fallback" "unknown-app" "" ""

# 11. Registry path + tag input (ghcr.io/org/vaultwarden:v1.0.0)
run_mapping_test "registry path and tag mapping" "ghcr.io/org/vaultwarden:v1.0.0" "dani-garcia/vaultwarden" "1.0.0"


# --- Docker pull failure tests ---
run_docker_pull_failure_test() {
  local test_name="$1"
  local image_arg="$2"
  local expected_latest_version="$3" # Expected latest_version in GITHUB_OUTPUT ("" if not expecting it)

  echo -n "Running docker pull failure test: $test_name... "

  # Reset temporary logs
  > "$CURL_LOG"
  > "$DOCKER_LOG"
  > "$TEST_GITHUB_OUTPUT"

  local output_file
  output_file=$(mktemp)
  local actual_code=0
  local expected_code=0
  if [ "$image_arg" = "unknown-app" ]; then
    expected_code=1
  fi

  # Override DOCKER_PULL_EXIT_CODE only for this execution
  set +e
  DOCKER_PULL_EXIT_CODE=1 ./check_update.sh "$image_arg" >"$output_file" 2>&1
  actual_code=$?
  set -e

  if [ "$actual_code" -ne "$expected_code" ]; then
    echo "FAILED (Expected exit code $expected_code, got $actual_code)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if [ "$image_arg" = "unknown-app" ]; then
    if ! grep -q "Cannot verify an upstream version for missing image unknown-app" "$output_file"; then
      echo "FAILED (Fail-closed message not found)"
      cat "$output_file"
      FAILED=1
      rm -f "$output_file"
      return
    fi
    if [ -s "$CURL_LOG" ]; then
      echo "FAILED (curl was called for an unregistered missing image)"
      cat "$CURL_LOG"
      FAILED=1
      rm -f "$output_file"
      return
    fi
    echo "PASSED"
    rm -f "$output_file"
    return
  fi

  if ! grep -q "A build may be required." "$output_file"; then
    echo "FAILED (Expected missing image warning not found in output)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if ! grep -Fxq "needs_update=true" "$TEST_GITHUB_OUTPUT"; then
    echo "FAILED (needs_update=true not found in GITHUB_OUTPUT)"
    cat "$TEST_GITHUB_OUTPUT"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if grep -Fxq "needs_update=false" "$TEST_GITHUB_OUTPUT"; then
    echo "FAILED (needs_update=false was incorrectly found in GITHUB_OUTPUT)"
    cat "$TEST_GITHUB_OUTPUT"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  # Check that docker run was not called
  if grep -q "^run " "$DOCKER_LOG"; then
    echo "FAILED (docker run was incorrectly called)"
    cat "$DOCKER_LOG"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if [ -z "$expected_latest_version" ]; then
    # If no version expected, we expect no curl to be called
    if [ -s "$CURL_LOG" ]; then
      echo "FAILED (curl was called but no API call was expected)"
      cat "$CURL_LOG"
      FAILED=1
      rm -f "$output_file"
      return
    fi
  else
    local expected_output="latest_version=${expected_latest_version}"
    if ! grep -Fxq "$expected_output" "$TEST_GITHUB_OUTPUT"; then
      echo "FAILED (expected $expected_output not found in GITHUB_OUTPUT)"
      cat "$TEST_GITHUB_OUTPUT"
      FAILED=1
      rm -f "$output_file"
      return
    fi
  fi

  echo "PASSED"
  rm -f "$output_file"
}

# A. Unregistered image + docker pull failure
run_docker_pull_failure_test "Unregistered image + docker pull failure" "unknown-app" ""

# B. Registered image + docker pull failure + GitHub API success
run_docker_pull_failure_test "Registered image (vaultwarden) + docker pull failure" "vaultwarden" "1.0.0"

# C. Registered image + docker pull failure + GitHub API failure
run_docker_pull_failure_api_fail_test() {
  local test_name="Registered image (vaultwarden) + docker pull failure + GitHub API failure"
  echo -n "Running docker pull failure test: $test_name... "

  # Reset temporary logs
  > "$CURL_LOG"
  > "$DOCKER_LOG"
  > "$TEST_GITHUB_OUTPUT"

  # Override curl stub temporarily
  cat <<'EOF' > "$STUB_DIR/curl"
#!/bin/bash
echo "$@" >> "$CURL_LOG"
echo '{"tag_name": "null"}'
exit 0
EOF

  local output_file
  output_file=$(mktemp)
  local actual_code=0

  set +e
  DOCKER_PULL_EXIT_CODE=1 ./check_update.sh "vaultwarden" >"$output_file" 2>&1
  actual_code=$?
  set -e

  # Restore curl stub
  cat <<'EOF' > "$STUB_DIR/curl"
#!/bin/bash
echo "$@" >> "$CURL_LOG"
echo '{"tag_name": "v1.0.0"}'
exit 0
EOF

  if [ "$actual_code" -ne 1 ]; then
    echo "FAILED (Expected fail-closed exit code 1, got $actual_code)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if ! grep -q "Cannot resolve an upstream application version for missing image vaultwarden" "$output_file"; then
    echo "FAILED (Expected fail-closed version-resolution error not found)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if ! grep -Fxq "needs_update=true" "$TEST_GITHUB_OUTPUT"; then
    echo "FAILED (needs_update=true not found in GITHUB_OUTPUT)"
    cat "$TEST_GITHUB_OUTPUT"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if grep -Fxq "needs_update=false" "$TEST_GITHUB_OUTPUT"; then
    echo "FAILED (needs_update=false was incorrectly found in GITHUB_OUTPUT)"
    cat "$TEST_GITHUB_OUTPUT"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  # Fail closed: do not continue into OS checks after upstream version resolution fails.
  if grep -q "^run " "$DOCKER_LOG"; then
    echo "FAILED (docker run was incorrectly called after version resolution failed)"
    cat "$DOCKER_LOG"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  echo "PASSED"
  rm -f "$output_file"
}
run_docker_pull_failure_api_fail_test

# --- OS package check tests ---
run_os_check_test() {
  local test_name="$1"
  local image_arg="$2"
  local expected_needs_update="$3"
  local check_message_pattern="$4"

  echo -n "Running OS package check test: $test_name... "

  # Reset temporary logs
  > "$CURL_LOG"
  > "$DOCKER_LOG"
  > "$TEST_GITHUB_OUTPUT"

  local output_file
  output_file=$(mktemp)
  local actual_code=0

  set +e
  ./check_update.sh "$image_arg" >"$output_file" 2>&1
  actual_code=$?
  set -e

  if [ "$actual_code" -ne 0 ]; then
    echo "FAILED (Expected exit code 0, got $actual_code)"
    cat "$output_file"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  # Check that docker run was called
  if ! grep -q "^run " "$DOCKER_LOG"; then
    echo "FAILED (docker run was not called)"
    cat "$DOCKER_LOG"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  # Ensure curl was NOT called for unknown images
  if [ -s "$CURL_LOG" ]; then
    echo "FAILED (curl was called but no API call was expected for unknown image)"
    cat "$CURL_LOG"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if [ -n "$check_message_pattern" ]; then
    if ! grep -q "$check_message_pattern" "$output_file"; then
      echo "FAILED (Expected message matching '$check_message_pattern' not found in output)"
      cat "$output_file"
      FAILED=1
      rm -f "$output_file"
      return
    fi
  fi

  local output_value="needs_update=${expected_needs_update}"
  local inverse_value="needs_update=true"
  if [ "$expected_needs_update" = "true" ]; then
    inverse_value="needs_update=false"
  fi

  if ! grep -Fxq "$output_value" "$TEST_GITHUB_OUTPUT"; then
    echo "FAILED ($output_value not found in GITHUB_OUTPUT)"
    cat "$TEST_GITHUB_OUTPUT"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  if grep -Fxq "$inverse_value" "$TEST_GITHUB_OUTPUT"; then
    echo "FAILED ($inverse_value was incorrectly found in GITHUB_OUTPUT)"
    cat "$TEST_GITHUB_OUTPUT"
    FAILED=1
    rm -f "$output_file"
    return
  fi

  echo "PASSED"
  rm -f "$output_file"
}

# A. Empty output (exit 0) -> needs_update=false
DOCKER_RUN_OUTPUT="" DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Empty output (exit 0)" "unknown-app" "false" "Image OS is up-to-date"

# B. Whitespace-only output (exit 0) -> needs_update=false
DOCKER_RUN_OUTPUT="
  " DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Whitespace-only output (exit 0)" "unknown-app" "false" "Image OS is up-to-date"

# C. Alpine style updates (exit 0) -> needs_update=true
DOCKER_RUN_OUTPUT="libssl3-3.1.4-r0" DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Alpine style updates (exit 0)" "unknown-app" "true" "OS updates detected"

# D. Debian Inst lines (exit 0) -> needs_update=true
DOCKER_RUN_OUTPUT="Inst bash [5.0-6ubuntu1.1] (5.0-6ubuntu1.2 Ubuntu:20.04/focal-updates [amd64])" DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Debian Inst lines (exit 0)" "unknown-app" "true" "OS updates detected"

# E. Debian Conf lines (exit 0) -> needs_update=true
DOCKER_RUN_OUTPUT="Conf bash (5.0-6ubuntu1.2 Ubuntu:20.04/focal-updates [amd64])" DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Debian Conf lines (exit 0)" "unknown-app" "true" "OS updates detected"

# F. executable file not found in stderr (exit non-zero) -> skipped, needs_update=false
DOCKER_RUN_STDERR="docker: Error response from daemon: OCI runtime create failed: container_linux.go:349: starting container process caused \"exec: \\\"sh\\\": executable file not found in \$PATH\": unknown." DOCKER_RUN_EXIT_CODE=127 run_os_check_test "executable file not found in stderr" "unknown-app" "false" "Image has no shell"

# G. Only filtered strings (fetch http, WARNING) -> needs_update=false
DOCKER_RUN_OUTPUT="fetch http://dl-cdn.alpinelinux.org/alpine/v3.18/main/x86_64/APKINDEX.tar.gz
WARNING: Ignoring APKINDEX.d4f...: No such file or directory" DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Only filtered strings" "unknown-app" "false" "Image OS is up-to-date"

# H. Mixed filtered strings and valid updates -> needs_update=true
DOCKER_RUN_OUTPUT="fetch http://dl-cdn.alpinelinux.org/alpine/v3.18/main/x86_64/APKINDEX.tar.gz
WARNING: Ignoring APKINDEX.d4f...: No such file or directory
libssl3-3.1.4-r0" DOCKER_RUN_EXIT_CODE=0 run_os_check_test "Mixed filtered strings and valid updates" "unknown-app" "true" "OS updates detected"

# I. Non-zero exit code with unknown error (characterization test)
# Known limitation: check_update.sh doesn't strictly check the docker run exit code unless it matches "executable file not found".
# Any other error output that contains alphanumeric characters might incorrectly trigger "needs_update=true".
DOCKER_RUN_STDERR="docker: Error response from daemon: some random error" DOCKER_RUN_EXIT_CODE=1 run_os_check_test "Non-zero exit code with unknown error" "unknown-app" "true" "OS updates detected"

# J. Non-zero exit code with empty output (characterization test)
# Known limitation: Empty output with non-zero exit code still results in needs_update=false.
DOCKER_RUN_OUTPUT="" DOCKER_RUN_EXIT_CODE=1 run_os_check_test "Non-zero exit code with empty output" "unknown-app" "false" "Image OS is up-to-date"

if [ "$FAILED" -ne 0 ]; then
  echo "Some tests failed."
  exit 1
else
  echo "All check_update.sh tests passed successfully!"
fi
