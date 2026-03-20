#!/usr/bin/env bash
# Ensure a test user and a service-account client exist in the Keycloak
# kagenti realm.  Runs AFTER the platform is deployed and Keycloak is
# reachable, BEFORE E2E tests start.
#
# Creates:
#   1. Test user "admin" in the kagenti realm (for agent AuthBridge auth)
#   2. Confidential client "kagenti-e2e-tests" with client_credentials
#      grant (for backend API tests that need a service account)
#
# Outputs (exported to GITHUB_ENV on CI):
#   KAGENTI_TEST_USER        – username
#   KAGENTI_TEST_PASSWORD    – password
#   KAGENTI_E2E_CLIENT_ID    – service account client id
#   KAGENTI_E2E_CLIENT_SECRET – service account client secret
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/env-detect.sh"
source "$SCRIPT_DIR/../lib/logging.sh"

log_step "87" "Setting up test credentials in Keycloak"

# ============================================================================
# Resolve Keycloak URL and credentials
# ============================================================================

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8081}"

# Read admin credentials from K8s secret
ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak \
    -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak \
    -o jsonpath='{.data.password}' | base64 -d)

# Read realm from kagenti-test-user secret (if it exists), else default
REALM=$(kubectl get secret kagenti-test-user -n keycloak \
    -o jsonpath='{.data.realm}' 2>/dev/null | base64 -d 2>/dev/null || echo "kagenti")

log_info "Keycloak URL: $KEYCLOAK_URL"
log_info "Target realm: $REALM"

# curl flags: follow redirects, accept self-signed certs on OCP routes
CURL="curl -sf -k --connect-timeout 10"

# ============================================================================
# Get admin token (master realm)
# ============================================================================

ADMIN_TOKEN=$($CURL -X POST \
    "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=$ADMIN_USER&password=$ADMIN_PASS" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$ADMIN_TOKEN" ]; then
    log_error "Failed to get Keycloak admin token"
    exit 1
fi
log_success "Got admin token"

AUTH="Authorization: Bearer $ADMIN_TOKEN"

# ============================================================================
# 1. Ensure realm exists
# ============================================================================

REALM_STATUS=$($CURL -o /dev/null -w "%{http_code}" \
    -H "$AUTH" "$KEYCLOAK_URL/admin/realms/$REALM" 2>/dev/null || echo "000")

if [ "$REALM_STATUS" = "404" ]; then
    log_info "Creating realm '$REALM'..."
    $CURL -X POST -H "$AUTH" -H "Content-Type: application/json" \
        "$KEYCLOAK_URL/admin/realms" \
        -d "{\"realm\": \"$REALM\", \"enabled\": true}"
    log_success "Realm '$REALM' created"
elif [ "$REALM_STATUS" = "200" ]; then
    log_info "Realm '$REALM' exists"
else
    log_error "Could not check realm (HTTP $REALM_STATUS)"
    exit 1
fi

# ============================================================================
# 2. Create test user (or reset password if exists)
# ============================================================================

TEST_USER="admin"
TEST_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))")

# Check if user exists
USER_JSON=$($CURL -H "$AUTH" \
    "$KEYCLOAK_URL/admin/realms/$REALM/users?username=$TEST_USER&exact=true" 2>/dev/null || echo "[]")
USER_COUNT=$(echo "$USER_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$USER_COUNT" = "0" ]; then
    log_info "Creating test user '$TEST_USER' in realm '$REALM'..."
    $CURL -X POST -H "$AUTH" -H "Content-Type: application/json" \
        "$KEYCLOAK_URL/admin/realms/$REALM/users" \
        -d "{
            \"username\": \"$TEST_USER\",
            \"enabled\": true,
            \"emailVerified\": true,
            \"email\": \"$TEST_USER@kagenti.dev\",
            \"requiredActions\": [],
            \"credentials\": [{\"type\": \"password\", \"value\": \"$TEST_PASS\", \"temporary\": false}]
        }"
    log_success "Test user '$TEST_USER' created"
else
    # Reset password to a known value
    USER_ID=$(echo "$USER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
    log_info "Test user '$TEST_USER' exists (id=$USER_ID), resetting password..."
    $CURL -X PUT -H "$AUTH" -H "Content-Type: application/json" \
        "$KEYCLOAK_URL/admin/realms/$REALM/users/$USER_ID/reset-password" \
        -d "{\"type\": \"password\", \"value\": \"$TEST_PASS\", \"temporary\": false}"
    log_success "Password reset for '$TEST_USER'"
fi

# Verify: get a token for the test user
TEST_TOKEN=$($CURL -X POST \
    "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=$TEST_USER&password=$TEST_PASS" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

if [ -z "$TEST_TOKEN" ]; then
    log_error "Could not acquire token for test user"
    exit 1
fi
log_success "Test user token verified (length=${#TEST_TOKEN})"

# ============================================================================
# 3. Create service account client for API tests
# ============================================================================

E2E_CLIENT_ID="kagenti-e2e-tests"

# Check if client exists
CLIENT_JSON=$($CURL -H "$AUTH" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$E2E_CLIENT_ID" 2>/dev/null || echo "[]")
CLIENT_COUNT=$(echo "$CLIENT_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [ "$CLIENT_COUNT" = "0" ]; then
    log_info "Creating service account client '$E2E_CLIENT_ID'..."
    $CURL -X POST -H "$AUTH" -H "Content-Type: application/json" \
        "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
        -d "{
            \"clientId\": \"$E2E_CLIENT_ID\",
            \"enabled\": true,
            \"publicClient\": false,
            \"serviceAccountsEnabled\": true,
            \"standardFlowEnabled\": false,
            \"directAccessGrantsEnabled\": true
        }"
    log_success "Service account client '$E2E_CLIENT_ID' created"
fi

# Get the client's internal ID and secret
CLIENT_INTERNAL_ID=$($CURL -H "$AUTH" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$E2E_CLIENT_ID" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

E2E_CLIENT_SECRET=$($CURL -H "$AUTH" \
    "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_INTERNAL_ID/client-secret" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

log_success "Service account client ready (client_id=$E2E_CLIENT_ID)"

# ============================================================================
# 4. Update kagenti-test-user secret with verified credentials
# ============================================================================

log_info "Updating kagenti-test-user secret with verified credentials..."
kubectl create secret generic kagenti-test-user \
    --namespace keycloak \
    --from-literal=username="$TEST_USER" \
    --from-literal=password="$TEST_PASS" \
    --from-literal=realm="$REALM" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

# ============================================================================
# 5. Export to environment (CI and local)
# ============================================================================

if [ "$IS_CI" = true ]; then
    {
        echo "KAGENTI_TEST_USER=$TEST_USER"
        echo "KAGENTI_TEST_PASSWORD=$TEST_PASS"
        echo "KAGENTI_E2E_CLIENT_ID=$E2E_CLIENT_ID"
        echo "KAGENTI_E2E_CLIENT_SECRET=$E2E_CLIENT_SECRET"
    } >> "$GITHUB_ENV"
else
    export KAGENTI_TEST_USER="$TEST_USER"
    export KAGENTI_TEST_PASSWORD="$TEST_PASS"
    export KAGENTI_E2E_CLIENT_ID="$E2E_CLIENT_ID"
    export KAGENTI_E2E_CLIENT_SECRET="$E2E_CLIENT_SECRET"
fi

log_success "Test credentials ready"
log_info "  Test user: $TEST_USER (realm: $REALM)"
log_info "  Service account: $E2E_CLIENT_ID"
