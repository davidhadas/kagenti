#!/bin/bash
set -e

# ============================================================================
# Load Images into Kind Cluster
# ============================================================================
# This script loads the required demo infrastructure images into a Kind cluster.
# It can be run independently if image preloading was skipped during deployment
# or if you need to reload infrastructure images after pulling new versions.
#
# Prerequisites:
# - kind CLI installed
# - kubectl configured and connected to a Kind cluster
# - Docker images available locally (pulled)
# ============================================================================

echo "=============================================="
echo "Kind Image Loader"
echo "=============================================="
echo ""

# ============================================================================
# Preflight Checks
# ============================================================================
echo "Running preflight checks..."
echo ""

# Check if kind is available
if ! command -v kind &> /dev/null; then
    echo "❌ Error: kind CLI is not installed or not in PATH"
    echo "   Install kind from: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi
echo "✓ kind CLI found"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ Error: kubectl is not installed or not in PATH"
    exit 1
fi
echo "✓ kubectl found"

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Error: Cannot connect to Kubernetes cluster"
    exit 1
fi
echo "✓ Kubernetes cluster accessible"

# Detect if running on Kind cluster
if ! kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q "kind"; then
    echo "❌ Error: Current cluster is not a Kind cluster"
    echo "   This script is only for Kind clusters"
    exit 1
fi
echo "✓ Kind cluster detected"

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "❌ Error: docker is not installed or not in PATH"
    exit 1
fi
echo "✓ docker found"

echo ""
echo "All preflight checks passed!"
echo ""

# ============================================================================
# Get Kind Cluster Name and Paths
# ============================================================================
KIND_CLUSTER=$(kubectl config current-context | sed 's/kind-//')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Kind cluster name: ${KIND_CLUSTER}"
echo ""

# ============================================================================
# Define Images to Load
# ============================================================================
IMAGES=(
    "ghcr.io/davidhadas/kagenti-mcp-server:latest"
    "ghcr.io/davidhadas/kagenti-token-broker:latest"
    "ghcr.io/davidhadas/kagenti-backend:latest"
    "ghcr.io/davidhadas/kagenti-extensions/authbridge:latest"
)

echo "=============================================="
echo "Images to Load"
echo "=============================================="
echo ""
for IMAGE in "${IMAGES[@]}"; do
    echo "  - ${IMAGE}"
done
echo ""

# ============================================================================
# Check if Images Exist Locally
# ============================================================================
echo "=============================================="
echo "Checking Local Images"
echo "=============================================="
echo ""

MISSING_IMAGES=()
for IMAGE in "${IMAGES[@]}"; do
    if docker image inspect "${IMAGE}" &> /dev/null; then
        echo "✓ ${IMAGE} found locally"
    else
        echo "⚠️  ${IMAGE} not found locally"
        MISSING_IMAGES+=("${IMAGE}")
    fi
done
echo ""

if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    echo "⚠️  Warning: ${#MISSING_IMAGES[@]} image(s) not found locally"
    echo ""
    echo "You can pull them using:"
    for IMAGE in "${MISSING_IMAGES[@]}"; do
        echo "  docker pull ${IMAGE}"
    done
    echo ""
    read -p "Do you want to continue loading only available images? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Exiting. Please pull the missing images and run this script again."
        exit 1
    fi
fi

# ============================================================================
# Load Images into Kind Cluster
# ============================================================================
echo "=============================================="
echo "Loading Images into Kind Cluster"
echo "=============================================="
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for IMAGE in "${IMAGES[@]}"; do
    # Skip if image doesn't exist locally
    if ! docker image inspect "${IMAGE}" &> /dev/null; then
        echo "⊘ Skipping ${IMAGE} (not available locally)"
        echo ""
        continue
    fi
    
    echo "Loading ${IMAGE}..."
    if kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER}"; then
        echo "✓ ${IMAGE} loaded successfully"
        ((SUCCESS_COUNT++))
    else
        echo "❌ Failed to load ${IMAGE}"
        ((FAIL_COUNT++))
    fi
    echo ""
done

# ============================================================================
# Summary
# ============================================================================
echo "=============================================="
echo "Summary"
echo "=============================================="
echo ""
echo "Successfully loaded: ${SUCCESS_COUNT} image(s)"
if [ ${FAIL_COUNT} -gt 0 ]; then
    echo "Failed to load: ${FAIL_COUNT} image(s)"
fi
if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    echo "Skipped (not available): ${#MISSING_IMAGES[@]} image(s)"
fi
echo ""

if [ ${SUCCESS_COUNT} -eq ${#IMAGES[@]} ]; then
    echo "✓ All images loaded successfully!"
    echo ""
    echo "You can now deploy the MCP Elicitation demo:"
    echo "  ./deploy.sh"
elif [ ${SUCCESS_COUNT} -gt 0 ]; then
    echo "⚠️  Some images were loaded, but not all"
    echo "   You may encounter ErrImagePull errors for missing demo infrastructure images"
    echo ""
    echo "To pull missing images:"
    for IMAGE in "${MISSING_IMAGES[@]}"; do
        echo "  docker pull ${IMAGE}"
    done
    echo ""
    echo "Then run this script again to load them into Kind"
else
    echo "❌ No images were loaded"
    echo "   Please pull the images and run this script again"
    exit 1
fi

echo ""

# Made with Bob