#!/bin/bash
set -euo pipefail

# Create temporary directory for stubs and temporary file for GITHUB_OUTPUT & CURL_LOG
STUB_DIR=$(mktemp -d)
TEST_GITHUB_OUTPUT=$(mktemp)
CURL_LOG=$(mktemp)

cleanup() {
  rm -rf "$STUB_DIR" "$TEST_GITHUB_OUTPUT" "$CURL_LOG"
}
trap cleanup EXIT

# Create docker stub
cat <<'EOF' > "$STUB_DIR/docker"
#!/bin/bash
exit 0
EOF

# Create curl stub that logs invoked arguments and outputs a dummy GitHub release JSON
cat <<EOF > "$STUB_DIR/curl"
#!/bin/bash
echo "\$@" >> "$CURL_LOG"
echo '{"tag_name": "v1.0.0"}'
exit 0
EOF

chmod +x "$STUB_DIR/docker" "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"
export GITHUB_OUTPUT="$TEST_GITHUB_OUTPUT"
export CURL_LOG="$CURL_LOG"

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

    if ! grep -q "is not monitored via API. Falling back to OS package check." "$output_file"; then
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
run_mapping_test "cryptpad mapping" "cryptpad" "cryptpad/cryptpad" "v1.0.0"

# 9. nextcloud (STRIP_V=true)
run_mapping_test "nextcloud mapping" "nextcloud" "nextcloud/server" "1.0.0"

# 10. Unmonitored image fallback (unknown-app)
run_mapping_test "unknown-app unmonitored fallback" "unknown-app" "" ""

# 11. Registry path + tag input (ghcr.io/org/vaultwarden:v1.0.0)
run_mapping_test "registry path and tag mapping" "ghcr.io/org/vaultwarden:v1.0.0" "dani-garcia/vaultwarden" "1.0.0"

if [ "$FAILED" -ne 0 ]; then
  echo "Some tests failed."
  exit 1
else
  echo "All check_update.sh tests passed successfully!"
fi
