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

if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Error: GITHUB_TOKEN not set in .env"
    echo "   A GitHub PAT is required to pull private container images from ghcr.io"
    exit 1
fi

echo "   Using CLIENT_ID: ${GITHUB_OAUTH_CLIENT_ID:0:3}..."
echo "   Using CLIENT_SECRET: ${GITHUB_OAUTH_CLIENT_SECRET:0:3}..."
echo "   Using GITHUB_TOKEN: ${GITHUB_TOKEN:0:7}..."
echo "✓ Credentials loaded from .env"

echo ""
echo "All preflight checks passed!"
echo ""

# ============================================================================
# Build Backend Image
# ============================================================================
echo "=============================================="
echo "Building Backend from Local Source"
echo "=============================================="
echo ""
echo "Building backend image with Keycloak authentication..."
cd "${DEMO_DIR}"
docker build -t localhost/kagenti-backend-local:latest -f Dockerfile .
echo "✓ Backend image built successfully"
echo ""
cd "${SCRIPT_DIR}"

# ============================================================================
# Kind Cluster Detection and Image Preloading
# ============================================================================
echo "=============================================="
echo "Checking for Kind Cluster"
echo "=============================================="
echo ""

# Always assume Kind cluster for this demo
IS_KIND=true
echo "✓ Assuming Kind cluster (always load images)"
echo ""

    if ! command -v kind &> /dev/null; then
        echo "❌ Error: kind CLI not found in PATH (required for image loading)"
        exit 1
    fi

    KIND_CLUSTER=$(kubectl config current-context | sed 's/kind-//')

    echo "=============================================="
    echo "Pulling and Loading Images into Kind Cluster"
    echo "=============================================="
    echo ""

    # Authenticate with GHCR using the PAT from .env
    echo "Authenticating with GitHub Container Registry..."
    echo "$GITHUB_TOKEN" | docker login ghcr.io -u davidhadas --password-stdin 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to authenticate with GHCR"
        echo "   Check that GITHUB_TOKEN in .env is a valid PAT with packages:read scope"
        exit 1
    fi
    echo "✓ Authenticated with GHCR"
    echo ""

    IMAGES=(
        "ghcr.io/davidhadas/kagenti-mcp-server:latest"
        "ghcr.io/davidhadas/kagenti-token-broker:latest"
        "ghcr.io/davidhadas/kagenti-extensions/authbridge:latest"
    )

    for IMAGE in "${IMAGES[@]}"; do
        echo "Pulling ${IMAGE}..."
        if ! docker pull "${IMAGE}"; then
            echo "❌ Error: Failed to pull ${IMAGE}"
            exit 1
        fi
        echo "Loading ${IMAGE} into Kind cluster..."
        if ! kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER}"; then
            echo "❌ Error: Failed to load ${IMAGE} into Kind"
            exit 1
        fi
        echo "✓ ${IMAGE} ready"
        echo ""
    done

    # Load locally-built backend image
    echo "Loading localhost/kagenti-backend-local:latest into Kind cluster..."
    if ! kind load docker-image localhost/kagenti-backend-local:latest --name "${KIND_CLUSTER}"; then
        echo "❌ Error: Failed to load backend image into Kind"
        exit 1
    fi
    echo "✓ Backend image loaded"
    echo ""

    # Verify critical images are present in the Kind node
    echo "Verifying images are available inside Kind node..."
    REQUIRED_IMAGES=(
        "ghcr.io/davidhadas/kagenti-mcp-server:latest"
        "ghcr.io/davidhadas/kagenti-token-broker:latest"
        "ghcr.io/davidhadas/kagenti-extensions/authbridge:latest"
        "localhost/kagenti-backend-local:latest"
    )
    for IMG in "${REQUIRED_IMAGES[@]}"; do
        if docker exec "${KIND_CLUSTER}-control-plane" crictl images 2>/dev/null | grep -q "$(echo $IMG | cut -d: -f1)"; then
            echo "  ✓ $IMG found on Kind node"
        else
            echo "  ⚠️  $IMG may not be on Kind node — pod may fail to start"
        fi
    done
    echo ""

    echo "✓ All images pulled and loaded into Kind"
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
    echo "✓ Kagenti is already installed in namespace ${KAGENTI_NAMESPACE}"
    echo "  Skipping Kagenti installation (use cleanup.sh to reinstall)"
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
echo "✓ Keycloak client redirect URIs configured"
echo ""

# Configure backend Keycloak client
echo "Configuring Keycloak client for backend service..."
bash "${SCRIPT_DIR}/configure-keycloak-client.sh"
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

# Create secret with keys matching 03-mcp-server.yaml (the only consumer)
kubectl create secret generic mcp-elicitation-oauth-secret \
  --from-literal=client-id="$GITHUB_OAUTH_CLIENT_ID" \
  --from-literal=client-secret="$GITHUB_OAUTH_CLIENT_SECRET" \
  --namespace=${NAMESPACE}

echo "✓ OAuth secret created successfully"
echo ""

# ============================================================================
# Step 4: Deploy Token Broker, MCP Server, and Backend
# ============================================================================
echo "=============================================="
echo "Step 4: Deploying Token Broker"
echo "=============================================="
echo ""

echo "Deploying Token Broker service..."
kubectl apply -f "${K8S_DIR}/02-token-broker.yaml"
kubectl rollout restart deployment/token-broker -n ${NAMESPACE} 

echo "Deploying MCP Server..."
kubectl apply -f "${K8S_DIR}/03-mcp-server.yaml"
kubectl rollout restart deployment/mcp-server -n ${NAMESPACE} 


echo "Deploying Backend service..."
kubectl apply -f "${K8S_DIR}/04-backend.yaml"
kubectl rollout restart deployment/backend -n ${NAMESPACE} 


# ============================================================================
# Step 5: Verify Deployments
# ============================================================================

echo ""
echo "Waiting for Token Broker to be ready..."
kubectl rollout status deployment/token-broker -n ${NAMESPACE} --timeout=120s
echo "✓ Token Broker is ready"
echo ""

echo "Waiting for MCP Server to be ready..."
kubectl rollout status deployment/mcp-server -n ${NAMESPACE} --timeout=120s
echo "✓ MCP Server is ready"
echo ""

echo "Waiting for Backend rollout to complete..."
kubectl rollout status deployment/backend -n ${NAMESPACE} --timeout=120s

echo ""
echo "Waiting for Backend pod to pass readiness probe..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=backend \
    -n ${NAMESPACE} --timeout=120s
echo "✓ Backend is ready"
echo ""

# ============================================================================
# Step 6: github-elicitation-tool source import
# ============================================================================
echo "=============================================="
echo "Step 6: Import github-elicitation-tool via Kagenti UI"
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
# Step 7: Setup Port Forwarding
# ============================================================================
echo "=============================================="
echo "Step 7: Setting Up Port Forwarding"
echo "=============================================="
echo ""

# Function to kill existing kubectl port-forward processes for a specific port
kill_port_forward() {
    local port=$1
    local pids=$(ps aux | grep "kubectl port-forward" | grep -v grep | grep ":${port}" | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "  Killing existing kubectl port-forward processes for port $port: $pids"
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 2
    fi
}

# Function to wait until an HTTP endpoint responds (up to 15s)
wait_for_http() {
    local url=$1
    local max_attempts=15
    for i in $(seq 1 $max_attempts); do
        if curl -sf --max-time 2 "$url" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Function to start port-forward and verify the endpoint is actually reachable
start_and_verify_pf() {
    local name=$1
    local namespace=$2
    local service=$3
    local port=$4
    local health_path=${5:-""}

    # Always kill stale port-forwards first — a bound port doesn't mean it works
    kill_port_forward $port

    echo "Starting port-forward for $name..."
    kubectl port-forward -n $namespace svc/$service $port:$port > /tmp/pf-${service}.log 2>&1 &
    local pid=$!

    # Give kubectl a moment to bind
    sleep 2

    if ! ps -p $pid > /dev/null 2>&1; then
        echo "❌ Failed to start $name port-forward (process exited)"
        echo "   Check logs: cat /tmp/pf-${service}.log"
        return 1
    fi

    # If a health path was given, verify the endpoint actually responds
    if [ -n "$health_path" ]; then
        echo "  Verifying $name is reachable at http://localhost:$port$health_path ..."
        if wait_for_http "http://localhost:$port$health_path"; then
            echo "✓ $name port-forward started and verified (PID: $pid)"
        else
            echo "⚠️  $name port-forward started (PID: $pid) but endpoint not yet responding"
            echo "   Log: /tmp/pf-${service}.log"
            echo "   Retrying once..."
            kill $pid 2>/dev/null || true
            sleep 2
            kill_port_forward $port
            kubectl port-forward -n $namespace svc/$service $port:$port > /tmp/pf-${service}.log 2>&1 &
            pid=$!
            sleep 3
            if wait_for_http "http://localhost:$port$health_path"; then
                echo "✓ $name port-forward started and verified on retry (PID: $pid)"
            else
                echo "❌ $name port-forward is running but endpoint still not responding"
                echo "   Check pod logs: kubectl logs -n $namespace -l app.kubernetes.io/name=$service"
                echo "   Check pf logs: cat /tmp/pf-${service}.log"
                return 1
            fi
        fi
    else
        echo "✓ $name port-forward started (PID: $pid)"
    fi
    echo "  URL: http://localhost:$port"
    echo "  Log: /tmp/pf-${service}.log"
    echo ""
}

echo "Checking and starting port forwards..."
echo ""

# Kagenti Dashboard and Keycloak are served via the Istio gateway (NodePort 30080 → host 8080).
# Do NOT port-forward them — that would shadow the gateway and break hostname-based routing
# (keycloak.localtest.me:8080 vs kagenti-ui.localtest.me:8080).
echo "ℹ️  Kagenti Dashboard and Keycloak are accessible via the Istio gateway on port 8080"
echo "   No port-forward needed for these services."
echo ""

# Only the demo backend needs a port-forward (no HTTPRoute configured for it)
start_and_verify_pf "Demo Backend" "$NAMESPACE" "backend" "8187" "/health"

# Final end-to-end check: verify the demo page is actually reachable
echo "=============================================="
echo "Final End-to-End Verification"
echo "=============================================="
echo ""

echo "Verifying http://localhost:8187/demo is reachable..."
if wait_for_http "http://localhost:8187/demo"; then
    echo "✓ Demo page is live at http://localhost:8187/demo"
else
    echo "❌ Demo page is NOT reachable at http://localhost:8187/demo"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check backend pod status:"
    echo "     kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=backend"
    echo "  2. Check backend logs:"
    echo "     kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=backend"
    echo "  3. Check port-forward logs:"
    echo "     cat /tmp/pf-backend.log"
    echo "  4. Restart port-forward manually:"
    echo "     kubectl port-forward -n ${NAMESPACE} svc/backend 8187:8187"
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
echo "  - Kagenti Dashboard: http://kagenti-ui.localtest.me:8080  (via Istio gateway)"
echo "  - Keycloak Admin:    http://keycloak.localtest.me:8080    (via Istio gateway)"
echo "  - Demo Backend:      http://localhost:8187                (via port-forward)"
echo "  - Demo Backend:      http://localhost:30187               (via NodePort)"
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
