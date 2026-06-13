#!/usr/bin/env bash
# Run Konflux build-images locally/GHA via konflux-build-cli image build (buildah).
#
# Intended for Linux hosts with a podman socket (GHA install-podman-action). The CLI
# container talks to the host podman via CONTAINER_HOST. On macOS, tekton_build.py
# falls back to an enhanced podman build with the same build-args and cachi2 mounts.
#
# Required env (usually set by tekton_build.py):
#   SOURCE_DIR      - repo root
#   IMAGE_TAG       - output image reference
#   DOCKERFILE      - path relative to SOURCE_DIR (e.g. jupyter/.../Dockerfile.cuda)
#   CONTEXT         - build context relative to SOURCE_DIR (usually .)
#   BUILD_ARGS_FILE - path relative to SOURCE_DIR (e.g. build-args/global.conf)
#
# Optional env:
#   BUILD_ARGS      - space-separated KEY=VAL inline build-args (Tekton build-args param)
#   BUILD_PLATFORM  - podman platform string (e.g. linux/amd64); used for RPM repo arch
#   YUM_REPOS_D_SOURCES - container path(s) for --yum-repos-d-sources (space-separated)
#   HERMETIC        - true|false (default: true)
#   IMAGE_SOURCE    - org.opencontainers.image.source (default: git remote origin URL)
#   IMAGE_REVISION  - git commit SHA (default: HEAD)
#   RHSM_KEY_DIR    - dir with org + activationkey files
#   CONTAINER_ENGINE - podman (default) or docker
#   LOG_LEVEL       - konflux-build-cli log level (default: info)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=konflux-versions.env
source "$SCRIPT_DIR/konflux-versions.env"

: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"
: "${DOCKERFILE:?DOCKERFILE is required}"
: "${CONTEXT:=.}"
: "${BUILD_ARGS_FILE:=}"
: "${HERMETIC:=true}"
: "${CONTAINER_ENGINE:=podman}"
: "${LOG_LEVEL:=info}"

SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
CACHI2_DIR="$SOURCE_DIR/cachi2"

USE_REMOTE_PODMAN=false
if [[ -n "${CONTAINER_HOST:-}" ]]; then
  USE_REMOTE_PODMAN=true
elif [[ -S "/var/run/podman/podman.sock" ]]; then
  USE_REMOTE_PODMAN=true
  CONTAINER_HOST="unix:///var/run/podman/podman.sock"
fi

BUILD_STORAGE=""
cleanup() {
  if [[ -n "$BUILD_STORAGE" ]]; then
    rm -rf "$BUILD_STORAGE" 2>/dev/null || sudo rm -rf "$BUILD_STORAGE" || true
  fi
}
if [[ "$USE_REMOTE_PODMAN" == "false" ]]; then
  BUILD_STORAGE=$(mktemp -d)
  trap cleanup EXIT
fi

if [[ "$HERMETIC" == "true" && ! -d "$CACHI2_DIR/output" ]]; then
  echo "Hermetic build requires cachi2/output. Run prefetch first." >&2
  exit 1
fi

if [[ -z "${IMAGE_SOURCE:-}" ]]; then
  IMAGE_SOURCE=$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || echo "unknown")
fi
if [[ -z "${IMAGE_REVISION:-}" ]]; then
  IMAGE_REVISION=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
fi

BUILD_ARGS_FLAGS=()
if [[ -n "${BUILD_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  for arg in ${BUILD_ARGS}; do
    BUILD_ARGS_FLAGS+=(--build-args "$arg")
  done
fi

PODMAN_ARGS=(
  --rm
  --privileged
  --user 0:0
  -v "$SOURCE_DIR:/source:z"
  -v "$CACHI2_DIR:/cachi2:z"
  -e "TMPDIR=/var/tmp"
)

if [[ -n "$BUILD_STORAGE" ]]; then
  PODMAN_ARGS+=(-v "$BUILD_STORAGE:/var/lib/containers/storage:z")
fi

CONTAINERS_CONF="$SOURCE_DIR/ci/cached-builds/containers.conf"
if [[ -f "$CONTAINERS_CONF" ]]; then
  PODMAN_ARGS+=(
    -v "$CONTAINERS_CONF:/etc/containers/containers.conf:ro,z"
  )
fi

# Prefer remote podman/buildah on the host when a socket is available (GHA).
if [[ "$USE_REMOTE_PODMAN" == "true" ]]; then
  PODMAN_ARGS+=(
    -e "CONTAINER_HOST=${CONTAINER_HOST}"
    -v "/var/run/podman/podman.sock:/var/run/podman/podman.sock:z"
  )
fi

RHSM_ARGS=()
if [[ -n "${RHSM_KEY_DIR:-}" && -f "$RHSM_KEY_DIR/org" && -f "$RHSM_KEY_DIR/activationkey" ]]; then
  PODMAN_ARGS+=(-v "$RHSM_KEY_DIR:/activation-key:ro,z")
  RHSM_ARGS+=(
    --rhsm-org /activation-key/org
    --rhsm-activation-key /activation-key/activationkey
    --rhsm-activation-mount /activation-key
  )
fi

KBC_ARGS=(
  image build
  -f "$DOCKERFILE"
  -t "$IMAGE_TAG"
  --source /source
  --context "$CONTEXT"
  --image-source "$IMAGE_SOURCE"
  --image-revision "$IMAGE_REVISION"
  --inherit-labels=true
  --add-legacy-labels
  --include-legacy-buildinfo-path=true
  --skip-injections=false
  --skip-unused-stages=true
  --ulimits nofile=4096:4096
  --security-opts unmask=/proc/interrupts
  --no-cache
  --src-tls-verify=true
  --dest-tls-verify=true
)

if [[ -n "$BUILD_ARGS_FILE" ]]; then
  KBC_ARGS+=(--build-args-file "/source/$BUILD_ARGS_FILE")
fi

if [[ "$HERMETIC" == "true" ]]; then
  KBC_ARGS+=(
    --hermetic
    --prefetch-dir /cachi2
    --prefetch-env-mount /cachi2/cachi2.env
    --prefetch-output-mount /cachi2/output
    --yum-repos-d-target /etc/yum.repos.d
  )
  if [[ -n "${YUM_REPOS_D_SOURCES:-}" ]]; then
    # shellcheck disable=SC2206
    for repos_dir in ${YUM_REPOS_D_SOURCES}; do
      KBC_ARGS+=(--yum-repos-d-sources "$repos_dir")
    done
  fi
  src_repos="/source/repos.d"
  if [[ -d "$SOURCE_DIR/repos.d" ]]; then
    KBC_ARGS+=(--yum-repos-d-sources "$src_repos")
  fi
fi

echo "--- Konflux build-images (konflux-build-cli) ---"
echo "Image:       $KONFLUX_BUILD_CLI_IMAGE"
echo "Output:      $IMAGE_TAG"
echo "Dockerfile:  $DOCKERFILE"
echo "Context:     $CONTEXT"
echo "Platform:    ${BUILD_PLATFORM:-native}"
echo "Hermetic:    $HERMETIC"
echo "Remote:      ${USE_REMOTE_PODMAN} (${CONTAINER_HOST:-local storage})"
echo "Yum repos:   ${YUM_REPOS_D_SOURCES:-}"
echo "Build args:  ${BUILD_ARGS:-}"

"$CONTAINER_ENGINE" run "${PODMAN_ARGS[@]}" \
  --entrypoint konflux-build-cli \
  "$KONFLUX_BUILD_CLI_IMAGE" \
  --loglevel "$LOG_LEVEL" \
  "${KBC_ARGS[@]}" \
  "${BUILD_ARGS_FLAGS[@]}" \
  ${RHSM_ARGS[@]+"${RHSM_ARGS[@]}"}

echo "Build complete: $IMAGE_TAG"
