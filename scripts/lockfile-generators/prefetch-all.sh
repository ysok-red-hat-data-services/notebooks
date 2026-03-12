#!/usr/bin/env bash
set -euo pipefail

# prefetch-all.sh — Download hermetic build dependencies for a component.
#
# This script orchestrates prefetching dependency types into cachi2/output/deps/.
# Currently implements only Step 5 (Go modules). Steps 1–4 (generic, pip, npm, rpm)
# are skipped; the full implementation lives in the hermetic build branch.
#
#   5. Go modules — Go deps from go.mod/go.sum via Hermeto (gomod)
#      (into cachi2/output/deps/gomod/).
#
# Uses the Tekton PipelineRun YAML to discover gomod-type prefetch-input paths.
# Prerequisites: jq, podman, yq (for Tekton discovery).
#
# Usage:
#   ./scripts/lockfile-generators/prefetch-all.sh \
#       --component-dir jupyter/pytorch+llmcompressor/ubi9-python-3.12

SCRIPTS_PATH="scripts/lockfile-generators"

COMPONENT_DIR=""
VARIANT="odh"
FLAVOR="cpu"
ACTIVATION_KEY=""
ORG=""

show_help() {
  cat << 'HELPEOF'
Usage: scripts/lockfile-generators/prefetch-all.sh [OPTIONS]

Download hermetic build dependencies into cachi2/output/deps/.
Currently runs only the Go modules (gomod) step.

Options:
  --component-dir DIR     Component directory (required)
  --rhds                  Use downstream (RHDS) variant
  --flavor NAME           Lock file flavor (default: cpu)
  --activation-key KEY    Red Hat activation key (optional)
  --org ORG               Red Hat organization ID (optional)
  -h, --help              Show this help
HELPEOF
}

error_exit() {
  echo "Error: $1" >&2
  exit 1
}

find_tekton_yaml() {
  local comp_dir="$1"
  local variant="$2"
  local found=0
  local f dockerfile_path
  if [[ ! -d ".tekton" ]] || ! command -v yq &>/dev/null; then
    return 1
  fi
  for f in .tekton/*pull-request*.yaml; do
    [[ -f "$f" ]] || continue
    dockerfile_path=$(yq -r '.spec.params[] | select(.name == "dockerfile") | .value' "$f" 2>/dev/null)
    [[ -n "$dockerfile_path" ]] || continue
    if [[ "$variant" == "odh" ]]; then
      if [[ "$dockerfile_path" == "$comp_dir/Dockerfile."* ]] && [[ "$dockerfile_path" != "$comp_dir/Dockerfile.konflux."* ]]; then
        echo "$f"
        found=1
      fi
    elif [[ "$variant" == "rhds" ]]; then
      if [[ "$dockerfile_path" == "$comp_dir/Dockerfile.konflux."* ]]; then
        echo "$f"
        found=1
      fi
    fi
  done
  [[ $found -eq 1 ]]
}

if [[ ! -d "$SCRIPTS_PATH" ]]; then
  error_exit "This script must be run from the repository root."
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component-dir)     [[ $# -ge 2 ]] || error_exit "--component-dir requires a value"
                         COMPONENT_DIR="$2"; shift 2 ;;
    --rhds)              VARIANT="rhds"; shift ;;
    --flavor)            [[ $# -ge 2 ]] || error_exit "--flavor requires a value"
                         FLAVOR="$2"; shift 2 ;;
    --activation-key)    [[ $# -ge 2 ]] || error_exit "--activation-key requires a value"
                         ACTIVATION_KEY="$2"; shift 2 ;;
    --org)               [[ $# -ge 2 ]] || error_exit "--org requires a value"
                         ORG="$2"; shift 2 ;;
    -h|--help)           show_help; exit 0 ;;
    *)                   error_exit "Unknown argument: '$1'" ;;
  esac
done

[[ -z "$COMPONENT_DIR" ]] && error_exit "--component-dir is required."
[[ -d "$COMPONENT_DIR" ]] || error_exit "Component directory not found: $COMPONENT_DIR"

PREFETCH_DIR="$COMPONENT_DIR/prefetch-input"
VARIANT_DIR="$PREFETCH_DIR/$VARIANT"

STEPS_RUN=0
STEPS_SKIPPED=0

# Resolve Tekton file (same logic as full prefetch-all step 3)
tekton_file=""
if [[ -d ".tekton" ]] && command -v yq &>/dev/null; then
  tekton_file=$(find_tekton_yaml "$COMPONENT_DIR" "rhds" 2>/dev/null | head -1) || true
  [[ -n "$tekton_file" ]] || tekton_file=$(find_tekton_yaml "$COMPONENT_DIR" "odh" 2>/dev/null | head -1) || true
fi

echo "=============================================="
echo " prefetch-all.sh (gomod step only)"
echo "  component : $COMPONENT_DIR"
echo "  variant   : $VARIANT"
echo "  tekton    : ${tekton_file:-none}"
echo "=============================================="
echo ""

# Steps 1–4 not implemented in this minimal version
echo "=== [1/5] Generic artifacts — SKIPPED (not in this build) ==="
STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
echo "=== [2/5] Pip wheels — SKIPPED (not in this build) ==="
STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
echo "=== [3/5] NPM packages — SKIPPED (not in this build) ==="
STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
echo "=== [4/5] RPMs — SKIPPED (not in this build) ==="
STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
echo ""

# =========================================================================
# Step 5: Go modules (create-go-lockfile.sh)
# =========================================================================
echo "=== [5/5] Go modules ==="
if [[ -n "$tekton_file" ]] && command -v yq &>/dev/null; then
  gomod_paths=$(yq eval '
    .spec.params[]
    | select(.name == "prefetch-input")
    | .value[]
    | select(.type == "gomod")
    | .path
  ' "$tekton_file" 2>/dev/null) || true
  if [[ -n "$gomod_paths" ]] && [[ "$(echo "$gomod_paths" | grep -c .)" -gt 0 ]]; then
    "$SCRIPTS_PATH/create-go-lockfile.sh" --tekton-file "$tekton_file"
    STEPS_RUN=$((STEPS_RUN + 1))
  else
    echo "  No gomod-type prefetch-input in Tekton file — skipping"
    STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
  fi
else
  echo "  No Tekton file or yq — skipping Go modules"
  STEPS_SKIPPED=$((STEPS_SKIPPED + 1))
fi
echo ""

echo "=============================================="
echo " prefetch-all.sh complete"
echo "  steps run    : $STEPS_RUN"
echo "  steps skipped: $STEPS_SKIPPED"
echo "  Dependencies : cachi2/output/deps/"
echo "=============================================="
if [[ -d "cachi2/output/deps" ]]; then
  du -sh cachi2/output/deps/*/ 2>/dev/null || true
fi
