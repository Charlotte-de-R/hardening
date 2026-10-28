#!/bin/bash
set -euo pipefail

# Create temporary test directory
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Copy script to temporary directory
cp update_dockerfiles.sh "$TEST_DIR/"
chmod +x "$TEST_DIR/update_dockerfiles.sh"

# Navigate to test directory to simulate root
cd "$TEST_DIR"

# Create mock universal hardening snippet
mkdir -p templates
cat << 'MOCK_SNIPPET' > templates/universal_hardening.txt
# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---
echo "This is the mock universal snippet."
# --- COMMON HARDENING END ---
MOCK_SNIPPET

# Helper function to create a test Dockerfile
create_dockerfile() {
    local path=$1
    local content=$2
    mkdir -p "$(dirname "$path")"
    echo "$content" > "$path"
}

# 1. Setup mock targets mimicking the real script
# Expected list matches update_dockerfiles.sh
ALL_TARGETS=(
    "dockerfiles/immich-server/Dockerfile.hardened"
    "dockerfiles/immich-machine-learning/Dockerfile.hardened"
    "dockerfiles/immich-postgres/Dockerfile.hardened"
    "dockerfiles/mariadb/Dockerfile.hardened"
    "dockerfiles/vaultwarden/Dockerfile.hardened"
    "dockerfiles/crowdsec/Dockerfile.hardened"
    "dockerfiles/immich-redis/Dockerfile.hardened"
    "dockerfiles/socket-proxy/Dockerfile.hardened"
    "dockerfiles/tailscale/Dockerfile.hardened"
    "dockerfiles/promtail/Dockerfile.hardened"
    "dockerfiles/tetragon/Dockerfile.hardened"
    "dockerfiles/cryptpad/Dockerfile.hardened"
    "dockerfiles/portainer/Dockerfile.hardened"
)

# Standard mock content
MOCK_DOCKERFILE_CONTENT=$(cat << 'MOCK'
FROM alpine:latest
# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---
old hardening content
# --- COMMON HARDENING END ---
CMD ["echo", "test"]
MOCK
)

# Create all targets with standard mock content
for target in "${ALL_TARGETS[@]}"; do
    create_dockerfile "$target" "$MOCK_DOCKERFILE_CONTENT"
done

# Initialize a counter for failed tests
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
    ./update_dockerfiles.sh "$@" >"$output_file" 2>&1
    actual_code=$?
    set -e

    if [ "$actual_code" -ne "$expected_code" ]; then
        echo "FAILED (Expected exit code $expected_code, got $actual_code)"
        cat "$output_file"
        FAILED=1
        rm -f "$output_file"
        return
    fi

    if [ -n "$expected_output_pattern" ] && ! grep -q "$expected_output_pattern" "$output_file"; then
        echo "FAILED (Output did not contain pattern '$expected_output_pattern')"
        cat "$output_file"
        FAILED=1
        rm -f "$output_file"
        return
    fi

    echo "PASSED"
    rm -f "$output_file"
}

# --- Test Cases ---

# Test 1: Invalid Argument (Hyphen)
run_test "Invalid Argument (-invalid)" 1 "Error: Invalid target '-invalid'. Target cannot start with a hyphen." -invalid

# Test 2: Invalid Argument (--help)
run_test "Invalid Argument (--help)" 1 "Error: Invalid target '--help'. Target cannot start with a hyphen." --help

# Test 3: Non-existent file
run_test "Non-existent file" 0 "⚠️  File not found: dockerfiles/non-existent/Dockerfile.hardened (Skipping)" dockerfiles/non-existent/Dockerfile.hardened

# Test 4: Single file
create_dockerfile "dockerfiles/single-test/Dockerfile.hardened" "$MOCK_DOCKERFILE_CONTENT"
run_test "Single file update" 0 "✅ Updated: dockerfiles/single-test/Dockerfile.hardened" dockerfiles/single-test/Dockerfile.hardened

# Verify content of single file
if ! grep -q "This is the mock universal snippet." "dockerfiles/single-test/Dockerfile.hardened"; then
    echo "FAILED: Content was not updated in single file."
    FAILED=1
fi
if grep -q "old hardening content" "dockerfiles/single-test/Dockerfile.hardened"; then
    echo "FAILED: Old content was not removed in single file."
    FAILED=1
fi

# Test 5: Directory argument
create_dockerfile "dockerfiles/dir-test/Dockerfile.hardened" "$MOCK_DOCKERFILE_CONTENT"
create_dockerfile "dockerfiles/dir-test/ignore.txt" "Do not touch this"
cp "dockerfiles/dir-test/ignore.txt" "dockerfiles/dir-test/ignore.txt.backup"
run_test "Directory argument update" 0 "✅ Updated: dockerfiles/dir-test/Dockerfile.hardened" dockerfiles/dir-test

# Verify content of directory file
if ! grep -q "This is the mock universal snippet." "dockerfiles/dir-test/Dockerfile.hardened"; then
    echo "FAILED: Content was not updated in directory test."
    FAILED=1
fi
if ! cmp -s "dockerfiles/dir-test/ignore.txt" "dockerfiles/dir-test/ignore.txt.backup"; then
    echo "FAILED: Non-target file was modified in directory test."
    FAILED=1
fi

# Test 6: Missing hardening tags
MOCK_MISSING_TAGS=$(cat << 'MOCK'
FROM alpine:latest
RUN echo "No tags here"
CMD ["echo", "test"]
MOCK
)
create_dockerfile "dockerfiles/no-tags/Dockerfile.hardened" "$MOCK_MISSING_TAGS"
cp "dockerfiles/no-tags/Dockerfile.hardened" "dockerfiles/no-tags/Dockerfile.hardened.backup"
run_test "Missing hardening tags" 0 "✅ Updated: dockerfiles/no-tags/Dockerfile.hardened" dockerfiles/no-tags/Dockerfile.hardened

# Verify content of no-tags file (should remain exactly unchanged)
if ! cmp -s "dockerfiles/no-tags/Dockerfile.hardened" "dockerfiles/no-tags/Dockerfile.hardened.backup"; then
    echo "FAILED: Missing tags file was modified despite having no tags."
    FAILED=1
fi

# Test 7: Multiple hardening tags
MOCK_MULTIPLE_TAGS=$(cat << 'MOCK'
FROM alpine:latest
# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---
old hardening 1
# --- COMMON HARDENING END ---
RUN echo "Middle"
# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---
old hardening 2
# --- COMMON HARDENING END ---
CMD ["echo", "test"]
MOCK
)
create_dockerfile "dockerfiles/multiple-tags/Dockerfile.hardened" "$MOCK_MULTIPLE_TAGS"
run_test "Multiple hardening tags" 0 "✅ Updated: dockerfiles/multiple-tags/Dockerfile.hardened" dockerfiles/multiple-tags/Dockerfile.hardened

# Verify content of multiple-tags file
count=$(grep -c "This is the mock universal snippet." "dockerfiles/multiple-tags/Dockerfile.hardened" || true)
if [ "$count" -ne 2 ]; then
    echo "FAILED: Multiple tags file did not replace all blocks. Expected 2, found $count."
    cat "dockerfiles/multiple-tags/Dockerfile.hardened"
    FAILED=1
fi
if grep -q "old hardening 1" "dockerfiles/multiple-tags/Dockerfile.hardened" || grep -q "old hardening 2" "dockerfiles/multiple-tags/Dockerfile.hardened"; then
    echo "FAILED: Old content was not removed in multiple-tags file."
    FAILED=1
fi
if ! grep -q 'RUN echo "Middle"' "dockerfiles/multiple-tags/Dockerfile.hardened"; then
    echo "FAILED: Intermediate content was lost in multiple-tags file."
    FAILED=1
fi
if ! grep -q 'FROM alpine:latest' "dockerfiles/multiple-tags/Dockerfile.hardened" || ! grep -q 'CMD \["echo", "test"\]' "dockerfiles/multiple-tags/Dockerfile.hardened"; then
    echo "FAILED: Top/bottom file boundaries were corrupted in multiple-tags file."
    FAILED=1
fi

# Test 8: Empty hardening block
MOCK_EMPTY_TAGS=$(cat << 'MOCK'
FROM alpine:latest
# --- COMMON HARDENING START (DO NOT EDIT MANUALLY) ---
# --- COMMON HARDENING END ---
CMD ["echo", "test"]
MOCK
)
create_dockerfile "dockerfiles/empty-tags/Dockerfile.hardened" "$MOCK_EMPTY_TAGS"
run_test "Empty hardening tags" 0 "✅ Updated: dockerfiles/empty-tags/Dockerfile.hardened" dockerfiles/empty-tags/Dockerfile.hardened

if ! grep -q "This is the mock universal snippet." "dockerfiles/empty-tags/Dockerfile.hardened"; then
    echo "FAILED: Content was not updated in empty tags test."
    FAILED=1
fi


# Test 9: Repeated processing (Idempotency)
cp "dockerfiles/empty-tags/Dockerfile.hardened" "dockerfiles/empty-tags/Dockerfile.hardened.backup"
run_test "Repeated processing (Idempotency)" 0 "✅ Updated: dockerfiles/empty-tags/Dockerfile.hardened" dockerfiles/empty-tags/Dockerfile.hardened
# Verify content hasn't changed at all
if ! cmp -s "dockerfiles/empty-tags/Dockerfile.hardened" "dockerfiles/empty-tags/Dockerfile.hardened.backup"; then
    echo "FAILED: Repeated processing modified the file."
    diff "dockerfiles/empty-tags/Dockerfile.hardened" "dockerfiles/empty-tags/Dockerfile.hardened.backup" || true
    FAILED=1
fi


# Test 10: Run with no arguments (All targets)
run_test "No arguments (All targets)" 0 "🔄 Injecting UNIVERSAL hardening templates..."

# Verify one of the default targets was updated
if ! grep -q "This is the mock universal snippet." "dockerfiles/immich-server/Dockerfile.hardened"; then
    echo "FAILED: Default target (immich-server) was not updated when running with no arguments."
    FAILED=1
fi
if ! grep -q "This is the mock universal snippet." "dockerfiles/vaultwarden/Dockerfile.hardened"; then
    echo "FAILED: Default target (vaultwarden) was not updated when running with no arguments."
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "Some update_dockerfiles.sh tests failed."
    exit 1
fi

echo "All update_dockerfiles.sh tests passed successfully!"
exit 0
