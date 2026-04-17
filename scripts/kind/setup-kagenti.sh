#!/usr/bin/env bash
# ============================================================================
# KAGENTI PLATFORM SETUP FOR KIND
# ============================================================================
# Installs the Kagenti stack on a local Kind cluster. Composable: core
# components are always installed, optional layers enabled via --with-* flags.
#
# Core (always):   cert-manager, Keycloak, kagenti-operator, kagenti-webhook
# Optional:        --with-istio, --with-spire, --with-backend (UI+API),
#                  --with-mcp-gateway, --with-otel, --with-builds, --with-all
#
# Idempotent: safe to re-run. Uses helm upgrade --install and kubectl apply.
# Re-running with additional --with-* flags adds components incrementally.
#
# Usage:
#   scripts/kind/setup-kagenti.sh                          # Core only
#   scripts/kind/setup-kagenti.sh --with-all               # Everything
#   scripts/kind/setup-kagenti.sh --with-istio --with-ui   # Core + Istio + UI
#   scripts/kind/setup-kagenti.sh --skip-cluster           # Reuse existing cluster
#   scripts/kind/setup-kagenti.sh --cluster-name my-test   # Custom cluster name
#
# Prerequisites: kind, helm (v3), kubectl
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-kagenti}"
KIND_CONFIG="${KIND_CONFIG:-$REPO_ROOT/deployments/ansible/kind/kind-config-registry.yaml}"
DOMAIN="localtest.me"

# Component flags (core is always true)
WITH_ISTIO=false
WITH_SPIRE=false
WITH_BACKEND=false
WITH_MCP_GATEWAY=false
WITH_OTEL=false
WITH_BUILDS=false
SKIP_CLUSTER=false
DRY_RUN=false
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

# Versions — keep in sync with deployments/ansible/default_values.yaml
CERT_MANAGER_VERSION="v1.17.2"
ISTIO_VERSION="1.28.0"
SPIRE_CRD_VERSION="0.5.0"
SPIRE_VERSION="0.27.0"
GATEWAY_API_VERSION="v1.4.0"
TEKTON_VERSION="v0.66.0"
SHIPWRIGHT_VERSION="v0.14.0"
MCP_GATEWAY_VERSION="0.5.0"

# ── Colors & logging ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

run_cmd() {
  if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-istio)       WITH_ISTIO=true; shift ;;
    --with-spire)       WITH_SPIRE=true; shift ;;
    --with-backend)     WITH_BACKEND=true; shift ;;
    --with-ui)          WITH_BACKEND=true; shift ;;
    --with-mcp-gateway) WITH_MCP_GATEWAY=true; shift ;;
    --with-kuadrant)    WITH_MCP_GATEWAY=true; shift ;;
    --with-otel)        WITH_OTEL=true; shift ;;
    --with-builds)      WITH_BUILDS=true; shift ;;
    --with-all)
      WITH_ISTIO=true; WITH_SPIRE=true; WITH_BACKEND=true
      WITH_MCP_GATEWAY=true; WITH_OTEL=true; WITH_BUILDS=true
      shift ;;
    --skip-cluster)     SKIP_CLUSTER=true; shift ;;
    --cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
    --domain)           DOMAIN="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Component flags:"
      echo "  --with-istio        Install Istio ambient mesh"
      echo "  --with-spire        Install SPIRE + SPIFFE IdP setup"
      echo "  --with-backend      Install Kagenti backend API + UI"
      echo "  --with-ui           Alias for --with-backend"
      echo "  --with-mcp-gateway  Install MCP Gateway (Kuadrant)"
      echo "  --with-kuadrant     Alias for --with-mcp-gateway"
      echo "  --with-otel         Install OpenTelemetry collector"
      echo "  --with-builds       Install Tekton + Shipwright"
      echo "  --with-all          Enable all optional components"
      echo ""
      echo "Other options:"
      echo "  --skip-cluster      Don't create Kind cluster (reuse existing)"
      echo "  --cluster-name NAME Kind cluster name (default: kagenti)"
      echo "  --domain DOMAIN     Domain for services (default: localtest.me)"
      echo "  --dry-run           Show commands without executing"
      echo "  -h, --help          Show this help"
      exit 0 ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Pre-flight ──────────────────────────────────────────────────────────────
START_SECONDS=$SECONDS

echo ""
echo "============================================"
echo "  Kagenti Platform Setup (Kind)"
echo "============================================"
echo ""
echo "  Cluster:       $CLUSTER_NAME"
echo "  Domain:        $DOMAIN"
echo "  Components:"
echo "    Core:          cert-manager, Keycloak, operator, webhook"
echo "    Istio:         $WITH_ISTIO"
echo "    SPIRE:         $WITH_SPIRE"
echo "    Backend/UI:    $WITH_BACKEND"
echo "    MCP Gateway:   $WITH_MCP_GATEWAY"
echo "    OTel:          $WITH_OTEL"
echo "    Builds:        $WITH_BUILDS"
echo "    Skip cluster:  $SKIP_CLUSTER"
echo ""

for cmd in helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "$cmd not found in PATH"
    exit 1
  fi
done
log_success "helm found: $(helm version --short 2>/dev/null || echo unknown)"
log_success "kubectl found"

if ! $SKIP_CLUSTER; then
  if ! command -v kind &>/dev/null; then
    log_error "kind not found in PATH (use --skip-cluster to reuse existing cluster)"
    exit 1
  fi
  log_success "kind found"
fi

# Validate chart directories exist
if [ ! -d "$REPO_ROOT/charts/kagenti-deps" ] || [ ! -d "$REPO_ROOT/charts/kagenti" ]; then
  log_error "Charts not found. Run this script from the kagenti repo root."
  exit 1
fi
echo ""

# ── Helpers ─────────────────────────────────────────────────────────────────
_wait_deployment_ready() {
  local deploy="$1" ns="$2" label="${3:-$1}" timeout="${4:-300s}"
  if $DRY_RUN; then return; fi
  if ! kubectl get deployment/"$deploy" -n "$ns" &>/dev/null; then
    log_info "Waiting for $label to appear..."
    local tries=0
    until kubectl get deployment/"$deploy" -n "$ns" &>/dev/null; do
      [ $((++tries)) -ge 60 ] && { log_warn "$label not found after 5m"; return 1; }
      sleep 5
    done
  fi
  log_info "Waiting for $label rollout..."
  kubectl rollout status deployment/"$deploy" -n "$ns" --timeout="$timeout" || \
    log_warn "$label rollout not ready within timeout"
}

# ============================================================================
# Step 1: Create Kind Cluster
# ============================================================================
log_info "Step 1: Kind Cluster"

if $SKIP_CLUSTER; then
  log_info "Skipped (--skip-cluster)"
  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to cluster. Set KUBECONFIG or create a cluster first."
    exit 1
  fi
else
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_success "Cluster '$CLUSTER_NAME' already exists — reusing"
  else
    log_info "Creating Kind cluster '$CLUSTER_NAME'..."
    run_cmd kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    log_success "Cluster created"
  fi
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null || true
echo ""

# ============================================================================
# Step 2: Install cert-manager (core — required by webhook TLS)
# ============================================================================
log_info "Step 2: cert-manager"

if kubectl get deployment cert-manager-webhook -n cert-manager &>/dev/null; then
  log_success "cert-manager already installed — skipping"
else
  log_info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
  run_cmd kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  _wait_deployment_ready cert-manager-webhook cert-manager cert-manager
  log_success "cert-manager installed"
fi
echo ""

# ============================================================================
# Step 3: Install Istio ambient mesh (optional)
# ============================================================================
log_info "Step 3: Istio"

if $WITH_ISTIO; then
  log_info "Installing Istio ${ISTIO_VERSION} (ambient)..."
  ISTIO_REPO="https://istio-release.storage.googleapis.com/charts/"

  run_cmd helm upgrade --install istio-base base \
    --repo "$ISTIO_REPO" --version "$ISTIO_VERSION" \
    -n istio-system --create-namespace --wait

  run_cmd helm upgrade --install istiod istiod \
    --repo "$ISTIO_REPO" --version "$ISTIO_VERSION" \
    -n istio-system --wait \
    --set profile=ambient

  run_cmd helm upgrade --install istio-cni cni \
    --repo "$ISTIO_REPO" --version "$ISTIO_VERSION" \
    -n istio-system --wait \
    --set profile=ambient

  run_cmd helm upgrade --install ztunnel ztunnel \
    --repo "$ISTIO_REPO" --version "$ISTIO_VERSION" \
    -n istio-system --wait

  # Label for shared gateway access
  kubectl label namespace istio-system shared-gateway-access=true --overwrite 2>/dev/null || true
  log_success "Istio installed"
else
  log_info "Skipped (use --with-istio)"
fi
echo ""

# ============================================================================
# Step 3b: Install Tekton (optional, --with-builds)
# ============================================================================
if $WITH_BUILDS; then
  log_info "Step 3b: Tekton"
  log_info "Installing Tekton ${TEKTON_VERSION}..."
  run_cmd kubectl apply --server-side \
    -f "https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_VERSION}/release.yaml"
  log_success "Tekton applied"
  echo ""
fi

# ============================================================================
# Step 4: Install SPIRE (optional)
# ============================================================================
log_info "Step 4: SPIRE"

if $WITH_SPIRE; then
  SPIRE_REPO="https://spiffe.github.io/helm-charts-hardened/"

  log_info "Installing SPIRE CRDs ${SPIRE_CRD_VERSION}..."
  run_cmd helm upgrade --install spire-crds spire-crds \
    --repo "$SPIRE_REPO" --version "$SPIRE_CRD_VERSION" \
    -n spire-mgmt --create-namespace --wait

  log_info "Installing SPIRE ${SPIRE_VERSION}..."
  run_cmd helm upgrade --install spire spire \
    --repo "$SPIRE_REPO" --version "$SPIRE_VERSION" \
    -n spire-mgmt --create-namespace \
    --set global.spire.recommendations.enabled=true \
    --set global.spire.namespaces.create=true \
    --set global.spire.namespaces.server.name=zero-trust-workload-identity-manager \
    --set global.spire.namespaces.server.create=true \
    --set-string "global.spire.namespaces.server.labels.shared-gateway-access=true" \
    --set global.spire.ingressControllerType="" \
    --set global.spire.clusterName=agent-platform \
    --set "global.spire.trustDomain=${DOMAIN}" \
    --set "global.spire.caSubject.country=US" \
    --set "global.spire.caSubject.organization=AgenticPlatformDemo" \
    --set "global.spire.caSubject.commonName=${DOMAIN}" \
    --set spire-server.tornjak.enabled=true \
    --set "spire-server.controllerManager.ignoreNamespaces={kube-system,kube-public}" \
    --set spire-server.controllerManager.identities.clusterSPIFFEIDs.default.autoPopulateDNSNames=true \
    --set spire-server.controllerManager.identities.clusterSPIFFEIDs.default.jwtTTL=5m \
    --set spiffe-oidc-discovery-provider.enabled=true \
    --set spiffe-oidc-discovery-provider.config.set_key_use=true \
    --set spiffe-oidc-discovery-provider.tls.spire.enabled=false \
    --set tornjak-frontend.enabled=true \
    --set tornjak-frontend.image.tag=v2.0.0 \
    --set tornjak-frontend.ingress.enabled=true \
    --set "tornjak-frontend.apiServerURL=http://spire-tornjak-api.${DOMAIN}:8080" \
    --set tornjak-frontend.service.type=ClusterIP \
    --set tornjak-frontend.service.port=3000

  log_success "SPIRE installed"
else
  log_info "Skipped (use --with-spire)"
fi
echo ""

# ============================================================================
# Step 5: Install Gateway API CRDs
# ============================================================================
# Always required: kagenti-deps chart creates HTTPRoute resources (e.g. Keycloak)
log_info "Step 5: Gateway API CRDs"
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  log_success "Gateway API CRDs already installed"
else
  log_info "Installing Gateway API ${GATEWAY_API_VERSION}..."
  run_cmd kubectl apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  log_success "Gateway API CRDs installed"
fi
echo ""

# ============================================================================
# Step 6: Install kagenti-deps chart (core: Keycloak + toggles)
# ============================================================================
log_info "Step 6: kagenti-deps"

log_info "Updating kagenti-deps chart dependencies..."
run_cmd helm dependency update "$REPO_ROOT/charts/kagenti-deps/"

DEPS_FLAGS=(
  --set "openshift=false"
  --set "domain=${DOMAIN}"
  # Core: Keycloak always on
  --set "components.keycloak.enabled=true"
  # cert-manager CRDs are installed in Step 2 — disable the subchart
  --set "components.certManager.enabled=false"
  # Components toggled by flags
  --set "components.istio.enabled=false"
  --set "components.spire.enabled=false"
  --set "components.otel.enabled=${WITH_OTEL}"
  --set "components.metricsServer.enabled=${WITH_BACKEND}"
  --set "components.containerRegistry.enabled=${WITH_BUILDS}"
  --set "components.ingressGateway.enabled=${WITH_ISTIO}"
  --set "components.mcpInspector.enabled=${WITH_MCP_GATEWAY}"
  --set "components.tekton.enabled=false"
  --set "components.shipwright.enabled=false"
  --set "components.kiali.enabled=false"
  --set "components.phoenix.enabled=false"
  --set "components.mlflow.enabled=false"
  --set "components.rhoai.enabled=false"
)

log_info "Installing kagenti-deps..."
run_cmd helm upgrade --install kagenti-deps "$REPO_ROOT/charts/kagenti-deps/" \
  -n kagenti-system --create-namespace --wait --timeout 20m \
  "${DEPS_FLAGS[@]}"

# Label kagenti-system for shared gateway access
kubectl label namespace kagenti-system shared-gateway-access=true --overwrite 2>/dev/null || true

log_success "kagenti-deps installed"
echo ""

# ── Configure Kind node to reach in-cluster container registry ──────────────
if $WITH_BUILDS && ! $SKIP_CLUSTER; then
  REGISTRY_NAME="registry"
  REGISTRY_NS="cr-system"
  REGISTRY_HOST="${REGISTRY_NAME}.${REGISTRY_NS}.svc.cluster.local"
  REGISTRY_HOST_PORT="${REGISTRY_HOST}:5000"

  log_info "Configuring Kind node to reach in-cluster registry (${REGISTRY_HOST_PORT})..."

  if ! $DRY_RUN; then
    CLUSTER_IP=$(kubectl get svc "$REGISTRY_NAME" -n "$REGISTRY_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -n "$CLUSTER_IP" ]; then
      # Add registry DNS to Kind node's /etc/hosts
      $CONTAINER_ENGINE exec "${CLUSTER_NAME}-control-plane" \
        sh -c "echo '${CLUSTER_IP} ${REGISTRY_HOST}' >> /etc/hosts"

      # Configure containerd registry mirror for insecure in-cluster registry
      $CONTAINER_ENGINE exec "${CLUSTER_NAME}-control-plane" sh -c "
        mkdir -p /etc/containerd/certs.d/${REGISTRY_HOST_PORT}
        cat > /etc/containerd/certs.d/${REGISTRY_HOST_PORT}/hosts.toml <<TOML
server = \"http://${REGISTRY_HOST_PORT}\"

[host.\"http://${REGISTRY_HOST_PORT}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
  skip_verify = true
TOML
      "
      log_success "Kind registry DNS configured (${CLUSTER_IP} -> ${REGISTRY_HOST})"
    else
      log_warn "Could not resolve registry ClusterIP — registry DNS not configured"
    fi
  fi
  echo ""
fi

# ============================================================================
# Step 6b: Install Shipwright (optional, --with-builds, after cert-manager)
# ============================================================================
if $WITH_BUILDS; then
  log_info "Step 6b: Shipwright"

  log_info "Installing Shipwright ${SHIPWRIGHT_VERSION}..."
  run_cmd kubectl apply --server-side \
    -f "https://github.com/shipwright-io/build/releases/download/${SHIPWRIGHT_VERSION}/release.yaml"

  if ! $DRY_RUN; then
    kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/shipwright-build --timeout=30s 2>/dev/null || true

    # cert-manager resources for webhook TLS
    kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: shipwright-selfsigned-issuer
spec:
  selfSigned: {}
EOF
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shipwright-ca
  namespace: shipwright-build
spec:
  isCA: true
  commonName: shipwright-ca
  secretName: shipwright-ca-secret
  duration: 26280h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: shipwright-selfsigned-issuer
    kind: ClusterIssuer
EOF
    kubectl wait --for=condition=Ready certificate/shipwright-ca \
      -n shipwright-build --timeout=60s 2>/dev/null || true

    kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: shipwright-ca-issuer
  namespace: shipwright-build
spec:
  ca:
    secretName: shipwright-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shipwright-build-webhook-cert
  namespace: shipwright-build
spec:
  secretName: shipwright-build-webhook-cert
  duration: 8760h
  renewBefore: 720h
  dnsNames:
    - shp-build-webhook
    - shp-build-webhook.shipwright-build
    - shp-build-webhook.shipwright-build.svc
    - shp-build-webhook.shipwright-build.svc.cluster.local
  issuerRef:
    name: shipwright-ca-issuer
    kind: Issuer
EOF
    kubectl wait --for=condition=Ready certificate/shipwright-build-webhook-cert \
      -n shipwright-build --timeout=60s 2>/dev/null || true

    # Annotate CRDs for CA injection
    for crd in clusterbuildstrategies.shipwright.io buildstrategies.shipwright.io \
               builds.shipwright.io buildruns.shipwright.io; do
      kubectl annotate crd "$crd" \
        cert-manager.io/inject-ca-from=shipwright-build/shipwright-build-webhook-cert \
        --overwrite 2>/dev/null || true
    done

    # Restart webhook to pick up TLS
    kubectl rollout restart deployment/shipwright-build-webhook -n shipwright-build 2>/dev/null || true
    _wait_deployment_ready shipwright-build-webhook shipwright-build "Shipwright webhook"

    # Install sample build strategies
    kubectl apply --server-side \
      -f "https://github.com/shipwright-io/build/releases/download/${SHIPWRIGHT_VERSION}/sample-strategies.yaml" \
      2>/dev/null || true
  fi

  log_success "Shipwright installed"
  echo ""
fi

# ============================================================================
# Step 7: SPIRE post-install (OIDC patch + SPIFFE IdP setup job)
# ============================================================================
if $WITH_SPIRE && ! $DRY_RUN; then
  log_info "Step 7: SPIRE post-install"

  SPIRE_SERVER_NS="zero-trust-workload-identity-manager"
  KAGENTI_NS="kagenti-system"

  # 7a: Patch SPIRE OIDC ConfigMap to add set_key_use if missing
  log_info "Checking SPIRE OIDC ConfigMap..."
  tries=0
  while ! kubectl get configmap spire-spiffe-oidc-discovery-provider \
    -n "$SPIRE_SERVER_NS" &>/dev/null; do
    tries=$((tries + 1))
    [ $tries -ge 90 ] && { log_warn "SPIRE OIDC ConfigMap not found after 3m"; break; }
    sleep 2
  done

  if kubectl get configmap spire-spiffe-oidc-discovery-provider -n "$SPIRE_SERVER_NS" &>/dev/null; then
    OIDC_CONF=$(kubectl get configmap spire-spiffe-oidc-discovery-provider \
      -n "$SPIRE_SERVER_NS" \
      -o jsonpath='{.data.oidc-discovery-provider\.conf}' 2>/dev/null || echo "")
    if [ -n "$OIDC_CONF" ] && ! echo "$OIDC_CONF" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('set_key_use') else 1)" 2>/dev/null; then
      log_info "Patching OIDC ConfigMap with set_key_use: true..."
      PATCHED=$(echo "$OIDC_CONF" | python3 -c "import sys,json; d=json.load(sys.stdin); d['set_key_use']=True; json.dump(d,sys.stdout)")
      kubectl get configmap spire-spiffe-oidc-discovery-provider -n "$SPIRE_SERVER_NS" -o json | \
        python3 -c "
import sys, json
cm = json.load(sys.stdin)
cm['data']['oidc-discovery-provider.conf'] = '''$PATCHED'''
json.dump(cm, sys.stdout)
" | kubectl apply -f -
      kubectl rollout restart deployment/spire-spiffe-oidc-discovery-provider -n "$SPIRE_SERVER_NS"
      kubectl rollout status deployment/spire-spiffe-oidc-discovery-provider \
        -n "$SPIRE_SERVER_NS" --timeout=120s || true
      log_success "OIDC ConfigMap patched"
    else
      log_success "OIDC ConfigMap already has set_key_use"
    fi
  fi

  # 7b: Run SPIFFE IdP setup job (configures Keycloak with SPIRE identity provider)
  log_info "Setting up SPIFFE IdP..."

  # Get kagenti-deps values for image/config references
  KC_URL=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('keycloak',{}).get('url','http://keycloak-service.keycloak:8080'))" 2>/dev/null \
    || echo "http://keycloak-service.keycloak:8080")
  KC_REALM=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('keycloak',{}).get('realm','kagenti'))" 2>/dev/null \
    || echo "kagenti")
  KC_NS=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('keycloak',{}).get('namespace','keycloak'))" 2>/dev/null \
    || echo "keycloak")
  KC_ADMIN_SECRET=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('keycloak',{}).get('adminSecretName','keycloak-initial-admin'))" 2>/dev/null \
    || echo "keycloak-initial-admin")
  SPIFFE_IDP_IMAGE=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; v=json.load(sys.stdin); print(v.get('spiffeIdp',{}).get('image',{}).get('repository','ghcr.io/kagenti/kagenti/spiffe-idp-setup') + ':' + str(v.get('spiffeIdp',{}).get('image',{}).get('tag','latest')))" 2>/dev/null \
    || echo "ghcr.io/kagenti/kagenti/spiffe-idp-setup:latest")
  KUBECTL_IMAGE=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('common',{}).get('kubectlImage','quay.io/kubestellar/kubectl:1.30.14'))" 2>/dev/null \
    || echo "quay.io/kubestellar/kubectl:1.30.14")
  SPIFFE_IDP_ALIAS=$(helm get values kagenti-deps -n "$KAGENTI_NS" --all -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('authBridge',{}).get('spiffeIdpAlias','spire-spiffe'))" 2>/dev/null \
    || echo "spire-spiffe")

  # Create RBAC for the setup job
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kagenti-spiffe-idp-setup
  namespace: ${KAGENTI_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagenti-spiffe-idp-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["${KC_ADMIN_SECRET}"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagenti-spiffe-idp-keycloak-reader
  namespace: ${KC_NS}
subjects:
  - kind: ServiceAccount
    name: kagenti-spiffe-idp-setup
    namespace: ${KAGENTI_NS}
roleRef:
  kind: ClusterRole
  name: kagenti-spiffe-idp-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kagenti-spiffe-idp-pod-reader
  namespace: ${SPIRE_SERVER_NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagenti-spiffe-idp-pod-reader
  namespace: ${SPIRE_SERVER_NS}
subjects:
  - kind: ServiceAccount
    name: kagenti-spiffe-idp-setup
    namespace: ${KAGENTI_NS}
roleRef:
  kind: Role
  name: kagenti-spiffe-idp-pod-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kagenti-spiffe-idp-pod-reader
  namespace: ${KC_NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagenti-spiffe-idp-pod-reader
  namespace: ${KC_NS}
subjects:
  - kind: ServiceAccount
    name: kagenti-spiffe-idp-setup
    namespace: ${KAGENTI_NS}
roleRef:
  kind: Role
  name: kagenti-spiffe-idp-pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

  # Delete existing job (jobs are immutable)
  kubectl delete job kagenti-spiffe-idp-setup-job -n "$KAGENTI_NS" --ignore-not-found 2>/dev/null || true

  # Create the setup job
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kagenti-spiffe-idp-setup-job
  namespace: ${KAGENTI_NS}
spec:
  backoffLimit: 10
  template:
    metadata:
      labels:
        app: kagenti-spiffe-idp-setup
    spec:
      serviceAccountName: kagenti-spiffe-idp-setup
      restartPolicy: OnFailure
      initContainers:
        - name: wait-for-spire
          image: "${KUBECTL_IMAGE}"
          command: ["sh", "-c"]
          args:
            - |
              echo "Waiting for SPIRE server..."
              kubectl wait --for=condition=ready pod \
                -l app.kubernetes.io/name=server \
                -n ${SPIRE_SERVER_NS} --timeout=300s
              echo "Waiting for SPIRE OIDC discovery provider..."
              kubectl wait --for=condition=ready pod \
                -l app.kubernetes.io/name=spiffe-oidc-discovery-provider \
                -n ${SPIRE_SERVER_NS} --timeout=300s
      containers:
        - name: setup-spiffe-idp
          image: "${SPIFFE_IDP_IMAGE}"
          env:
            - name: KEYCLOAK_BASE_URL
              value: "${KC_URL}"
            - name: KEYCLOAK_REALM
              value: "${KC_REALM}"
            - name: KEYCLOAK_NAMESPACE
              value: "${KC_NS}"
            - name: KEYCLOAK_ADMIN_SECRET_NAME
              value: "${KC_ADMIN_SECRET}"
            - name: KEYCLOAK_ADMIN_USERNAME_KEY
              value: "username"
            - name: KEYCLOAK_ADMIN_PASSWORD_KEY
              value: "password"
            - name: SPIFFE_TRUST_DOMAIN
              value: "spiffe://${DOMAIN}"
            - name: SPIFFE_BUNDLE_ENDPOINT
              value: "http://spire-spiffe-oidc-discovery-provider.${SPIRE_SERVER_NS}.svc.cluster.local/keys"
            - name: SPIFFE_IDP_ALIAS
              value: "${SPIFFE_IDP_ALIAS}"
EOF

  # Wait for job to complete
  log_info "Waiting for SPIFFE IdP setup job..."
  tries=0
  while true; do
    SUCCEEDED=$(kubectl get job kagenti-spiffe-idp-setup-job -n "$KAGENTI_NS" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
    [ "$SUCCEEDED" = "1" ] && break
    tries=$((tries + 1))
    if [ $tries -ge 60 ]; then
      log_warn "SPIFFE IdP setup job did not complete in 5m — check logs:"
      log_warn "  kubectl logs -n $KAGENTI_NS job/kagenti-spiffe-idp-setup-job"
      break
    fi
    sleep 5
  done
  [ "$SUCCEEDED" = "1" ] && log_success "SPIFFE IdP setup complete"
  echo ""
fi

# ============================================================================
# Step 8: Install kagenti chart (operator + webhook + optional UI)
# ============================================================================
log_info "Step 8: kagenti"

# Detect latest release tag for UI images
KAGENTI_TAG="latest"
if $WITH_BACKEND; then
  log_info "Detecting latest kagenti release tag..."
  DETECTED_TAG=$(git ls-remote --tags --sort="v:refname" https://github.com/kagenti/kagenti.git 2>/dev/null | \
    tail -n1 | sed 's|.*refs/tags/||; s/\^{}//' || echo "")
  if [ -n "$DETECTED_TAG" ]; then
    KAGENTI_TAG="$DETECTED_TAG"
    log_success "Using tag: $KAGENTI_TAG"
  else
    log_warn "Could not detect latest tag — using 'latest'"
  fi
fi

# Secrets file
SECRETS_FILE="$REPO_ROOT/charts/kagenti/.secrets.yaml"
SECRETS_TEMPLATE="$REPO_ROOT/charts/kagenti/.secrets_template.yaml"
SECRETS_FLAGS=()
if [ -f "$SECRETS_FILE" ]; then
  SECRETS_FLAGS=(-f "$SECRETS_FILE")
elif [ -f "$SECRETS_TEMPLATE" ]; then
  log_info "Creating .secrets.yaml from template"
  cp "$SECRETS_TEMPLATE" "$SECRETS_FILE"
  SECRETS_FLAGS=(-f "$SECRETS_FILE")
fi

log_info "Updating kagenti chart dependencies..."
run_cmd helm dependency update "$REPO_ROOT/charts/kagenti/"

# Delete old OAuth secret jobs (immutable — must delete before helm upgrade)
kubectl delete job kagenti-ui-oauth-secret-job -n kagenti-system --ignore-not-found 2>/dev/null || true
kubectl delete job kagenti-agent-oauth-secret-job -n kagenti-system --ignore-not-found 2>/dev/null || true

# Pre-create mcp-system namespace (kagenti chart creates resources there when mcpGateway is enabled)
if $WITH_MCP_GATEWAY; then
  kubectl create namespace mcp-system --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
fi

KAGENTI_FLAGS=(
  --set "openshift=false"
  --set "domain=${DOMAIN}"
  --set "components.agentNamespaces.enabled=true"
  --set "components.agentOperator.enabled=true"
  --set "components.ui.enabled=${WITH_BACKEND}"
  --set "components.istio.enabled=${WITH_ISTIO}"
  --set "components.mcpGateway.enabled=${WITH_MCP_GATEWAY}"
  --set "components.phoenix.enabled=false"
  --set "components.mlflow.enabled=false"
  --set "ui.frontend.tag=${KAGENTI_TAG}"
  --set "ui.backend.tag=${KAGENTI_TAG}"
  --set "ui.auth.enabled=$($WITH_SPIRE && echo true || echo false)"
  --set "mlflow.auth.enabled=false"
)

log_info "Installing kagenti..."
run_cmd helm upgrade --install kagenti "$REPO_ROOT/charts/kagenti/" \
  -n kagenti-system --wait --timeout 20m \
  "${SECRETS_FLAGS[@]+"${SECRETS_FLAGS[@]}"}" \
  "${KAGENTI_FLAGS[@]}"

log_success "kagenti installed"
echo ""

# ============================================================================
# Step 9: Install MCP Gateway (optional)
# ============================================================================
log_info "Step 9: MCP Gateway"

if $WITH_MCP_GATEWAY; then
  # Create gateway-system namespace (required by MCP Gateway, not created by its chart)
  kubectl create namespace mcp-system --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  kubectl create namespace gateway-system --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  log_info "Installing MCP Gateway v${MCP_GATEWAY_VERSION}..."
  run_cmd helm upgrade --install mcp-gateway oci://ghcr.io/kuadrant/charts/mcp-gateway \
    -n mcp-system --create-namespace --version "$MCP_GATEWAY_VERSION" \
    --set "broker.create=true"
  log_success "MCP Gateway installed"
else
  log_info "Skipped (use --with-mcp-gateway)"
fi
echo ""

# ============================================================================
# Step 10: Verify & show access info
# ============================================================================
log_info "Step 10: Verification"
echo ""

# Helm release check
VERIFY_FAILED=false
for release_info in "kagenti-deps:kagenti-system" "kagenti:kagenti-system"; do
  release="${release_info%%:*}"
  ns="${release_info##*:}"
  STATUS=$(helm status "$release" -n "$ns" -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || echo "")
  if [ "$STATUS" = "deployed" ]; then
    log_success "$release: deployed"
  else
    log_error "$release: status '$STATUS'"
    VERIFY_FAILED=true
  fi
done

if $WITH_MCP_GATEWAY; then
  STATUS=$(helm status mcp-gateway -n mcp-system -o json 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || echo "")
  if [ "$STATUS" = "deployed" ]; then
    log_success "mcp-gateway: deployed"
  else
    log_error "mcp-gateway: status '$STATUS'"
    VERIFY_FAILED=true
  fi
fi

if $VERIFY_FAILED; then
  log_error "One or more Helm releases failed verification"
fi

echo ""
log_info "Access info:"
echo ""
if $WITH_BACKEND; then
  echo "  Kagenti UI:   http://kagenti-ui.${DOMAIN}:8080"
fi
echo "  Keycloak:     http://keycloak.${DOMAIN}:8080"
if $WITH_SPIRE; then
  echo "  Tornjak:      http://spire-tornjak-api.${DOMAIN}:8080"
fi
echo ""
echo "  Keycloak credentials:"
echo "    kubectl get secret keycloak-initial-admin -n keycloak -o go-template='User: {{.data.username | base64decode}}  Pass: {{.data.password | base64decode}}'"
echo ""

ELAPSED=$(( SECONDS - START_SECONDS ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo "============================================"
echo "  Kagenti platform is ready!  (${MINS}m ${SECS}s)"
echo "============================================"
echo ""
