
#!/usr/bin/env bash
# Usage: ./check_update.sh <target_image>

set -o pipefail

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <target_image>"
  exit 1
fi

if [[ "$1" == -* ]]; then
  echo "ERROR: Invalid image name '$1'."
  exit 1
fi

validate_docker_image() {
  local image="$1"
  [[ -n "$image" ]] || return 1

  # Docker reference grammar: registry names are dotted hostnames, localhost,
  # hostnames with an explicit port, or bracketed IPv6 literals.
  local LABEL='[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?'
  local DOMAIN_W_DOT="${LABEL}(\.${LABEL})+"
  local IPV6_DOMAIN='\[[0-9a-fA-F:]+\]'
  local DOMAIN_HOST="(${DOMAIN_W_DOT}|localhost)(:[0-9]+)?|${LABEL}:[0-9]+|${IPV6_DOMAIN}(:[0-9]+)?"
  local DOMAIN="(${DOMAIN_HOST})/"
  local REPO_COMP='[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*'
  # Tags start with an ASCII alphanumeric or underscore; max 128 chars.
  local TAG='(:[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127})'
  # Digest algorithm grammar plus a hexadecimal encoded digest.
  local DIGEST='(@[a-zA-Z][a-zA-Z0-9]*([-_+.][a-zA-Z][a-zA-Z0-9]*)*:[a-fA-F0-9]{32,})'
  local FULL_REGEX="^(${DOMAIN})?${REPO_COMP}(/${REPO_COMP})*(${TAG}|${DIGEST}|${TAG}${DIGEST})?$"

  [[ "$image" =~ $FULL_REGEX ]] || return 1

  # Bash regex cannot validate IPv6 semantics. Use Python's standard library
  # for bracketed literals so malformed forms such as [::::] are rejected.
  if [[ "$image" =~ ^\[([^]]+)\](:[0-9]+)?/ ]]; then
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${BASH_REMATCH[1]}" <<'PY' >/dev/null 2>&1 || return 1
import ipaddress
import sys
ipaddress.IPv6Address(sys.argv[1])
PY
  fi
  return 0
}

if ! validate_docker_image "$1"; then
  echo "ERROR: Invalid image reference format '$1'."
  exit 1
fi

IMAGE="$1"
IMAGE_NAME="${IMAGE##*/}"
IMAGE_NAME="${IMAGE_NAME%%:*}"

write_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

version_lt() {
  local a="${1#v}"
  local b="${2#v}"

  [[ -n "$a" && -n "$b" && "$a" != "$b" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" == "$a" ]]
}

version_gt() {
  version_lt "$2" "$1"
}

echo "Checking updates for: $IMAGE (Name: $IMAGE_NAME)..."

# --------------------------------------------------
# 1. Inspect the currently published hardened image
# --------------------------------------------------
MISSING_IMAGE=false

if docker pull "$IMAGE" >/dev/null 2>&1; then
  :
else
  echo "WARNING: Could not pull the published image."
  echo "A build may be required."
  MISSING_IMAGE=true
  write_output "needs_update" "true"
fi

CURRENT_VER=""
CURRENT_DOCKER_CLI_VER=""
DOCKER_CLI_UPDATE=false

if [[ "$MISSING_IMAGE" == false ]]; then
  CURRENT_VER=$(
    docker image inspect \
      --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
      "$IMAGE" 2>/dev/null || true
  )

  if [[ "$CURRENT_VER" == "<no value>" || "$CURRENT_VER" == "null" ]]; then
    CURRENT_VER=""
  fi
  CURRENT_DOCKER_CLI_VER=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.docker-cli-version" }}' "$IMAGE" 2>/dev/null || true)
  [[ "$CURRENT_DOCKER_CLI_VER" == "<no value>" || "$CURRENT_DOCKER_CLI_VER" == "null" ]] && CURRENT_DOCKER_CLI_VER=""
fi

if [[ "$IMAGE_NAME" == "immich-server" || "$IMAGE_NAME" == "immich-machine-learning" ]]; then
  case "$CURRENT_VER" in
    release|latest)
      echo "Floating Immich label '$CURRENT_VER' is not a comparable version; scheduling version migration."
      CURRENT_VER=""
      ;;
  esac
fi

echo "Current image version: ${CURRENT_VER:-unknown}"

# --------------------------------------------------
# 2. Map image names to upstream repositories
# --------------------------------------------------
REPO=""
STRIP_V=false

case "$IMAGE_NAME" in
  tailscale)
    REPO="tailscale/tailscale"
    ;;
  crowdsec)
    REPO="crowdsecurity/crowdsec"
    ;;
  vaultwarden)
    REPO="dani-garcia/vaultwarden"
    STRIP_V=true
    ;;
  immich-server|immich-machine-learning)
    REPO="immich-app/immich"
    ;;
  tetragon)
    REPO="cilium/tetragon"
    ;;
  portainer)
    REPO="portainer/portainer"
    STRIP_V=true
    ;;
  cryptpad)
    REPO="cryptpad/cryptpad"
    ;;
  nextcloud)
    REPO="nextcloud/server"
    STRIP_V=true
    ;;
  mariadb)
    # Resolve a published Docker Hub tag dynamically; retain the current major line.
    ;;
esac

# --------------------------------------------------
# 3. Resolve the upstream application version
# --------------------------------------------------
LATEST_VER=""
DESIRED_VER=""

if [[ "$IMAGE_NAME" == "mariadb" ]]; then
  echo "Resolving latest MariaDB tag within the current major version..."
  CURRENT_MAJOR="${CURRENT_VER%%.*}"
  if [[ ! "$CURRENT_MAJOR" =~ ^[0-9]+$ ]]; then CURRENT_MAJOR="12"; fi
  TAGS_JSON=$(curl -fsSL --retry 2 --connect-timeout 10 "https://hub.docker.com/v2/repositories/library/mariadb/tags?page_size=100&name=${CURRENT_MAJOR}.") || { echo "ERROR: Cannot retrieve MariaDB tags"; exit 1; }
  DESIRED_VER=$(jq -r '.results[]?.name | select(test("^'"$CURRENT_MAJOR"'\\.[0-9]+\\.[0-9]+$"))' <<< "$TAGS_JSON" | sort -Vu | tail -n 1)
  if [[ -z "$DESIRED_VER" ]]; then echo "ERROR: No compatible MariaDB tag found for major $CURRENT_MAJOR"; exit 1; fi
  write_output "latest_version" "$DESIRED_VER"
  if [[ "$MISSING_IMAGE" == true || -z "$CURRENT_VER" || "$DESIRED_VER" != "$CURRENT_VER" ]]; then
    echo "MariaDB update candidate: ${CURRENT_VER:-unknown} -> $DESIRED_VER (major line $CURRENT_MAJOR only)"
    write_output "needs_update" "true"
    exit 0
  fi
elif [[ -n "$REPO" ]]; then
  if [[ "$IMAGE_NAME" == "portainer" ]]; then
    echo "Resolving latest Docker CLI static binary version..."
    DOCKER_INDEX=$(curl -fsSL --retry 2 --connect-timeout 10 "https://download.docker.com/linux/static/stable/x86_64/") || { echo "ERROR: Cannot retrieve Docker CLI release index"; exit 1; }
    DOCKER_CLI_VER=$(grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' <<< "$DOCKER_INDEX" | sed -E 's/^docker-//; s/\.tgz$//' | sort -Vu | tail -n 1)
    if [[ ! "$DOCKER_CLI_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "ERROR: Could not resolve valid Docker CLI version"; exit 1; fi
    write_output "docker_cli_version" "$DOCKER_CLI_VER"
    echo "Resolved Docker CLI version: $DOCKER_CLI_VER"
    if [[ "$MISSING_IMAGE" == true || -z "$CURRENT_DOCKER_CLI_VER" || "$CURRENT_DOCKER_CLI_VER" != "$DOCKER_CLI_VER" ]]; then
      DOCKER_CLI_UPDATE=true
    fi
  fi

  echo "Fetching latest release for $REPO..."

  CURL_OPTS=(
    -fsSL
    --retry 2
    --connect-timeout 10
  )

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_OPTS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  RAW_TAG=$(
    curl "${CURL_OPTS[@]}" \
      "https://api.github.com/repos/${REPO}/releases/latest" |
      jq -r '.tag_name // empty' 2>/dev/null || true
  )

  if [[ -z "$RAW_TAG" ]]; then
    RAW_TAG=$(
      curl "${CURL_OPTS[@]}" \
        "https://api.github.com/repos/${REPO}/tags?per_page=1" |
        jq -r '.[0].name // empty' 2>/dev/null || true
    )
  fi

  if [[ -n "$RAW_TAG" && "$RAW_TAG" != "null" ]]; then
    LATEST_VER="$RAW_TAG"

    if [[ "$STRIP_V" == true ]]; then
      LATEST_VER="${LATEST_VER#v}"
    fi
  else
    echo "WARNING: Could not fetch a release/tag from $REPO."
  fi

  # ------------------------------------------------
  # CryptPad:
  # Use a published Docker Hub version tag rather
  # than assuming the latest GitHub release has
  # already been published as a Docker image.
  # ------------------------------------------------
  if [[ "$IMAGE_NAME" == "cryptpad" ]]; then
    echo "Resolving published CryptPad Docker versions..."

    DOCKER_TAGS_JSON=$(
      curl -fsSL \
        --retry 2 \
        --connect-timeout 10 \
        "https://hub.docker.com/v2/repositories/cryptpad/cryptpad/tags?page_size=100&name=version-" \
      2>/dev/null
    ) || {
      echo "ERROR: Could not retrieve CryptPad Docker Hub tags."
      echo "Refusing to build with an unverified application version."
      exit 1
    }

    if ! jq -e '.results | type == "array"' \
      <<< "$DOCKER_TAGS_JSON" >/dev/null; then
      echo "ERROR: Invalid response from Docker Hub tags API."
      exit 1
    fi

    DOCKER_TAGS=$(
      jq -r '
        .results[]?.name
        | select(test("^version-[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | sub("^version-"; "")
      ' <<< "$DOCKER_TAGS_JSON" |
        sort -Vu
    )

    DESIRED_VER=$(printf '%s\n' "$DOCKER_TAGS" | tail -n 1)

    if [[ -z "$DESIRED_VER" ]]; then
      echo "ERROR: No valid versioned CryptPad Docker tag was found."
      echo "Refusing to build with an unverified application version."
      exit 1
    fi

    echo "Latest GitHub release: ${LATEST_VER:-unknown}"
    echo "Latest published CryptPad Docker version: $DESIRED_VER"

  # ------------------------------------------------
  # Nextcloud:
  # Enforce a minimum allowed application version.
  # ------------------------------------------------
  elif [[ "$IMAGE_NAME" == "nextcloud" ]]; then
    NEXTCLOUD_MIN_VERSION="${NEXTCLOUD_MIN_VERSION:-34.0.4}"
    NEXTCLOUD_MIN_VERSION="${NEXTCLOUD_MIN_VERSION#v}"

    if [[ -z "$NEXTCLOUD_MIN_VERSION" ]]; then
      echo "ERROR: NEXTCLOUD_MIN_VERSION is empty."
      exit 1
    fi

    DESIRED_VER="$NEXTCLOUD_MIN_VERSION"

    if [[ -n "$LATEST_VER" ]] &&
       version_gt "$LATEST_VER" "$DESIRED_VER"; then
      DESIRED_VER="$LATEST_VER"
    fi

    echo "Nextcloud minimum version: $NEXTCLOUD_MIN_VERSION"
    echo "Nextcloud upstream release: ${LATEST_VER:-unavailable}"
    echo "Nextcloud selected version: $DESIRED_VER"

  # ------------------------------------------------
  # Other monitored images:
  # Use the latest upstream release/tag.
  # ------------------------------------------------
  elif [[ -n "$LATEST_VER" ]]; then
    DESIRED_VER="$LATEST_VER"

  elif [[ -n "$CURRENT_VER" && "$CURRENT_VER" != "latest" ]]; then
    DESIRED_VER="$CURRENT_VER"
    echo "Falling back to current version: $DESIRED_VER"
  fi

  # A missing published image must never be built with an unverified version.
  if [[ "$MISSING_IMAGE" == true && -z "$DESIRED_VER" ]]; then
    echo "ERROR: Cannot resolve an upstream application version for missing image $IMAGE."
    echo "Refusing to build an image without a verified application version."
    exit 1
  fi

  # ------------------------------------------------
  # 3a. Reject application downgrades
  # ------------------------------------------------
  if [[ -n "$CURRENT_VER" &&
        "$CURRENT_VER" != "latest" &&
        -n "$DESIRED_VER" ]] &&
     version_lt "$DESIRED_VER" "$CURRENT_VER"; then
    echo "ERROR: Downgrade rejected: $DESIRED_VER < $CURRENT_VER"
    exit 1
  fi

  if [[ -n "$DESIRED_VER" ]]; then
    write_output "latest_version" "$DESIRED_VER"
  fi

  # ------------------------------------------------
  # 3b. Tailscale uses its existing source build flow
  # ------------------------------------------------
  if [[ "$IMAGE_NAME" == "tailscale" &&
        -n "$DESIRED_VER" ]] &&
     { [[ "$MISSING_IMAGE" == true ]] ||
       [[ -z "$CURRENT_VER" ]] ||
       version_gt "$DESIRED_VER" "$CURRENT_VER"; }; then
    echo "Tailscale build required: ${CURRENT_VER:-unknown} -> $DESIRED_VER"
    write_output "needs_update" "true"
    exit 0
  fi

  # ------------------------------------------------
  # 3c. Verify that the selected upstream Docker tag
  #     exists before building.
  # ------------------------------------------------
  if [[ -n "$DESIRED_VER" ]] &&
     { [[ "$MISSING_IMAGE" == true ]] ||
       [[ -z "$CURRENT_VER" ]] ||
       version_gt "$DESIRED_VER" "$CURRENT_VER"; }; then

    case "$IMAGE_NAME" in
      crowdsec)
        BASE_IMAGE_REF="ghcr.io/crowdsecurity/crowdsec:${DESIRED_VER}"
        ;;
      nextcloud)
        BASE_IMAGE_REF="nextcloud:${DESIRED_VER}"
        ;;
      cryptpad)
        BASE_IMAGE_REF="cryptpad/cryptpad:version-${DESIRED_VER}"
        ;;
      tetragon)
        BASE_IMAGE_REF="quay.io/cilium/tetragon:${DESIRED_VER}"
        ;;
      immich-server)
        BASE_IMAGE_REF="ghcr.io/immich-app/immich-server:${DESIRED_VER}"
        ;;
      immich-machine-learning)
        BASE_IMAGE_REF="ghcr.io/immich-app/immich-machine-learning:${DESIRED_VER}"
        ;;
      *)
        BASE_IMAGE_REF="${REPO}:${DESIRED_VER}"
        ;;
    esac

    echo "Verifying upstream image availability: $BASE_IMAGE_REF"

    if ! docker buildx imagetools inspect "$BASE_IMAGE_REF" >/dev/null 2>&1; then
      echo "ERROR: Upstream image not found: $BASE_IMAGE_REF"
      echo "Refusing to build with an unverified application version."
      exit 1
    fi

    echo "Upstream update/build required: ${CURRENT_VER:-unknown} -> $DESIRED_VER"
    write_output "needs_update" "true"
    exit 0
  fi

  # ------------------------------------------------
  # 3d. Report the resolved version
  # ------------------------------------------------
  if [[ -n "$DESIRED_VER" && -n "$CURRENT_VER" ]]; then
    if [[ "$DESIRED_VER" == "$CURRENT_VER" ]]; then
      echo "Application version unchanged: $CURRENT_VER"
    else
      echo "Keeping current application version: $CURRENT_VER"
    fi
  fi

else
  echo "Image '$IMAGE_NAME' is not monitored via the GitHub API."

  if [[ "$MISSING_IMAGE" == true ]]; then
    echo "ERROR: Cannot verify an upstream version for missing image $IMAGE."
    exit 1
  fi

  if [[ -n "$CURRENT_VER" && "$CURRENT_VER" != "latest" ]]; then
    write_output "latest_version" "$CURRENT_VER"
  fi
fi

# --------------------------------------------------
# 4. Check OS package updates without changing the
#    selected application version.
# --------------------------------------------------
CHECK_CMD='
if [ -f /etc/alpine-release ]; then
    apk update >/dev/null 2>&1 && apk list -u 2>/dev/null
elif command -v apt-get >/dev/null; then
    apt-get update >/dev/null 2>&1 &&
    apt-get -s upgrade 2>/dev/null | grep -E "^Inst|^Conf"
else
    echo ""
fi
'

OUTPUT=$(
  docker run --rm --user 0:0 --entrypoint sh -- "$IMAGE" \
    -c "$CHECK_CMD" 2>&1 || true
)

if echo "$OUTPUT" | grep -q "executable file not found"; then
  echo "Image has no shell. Skipping OS package check."

  if [[ "$MISSING_IMAGE" == false ]]; then
    write_output "needs_update" "false"
  fi

  exit 0
fi

UPDATES=$(
  echo "$OUTPUT" |
    grep -v "fetch http" |
    grep -v "WARNING" |
    grep -E "[a-zA-Z0-9]" || true
)

if [[ -n "$UPDATES" ]]; then
  echo "OS updates detected:"
  echo "$UPDATES"
  write_output "needs_update" "true"
else
  echo "Image OS is up-to-date."

  if [[ "$MISSING_IMAGE" == false ]]; then
    if [[ "$DOCKER_CLI_UPDATE" == true ]]; then
      write_output "needs_update" "true"
    else
      write_output "needs_update" "false"
    fi
  fi
fi
