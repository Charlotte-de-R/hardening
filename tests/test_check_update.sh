#!/bin/bash
set -euo pipefail

# Create temporary directory for stubs and temporary file for GITHUB_OUTPUT
STUB_DIR=$(mktemp -d)
TEST_GITHUB_OUTPUT=$(mktemp)

cleanup() {
  rm -rf "$STUB_DIR" "$TEST_GITHUB_OUTPUT"
}
trap cleanup EXIT

# Create docker stub
cat <<'EOF' > "$STUB_DIR/docker"
#!/bin/bash
exit 0
EOF

# Create curl stub
cat <<'EOF' > "$STUB_DIR/curl"
#!/bin/bash
echo '{"tag_name": "v1.0.0"}'
exit 0
EOF

chmod +x "$STUB_DIR/docker" "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"
export GITHUB_OUTPUT="$TEST_GITHUB_OUTPUT"

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

# Test 1: No argument provided
run_test "No argument provided" 1 "Usage:"

# Test 2: Argument starting with hyphen '-h'
run_test "Hyphen argument -h" 1 "Invalid image name" "-h"

# Test 3: Argument starting with hyphen '--help'
run_test "Hyphen argument --help" 1 "Invalid image name" "--help"

# Test 4: Argument starting with hyphen '-invalid'
run_test "Hyphen argument -invalid" 1 "Invalid image name" "-invalid"

# Test 5: Valid image name
run_test "Valid image name" 0 "Checking updates for: ghcr.io/example/owner/repo/image:tag" "ghcr.io/example/owner/repo/image:tag"

if [ "$FAILED" -ne 0 ]; then
  echo "Some tests failed."
  exit 1
else
  echo "All check_update.sh argument validation tests passed successfully!"
fi
