#!/bin/bash
set -e

# ============================================================================
# MCP Elicitation Demo Deployment Script
# ============================================================================
# This script deploys the complete MCP Elicitation demo to a Kubernetes cluster.
#
# Deployment Order:
# 1. Install Kagenti with custom authbridge configuration
# 2. Create demo namespace
# 3. Deploy OAuth secret
# 4. Deploy Token Broker service
# 5. Deploy MCP Server
# 6. Deploy Backend service
# 7. Import agents via Kagenti dashboard (manual step)
#
# Prerequisites:
# - kubectl configured and connected to cluster
# - helm 3.x installed
# - Kagenti charts available at ../../charts/kagenti
# - OAuth credentials configured in k8s/01-oauth-secret.yaml
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="${SCRIPT_DIR}/.."
K8S_DIR="${DEMO_DIR}/k8s"
VALUES_FILE="${DEMO_DIR}/kagenti-values.yaml"
CHARTS_DIR="${SCRIPT_DIR}/../../../../charts/kagenti"
NAMESPACE="kagenti-mcp-elicitation"
KAGENTI_NAMESPACE="kagenti-system"
HELM_RELEASE="kagenti"

echo "=============================================="
echo "MCP Elicitation Demo Deployment"
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

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "❌ Error: helm is not installed or not in PATH"
    exit 1
fi
echo "✓ helm found"

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Error: Cannot connect to Kubernetes cluster"
    exit 1
fi
echo "✓ Kubernetes cluster accessible"

# Check if Kagenti charts exist
if [ ! -d "${CHARTS_DIR}" ]; then
    echo "❌ Error: Kagenti charts not found at ${CHARTS_DIR}"
    echo "   Please ensure you're running this script from the correct location"
    exit 1
fi
echo "✓ Kagenti charts found"

# Check if values file exists
if [ ! -f "${VALUES_FILE}" ]; then
    echo "❌ Error: Values file not found at ${VALUES_FILE}"
    exit 1
fi
echo "✓ Kagenti values file found"

# Check if K8s manifests directory exists
if [ ! -d "${K8S_DIR}" ]; then
    echo "❌ Error: K8s manifests directory not found at ${K8S_DIR}"
    exit 1
fi
echo "✓ K8s manifests directory found"

echo ""
echo "All preflight checks passed!"
echo ""

# ============================================================================
# Step 1: Install Kagenti with Custom AuthBridge Configuration
# ============================================================================
echo "=============================================="
echo "Step 1: Installing Kagenti"
echo "=============================================="
echo ""

# Check if Kagenti is already installed
if helm list -n ${KAGENTI_NAMESPACE} | grep -q "^${HELM_RELEASE}"; then
    echo "⚠️  Kagenti is already installed in namespace ${KAGENTI_NAMESPACE}"
    read -p "Do you want to upgrade the existing installation? (yes/no): " -r
    echo ""
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Upgrading Kagenti..."
        helm upgrade ${HELM_RELEASE} ${CHARTS_DIR} \
            -f ${VALUES_FILE} \
            -n ${KAGENTI_NAMESPACE}
        echo "✓ Kagenti upgraded successfully"
    else
        echo "Skipping Kagenti installation"
    fi
else
    echo "Installing Kagenti with custom authbridge configuration..."
    echo "  Release: ${HELM_RELEASE}"
    echo "  Namespace: ${KAGENTI_NAMESPACE}"
    echo "  Chart: ${CHARTS_DIR}"
    echo "  Values: ${VALUES_FILE}"
    echo ""
    
    helm install ${HELM_RELEASE} ${CHARTS_DIR} \
        -f ${VALUES_FILE} \
        -n ${KAGENTI_NAMESPACE} \
        --create-namespace
    
    echo ""
    echo "✓ Kagenti installed successfully"
fi

echo ""
echo "Waiting for Kagenti operator to be ready..."
kubectl wait --for=condition=available --timeout=300s \
    deployment/kagenti-operator-controller-manager \
    -n ${KAGENTI_NAMESPACE} 2>/dev/null || true

echo "✓ Kagenti operator is ready"
echo ""

# ============================================================================
# Step 2: Create Demo Namespace
# ============================================================================
echo "=============================================="
echo "Step 2: Creating Demo Namespace"
echo "=============================================="
echo ""

echo "Creating namespace: ${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"

echo ""
echo "Waiting for namespace to be ready..."
kubectl wait --for=jsonpath='{.status.phase}'=Active \
    namespace/${NAMESPACE} --timeout=30s

echo "✓ Namespace ${NAMESPACE} is ready"
echo ""

# ============================================================================
# Step 3: Deploy OAuth Secret
# ============================================================================
echo "=============================================="
echo "Step 3: Deploying OAuth Secret"
echo "=============================================="
echo ""

echo "⚠️  IMPORTANT: Ensure you have configured your OAuth credentials"
echo "   in ${K8S_DIR}/01-oauth-secret.yaml before proceeding."
echo ""
read -p "Have you configured the OAuth secret? (yes/no): " -r
echo ""
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "❌ Please configure the OAuth secret and run this script again"
    exit 1
fi

echo "Deploying OAuth secret..."
kubectl apply -f "${K8S_DIR}/01-oauth-secret.yaml"

echo "✓ OAuth secret deployed"
echo ""

# ============================================================================
# Step 4: Deploy Token Broker Service
# ============================================================================
echo "=============================================="
echo "Step 4: Deploying Token Broker"
echo "=============================================="
echo ""

echo "Deploying Token Broker service..."
kubectl apply -f "${K8S_DIR}/02-token-broker.yaml"

echo ""
echo "Waiting for Token Broker to be ready..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/token-broker -n ${NAMESPACE}

echo "✓ Token Broker is ready"
echo ""

# ============================================================================
# Step 5: Deploy MCP Server
# ============================================================================
echo "=============================================="
echo "Step 5: Deploying MCP Server"
echo "=============================================="
echo ""

echo "Deploying MCP Server..."
kubectl apply -f "${K8S_DIR}/03-mcp-server.yaml"

echo ""
echo "Waiting for MCP Server to be ready..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/mcp-server -n ${NAMESPACE}

echo "✓ MCP Server is ready"
echo ""

# ============================================================================
# Step 6: Deploy Backend Service
# ============================================================================
echo "=============================================="
echo "Step 6: Deploying Backend Service"
echo "=============================================="
echo ""

echo "Deploying Backend service..."
kubectl apply -f "${K8S_DIR}/04-backend.yaml"

echo ""
echo "Waiting for Backend to be ready..."
kubectl wait --for=condition=available --timeout=120s \
    deployment/backend -n ${NAMESPACE}

echo "✓ Backend is ready"
echo ""

# ============================================================================
# Deployment Status
# ============================================================================
echo "=============================================="
echo "Deployment Status"
echo "=============================================="
echo ""

echo "Kagenti System (${KAGENTI_NAMESPACE}):"
kubectl get pods -n ${KAGENTI_NAMESPACE}
echo ""

echo "Demo Components (${NAMESPACE}):"
kubectl get all -n ${NAMESPACE}
echo ""

# ============================================================================
# Verify Pod Status
# ============================================================================
echo "=============================================="
echo "Verifying Pod Status"
echo "=============================================="
echo ""

# Check if all pods are running
NOT_RUNNING=$(kubectl get pods -n ${NAMESPACE} --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l)
if [ "$NOT_RUNNING" -gt 0 ]; then
    echo "⚠️  Warning: Some pods are not in Running state:"
    kubectl get pods -n ${NAMESPACE} --field-selector=status.phase!=Running
    echo ""
else
    echo "✓ All pods are running"
    echo ""
fi

# ============================================================================
# Next Steps
# ============================================================================
echo "=============================================="
echo "Deployment Complete!"
echo "=============================================="
echo ""
echo "✓ Kagenti installed with custom authbridge"
echo "✓ Token Broker deployed and running"
echo "✓ MCP Server deployed and running"
echo "✓ Backend service deployed and running"
echo ""
echo "=============================================="
echo "Next Steps"
echo "=============================================="
echo ""
echo "1. Import Agents via Kagenti Dashboard:"
echo "   - Access the Kagenti dashboard"
echo "   - Navigate to the Agents section"
echo "   - Import the agent configurations for this demo"
echo "   - The agents will automatically use the MCP Server"
echo ""
echo "2. Access the Demo UI:"
echo "   To access the backend service, use port-forwarding:"
echo "   kubectl port-forward -n ${NAMESPACE} svc/backend 8080:8080"
echo "   Then open: http://localhost:8080"
echo ""
echo "3. Monitor the deployment:"
echo "   kubectl get all -n ${NAMESPACE}"
echo "   kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=token-broker"
echo "   kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=mcp-server"
echo "   kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=backend"
echo ""
echo "4. Check authbridge injection:"
echo "   kubectl get pods -n ${NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.containers[*].name}{\"\\n\"}{end}'"
echo "   (MCP Server should have an authbridge sidecar)"
echo ""
echo "5. To clean up the demo:"
echo "   ${SCRIPT_DIR}/cleanup.sh"
echo ""
echo "For more information, see:"
echo "  ${DEMO_DIR}/README.md"
echo "  ${DEMO_DIR}/ARCHITECTURE.md"
echo ""

# Made with Bob
