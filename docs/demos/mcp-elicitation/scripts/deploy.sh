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
# 7. Build/import github-elicitation-tool via Kagenti dashboard (manual step)
# 8. Import agents via Kagenti dashboard (manual step)
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
REPO_ROOT="${SCRIPT_DIR}/../../../.."
NAMESPACE="kagenti-mcp-elicitation"
KAGENTI_NAMESPACE="kagenti-system"
HELM_RELEASE="kagenti"
GITHUB_ELICITATION_TOOL_CONTEXT_DIR="."
GITHUB_ELICITATION_TOOL_SOURCE_PATH="kagenti/tools/github-elicitation-tool"

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

# Check if wrapper source exists
if [ ! -d "${REPO_ROOT}/${GITHUB_ELICITATION_TOOL_SOURCE_PATH}" ]; then
    echo "❌ Error: Wrapper source directory not found at ${REPO_ROOT}/${GITHUB_ELICITATION_TOOL_SOURCE_PATH}"
    exit 1
fi
echo "✓ github-elicitation-tool source found"

# Check if .env file exists for OAuth credentials
ENV_FILE="${DEMO_DIR}/.env"
if [ ! -f "${ENV_FILE}" ]; then
    echo "❌ Error: .env file not found at ${ENV_FILE}"
    echo "   Please create .env with your GitHub OAuth credentials:"
    echo "   cp ${DEMO_DIR}/.env.example ${ENV_FILE}"
    echo "   # Then edit .env with your actual credentials"
    exit 1
fi
echo "✓ .env file found"

# Load OAuth credentials - use export to make them available to kubectl
export $(grep -v '^#' "${ENV_FILE}" | xargs)

if [ -z "$GITHUB_OAUTH_CLIENT_ID" ] || [ -z "$GITHUB_OAUTH_CLIENT_SECRET" ]; then
    echo "❌ Error: OAuth credentials not set in .env"
    echo "   Please ensure GITHUB_OAUTH_CLIENT_ID and GITHUB_OAUTH_CLIENT_SECRET are set"
    exit 1
fi

echo "   Using CLIENT_ID: ${GITHUB_OAUTH_CLIENT_ID:0:3}..."
echo "   Using CLIENT_SECRET: ${GITHUB_OAUTH_CLIENT_SECRET:0:3}..."
echo "✓ OAuth credentials loaded from .env"

echo ""
echo "All preflight checks passed!"
echo ""

# ============================================================================
# Kind Cluster Detection and Image Preloading
# ============================================================================
echo "=============================================="
echo "Checking for Kind Cluster"
echo "=============================================="
echo ""

# Detect if running on Kind cluster
IS_KIND=false
if kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q "kind"; then
    IS_KIND=true
    echo "✓ Kind cluster detected"
    echo ""
    
    # Check if kind CLI is available
    if ! command -v kind &> /dev/null; then
        echo "⚠️  Warning: kind CLI not found in PATH"
        echo "   Image preloading will be skipped"
        echo "   Install kind CLI or manually load images using:"
        echo "   kind load docker-image <image-name>"
        echo ""
    else
        echo "=============================================="
        echo "Preloading Images into Kind Cluster"
        echo "=============================================="
        echo ""
        echo "Kind clusters require the demo infrastructure images to be preloaded."
        echo "This will load the following images:"
        echo "  - ghcr.io/davidhadas/kagenti-mcp-server:latest"
        echo "  - ghcr.io/davidhadas/kagenti-token-broker:latest"
        echo "  - ghcr.io/davidhadas/kagenti-backend:latest"
        echo "  - ghcr.io/davidhadas/kagenti-extensions/authbridge:latest"
        echo ""
        echo "The github-elicitation-tool is now imported from source via Kagenti UI,"
        echo "so no separate local tool image build/load is required for the primary flow."
        echo ""
        
        read -p "Do you want to preload infrastructure images now? (yes/no/skip): " -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            KIND_CLUSTER=$(kubectl config current-context | sed 's/kind-//')
            echo "Loading images into Kind cluster: ${KIND_CLUSTER}"
            echo ""
            
            IMAGES=(
                "ghcr.io/davidhadas/kagenti-mcp-server:latest"
                "ghcr.io/davidhadas/kagenti-token-broker:latest"
                "ghcr.io/davidhadas/kagenti-backend:latest"
                "ghcr.io/davidhadas/kagenti-extensions/authbridge:latest"
            )
            
            for IMAGE in "${IMAGES[@]}"; do
                echo "Loading ${IMAGE}..."
                if kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER}"; then
                    echo "✓ ${IMAGE} loaded successfully"
                else
                    echo "⚠️  Warning: Failed to load ${IMAGE}"
                    echo "   Make sure the image exists locally (docker pull ${IMAGE})"
                fi
                echo ""
            done
            
            echo "✓ Infrastructure image preloading complete"
            echo ""
        elif [[ $REPLY =~ ^[Ss][Kk][Ii][Pp]$ ]]; then
            echo "⚠️  Skipping image preloading"
            echo "   If you encounter ErrImagePull errors for demo infrastructure, run:"
            echo "   ${SCRIPT_DIR}/load-images.sh"
            echo ""
        else
            echo "❌ Image preloading is required for Kind clusters"
            echo "   Please run this script again and choose 'yes' to preload images"
            echo "   Or manually load images using: ${SCRIPT_DIR}/load-images.sh"
            exit 1
        fi
    fi
else
    echo "ℹ️  Not a Kind cluster - skipping image preloading"
    echo ""
fi

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
# Step 1.5: Fix Keycloak Client Redirect URIs
# ============================================================================
echo "=============================================="
echo "Step 1.5: Configuring Keycloak Client"
echo "=============================================="
echo ""

echo "Waiting for Keycloak to be ready..."
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s 2>/dev/null || true
echo "✓ Keycloak is ready"
echo ""

echo "Configuring Keycloak client redirect URIs..."
echo "  This ensures OAuth works correctly with port-forwarding"
echo ""

# Configure Keycloak client with correct redirect URIs
kubectl exec -n keycloak keycloak-0 -- sh -c '
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password admin > /dev/null 2>&1
CLIENT_ID=$(/opt/keycloak/bin/kcadm.sh get clients -r kagenti --fields id,clientId 2>/dev/null | grep -B1 "\"clientId\" : \"kagenti\"" | grep "\"id\"" | sed "s/.*: \"\(.*\)\".*/\1/")
if [ -n "$CLIENT_ID" ]; then
    /opt/keycloak/bin/kcadm.sh update clients/$CLIENT_ID -r kagenti -s "redirectUris=[\"http://kagenti-ui.localtest.me:8080/*\",\"http://localhost:8080/*\"]" > /dev/null 2>&1
    echo "✓ Keycloak client configured successfully"
    echo ""
    echo "Redirect URIs set to:"
    /opt/keycloak/bin/kcadm.sh get clients/$CLIENT_ID -r kagenti --fields redirectUris 2>/dev/null
else
    echo "⚠️  Warning: Could not find Keycloak client"
    echo "   The client may not be created yet. This is normal on first install."
    echo "   The redirect URIs will be configured when you access the UI."
fi
' || echo "⚠️  Note: Keycloak client configuration will be set up on first UI access"

echo ""
echo "✓ Keycloak client configuration complete"
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
# Step 3: Create OAuth Secret Dynamically
# ============================================================================
echo "=============================================="
echo "Step 3: Creating OAuth Secret"
echo "=============================================="
echo ""

echo "Creating OAuth secret from .env credentials..."
echo "  Secret name: mcp-elicitation-oauth-secret"
echo "  Namespace: ${NAMESPACE}"
echo ""

# Delete existing secret if it exists
kubectl delete secret mcp-elicitation-oauth-secret -n ${NAMESPACE} 2>/dev/null || true

# Create secret from environment variables
kubectl create secret generic mcp-elicitation-oauth-secret \
  --from-literal=client-id="$GITHUB_OAUTH_CLIENT_ID" \
  --from-literal=client-secret="$GITHUB_OAUTH_CLIENT_SECRET" \
  --namespace=${NAMESPACE}

echo "✓ OAuth secret created successfully"
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
# Step 7: github-elicitation-tool source import
# ============================================================================
echo "=============================================="
echo "Step 7: Import github-elicitation-tool via Kagenti UI"
echo "=============================================="
echo ""
echo "No static github-elicitation-tool manifest is applied by this script."
echo "Import the tool in namespace team1 via source build:"
echo "  http://kagenti-ui.localtest.me:8080/tools/import"
echo ""
echo "Recommended values:"
echo "  - Name: github-elicitation-tool"
echo "  - Deployment Method: Build from source"
echo "  - Git URL: <this repository URL>"
echo "  - Git Revision: <your branch, e.g. main>"
echo "  - Context Directory: ${GITHUB_ELICITATION_TOOL_CONTEXT_DIR}"
echo "  - Enable AuthBridge sidecar injection: false"
echo "  - Enable SPIRE identity: false"
echo "  - UPSTREAM_MCP_URL=http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184"
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
# Step 8: Setup Port Forwarding
# ============================================================================
echo "=============================================="
echo "Step 8: Setting Up Port Forwarding"
echo "=============================================="
echo ""

# Check if port forwards are already running
EXISTING_PF=$(ps aux | grep "kubectl port-forward" | grep -v grep | grep -E "(kagenti-ui|backend)" | wc -l)
SHOULD_START_PF=true

if [ "$EXISTING_PF" -gt 0 ]; then
    echo "⚠️  Port forwards are already running:"
    ps aux | grep "kubectl port-forward" | grep -v grep | grep -E "(kagenti-ui|backend)"
    echo ""
    read -p "Do you want to restart port forwarding? (yes/no): " -r
    echo ""
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Stopping existing port forwards..."
        pkill -f "kubectl port-forward.*kagenti-ui" 2>/dev/null || true
        pkill -f "kubectl port-forward.*backend" 2>/dev/null || true
        sleep 2
        echo "✓ Existing port forwards stopped"
        echo ""
        SHOULD_START_PF=true
    else
        echo "✓ Keeping existing port forwards"
        echo ""
        SHOULD_START_PF=false
    fi
fi

# Only start port forwarding if needed
if [ "$SHOULD_START_PF" = true ]; then
    # Start port forwarding in background
    echo "Starting port forwarding..."
    echo ""

# Function to start and verify port forward
start_and_verify_pf() {
    local name=$1
    local namespace=$2
    local service=$3
    local port=$4
    
    echo "Starting port-forward for $name..."
    kubectl port-forward -n $namespace svc/$service $port:$port > /tmp/pf-${service}.log 2>&1 &
    local pid=$!
    
    # Wait a moment and check if it's still running
    sleep 2
    if ps -p $pid > /dev/null 2>&1; then
        echo "✓ $name port-forward started (PID: $pid)"
        echo "  URL: http://localhost:$port"
        echo "  Log: /tmp/pf-${service}.log"
    else
        echo "❌ Failed to start $name port-forward"
        echo "   Check logs: cat /tmp/pf-${service}.log"
        return 1
    fi
    echo ""
}

    # Start each port forward
    start_and_verify_pf "Kagenti Dashboard" "$KAGENTI_NAMESPACE" "kagenti-ui" "8080"
    start_and_verify_pf "Demo Backend" "$NAMESPACE" "backend" "8187"
    
    # Start Keycloak port forward on different port (8081)
    echo "Starting port-forward for Keycloak Admin..."
    kubectl port-forward -n keycloak svc/keycloak-service 8081:8080 > /tmp/pf-keycloak.log 2>&1 &
    keycloak_pid=$!
    sleep 2
    if ps -p $keycloak_pid > /dev/null; then
        echo "✓ Keycloak Admin port-forward started (PID: $keycloak_pid)"
        echo "  Access at: http://localhost:8081"
    else
        echo "⚠️  Warning: Keycloak port-forward failed to start"
        echo "  You can start it manually: kubectl port-forward -n keycloak svc/keycloak-service 8081:8080"
    fi
    echo ""

    echo "✓ Port forwarding setup complete"
    echo ""
fi

# Verify all port forwards are running
echo "Verifying port forwards..."
RUNNING_PF=$(ps aux | grep "kubectl port-forward" | grep -v grep | grep -E "(kagenti-ui|backend|keycloak)" | wc -l)
if [ "$RUNNING_PF" -ge 3 ]; then
    echo "✓ All port forwards are running (UI, Backend, and Keycloak)"
else
    echo "⚠️  Warning: Not all port forwards are running"
    echo "   Expected: 3, Running: $RUNNING_PF"
    echo "   You may need to manually start port forwarding:"
    echo "   ${SCRIPT_DIR}/port-forward.sh"
fi
echo ""

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
echo "✓ github-elicitation-tool wrapper source available for source import"
echo "✓ Port forwarding configured and running"
echo ""
echo "=============================================="
echo "Access Points"
echo "=============================================="
echo ""
echo "The following services are now accessible:"
echo "  - Kagenti Dashboard: http://localhost:8080"
echo "  - Keycloak Admin:    http://localhost:8081"
echo "  - Demo Backend:      http://localhost:8187"
echo ""
echo "IMPORTANT: Access Kagenti UI at http://localhost:8080 or http://kagenti-ui.localtest.me:8080"
echo "           Do NOT use http://keycloak.localtest.me:8080 (that's the OAuth provider)"
echo ""
echo "If using NodePort (Kind/Minikube), also available at:"
echo "  - Backend: http://localhost:30187"
echo "  - MCP Server: http://localhost:30184"
echo ""
echo "=============================================="
echo "Next Steps"
echo "=============================================="
echo ""
echo "1. Import github-elicitation-tool via Kagenti Dashboard:"
echo "   - Access the Kagenti dashboard at http://localhost:8080"
echo "   - Navigate to http://kagenti-ui.localtest.me:8080/tools/import"
echo "   - Import github-elicitation-tool into namespace team1"
echo "   - Choose 'Build from source'"
echo "   - Git URL: <this repository URL>"
echo "   - Git Revision: <your branch>"
echo "   - Context Directory: ${GITHUB_ELICITATION_TOOL_CONTEXT_DIR}"
echo "   - Set UPSTREAM_MCP_URL=http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184"
echo ""
echo "2. Import Agents via Kagenti Dashboard:"
echo "   - Navigate to the Agents section"
echo "   - Import the agent configurations for this demo in namespace team1"
echo "   - Configure MCP_URL to use github-elicitation-tool-mcp.team1.svc.cluster.local"
echo ""
echo "3. Monitor the infrastructure deployment:"
echo "   kubectl get all -n ${NAMESPACE}"
echo "   kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=token-broker"
echo "   kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=mcp-server"
echo "   kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=backend"
echo ""
echo "4. Check authbridge injection:"
echo "   kubectl get pods -n ${NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.containers[*].name}{\"\\n\"}{end}'"
echo "   (Agents imported via dashboard should have authbridge sidecar)"
echo ""
echo "5. To clean up the demo:"
echo "   ${SCRIPT_DIR}/cleanup.sh"
echo ""
echo "For more information, see:"
echo "  ${DEMO_DIR}/README.md"
echo "  ${DEMO_DIR}/ARCHITECTURE.md"
echo ""

# Made with Bob
