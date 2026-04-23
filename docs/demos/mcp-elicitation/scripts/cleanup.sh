#!/bin/bash
set -e

# ============================================================================
# MCP Elicitation Demo Cleanup Script
# ============================================================================
# This script removes the MCP Elicitation demo from a Kubernetes cluster.
#
# Cleanup Order:
# 1. Delete demo namespace (includes all demo resources)
# 2. Optionally uninstall Kagenti Helm release
# 3. Verify cleanup completion
#
# Prerequisites:
# - kubectl configured and connected to cluster
# - helm 3.x installed (if uninstalling Kagenti)
# ============================================================================

NAMESPACE="kagenti-mcp-elicitation"
KAGENTI_NAMESPACE="kagenti-system"
HELM_RELEASE="kagenti"

echo "=============================================="
echo "MCP Elicitation Demo Cleanup"
echo "=============================================="
echo ""

# ============================================================================
# Preflight Checks
# ============================================================================
echo "Running preflight checks..."
echo ""

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

echo ""

# ============================================================================
# Check What Will Be Deleted
# ============================================================================
DEMO_EXISTS=false
KAGENTI_EXISTS=false

# Check if demo namespace exists
if kubectl get namespace ${NAMESPACE} &> /dev/null; then
    DEMO_EXISTS=true
    echo "Found demo namespace: ${NAMESPACE}"
    echo ""
    echo "Resources in ${NAMESPACE}:"
    kubectl get all -n ${NAMESPACE}
    echo ""
else
    echo "Demo namespace ${NAMESPACE} does not exist."
    echo ""
fi

# Check if Kagenti is installed
if command -v helm &> /dev/null; then
    if helm list -n ${KAGENTI_NAMESPACE} 2>/dev/null | grep -q "^${HELM_RELEASE}"; then
        KAGENTI_EXISTS=true
        echo "Found Kagenti installation: ${HELM_RELEASE} in ${KAGENTI_NAMESPACE}"
        echo ""
    fi
fi

# If nothing to clean up, exit
if [ "$DEMO_EXISTS" = false ] && [ "$KAGENTI_EXISTS" = false ]; then
    echo "Nothing to clean up. Exiting."
    exit 0
fi

# ============================================================================
# Confirm Cleanup
# ============================================================================
echo "=============================================="
echo "Cleanup Plan"
echo "=============================================="
echo ""

if [ "$DEMO_EXISTS" = true ]; then
    echo "✓ Delete demo namespace: ${NAMESPACE}"
    echo "  This will remove:"
    echo "  - Token Broker service"
    echo "  - MCP Server"
    echo "  - Backend service"
    echo "  - OAuth secret"
    echo "  - All associated resources"
    echo ""
fi

if [ "$KAGENTI_EXISTS" = true ]; then
    echo "? Optionally uninstall Kagenti: ${HELM_RELEASE}"
    echo "  (You will be asked separately)"
    echo ""
fi

read -p "Do you want to proceed with cleanup? (yes/no): " -r
echo ""
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

# ============================================================================
# Step 1: Delete Demo Namespace
# ============================================================================
if [ "$DEMO_EXISTS" = true ]; then
    echo "=============================================="
    echo "Step 1: Deleting Demo Namespace"
    echo "=============================================="
    echo ""
    
    echo "Deleting namespace ${NAMESPACE}..."
    kubectl delete namespace ${NAMESPACE}
    
    echo ""
    echo "Waiting for namespace to be fully deleted..."
    kubectl wait --for=delete namespace/${NAMESPACE} --timeout=120s 2>/dev/null || true
    
    # Verify deletion
    if kubectl get namespace ${NAMESPACE} &> /dev/null; then
        echo "⚠️  Warning: Namespace ${NAMESPACE} still exists"
        echo "   Some resources may be stuck in terminating state"
        echo "   Check with: kubectl get all -n ${NAMESPACE}"
    else
        echo "✓ Namespace ${NAMESPACE} deleted successfully"
    fi
    echo ""
fi

# ============================================================================
# Step 2: Optionally Uninstall Kagenti
# ============================================================================
if [ "$KAGENTI_EXISTS" = true ]; then
    echo "=============================================="
    echo "Step 2: Kagenti Cleanup (Optional)"
    echo "=============================================="
    echo ""
    
    echo "⚠️  WARNING: This will uninstall Kagenti from your cluster!"
    echo "   This may affect other applications using Kagenti."
    echo ""
    read -p "Do you want to uninstall Kagenti? (yes/no): " -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Uninstalling Kagenti Helm release..."
        helm uninstall ${HELM_RELEASE} -n ${KAGENTI_NAMESPACE}
        
        echo ""
        echo "Waiting for Kagenti resources to be deleted..."
        sleep 5
        
        # Check if namespace should be deleted
        echo ""
        read -p "Do you want to delete the Kagenti namespace ${KAGENTI_NAMESPACE}? (yes/no): " -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Deleting namespace ${KAGENTI_NAMESPACE}..."
            kubectl delete namespace ${KAGENTI_NAMESPACE} --timeout=120s 2>/dev/null || true
            echo "✓ Kagenti namespace deleted"
        else
            echo "Keeping namespace ${KAGENTI_NAMESPACE}"
        fi
        
        echo ""
        echo "✓ Kagenti uninstalled successfully"
    else
        echo "Keeping Kagenti installation"
    fi
    echo ""
fi

# ============================================================================
# Verify Cleanup
# ============================================================================
echo "=============================================="
echo "Verifying Cleanup"
echo "=============================================="
echo ""

# Check demo namespace
if kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo "⚠️  Demo namespace ${NAMESPACE} still exists"
    REMAINING=$(kubectl get all -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l)
    if [ "$REMAINING" -gt 0 ]; then
        echo "   Remaining resources: $REMAINING"
        kubectl get all -n ${NAMESPACE}
    fi
else
    echo "✓ Demo namespace ${NAMESPACE} removed"
fi

# Check Kagenti
if command -v helm &> /dev/null; then
    if helm list -n ${KAGENTI_NAMESPACE} 2>/dev/null | grep -q "^${HELM_RELEASE}"; then
        echo "✓ Kagenti installation still present (not removed)"
    else
        echo "✓ Kagenti installation removed"
    fi
fi

echo ""

# ============================================================================
# Cleanup Complete
# ============================================================================
echo "=============================================="
echo "Cleanup Complete!"
echo "=============================================="
echo ""

if [ "$DEMO_EXISTS" = true ]; then
    echo "✓ MCP Elicitation demo resources removed"
fi

if [ "$KAGENTI_EXISTS" = true ]; then
    if helm list -n ${KAGENTI_NAMESPACE} 2>/dev/null | grep -q "^${HELM_RELEASE}"; then
        echo "✓ Kagenti installation preserved"
    else
        echo "✓ Kagenti installation removed"
    fi
fi

echo ""
echo "To redeploy the demo, run:"
echo "  ./deploy.sh"
echo ""

# Made with Bob
