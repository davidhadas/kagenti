#!/bin/bash
set -e

echo "Configuring Keycloak client for backend service..."

# Wait for Keycloak to be ready
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s 2>/dev/null || true

# Configure credentials
kubectl exec -n keycloak keycloak-0 -- /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user admin \
    --password admin > /dev/null 2>&1

# Check if backend client already exists
CLIENT_EXISTS=$(kubectl exec -n keycloak keycloak-0 -- \
    /opt/keycloak/bin/kcadm.sh get clients -r kagenti --fields clientId 2>/dev/null | \
    grep -c '"clientId" : "kagenti-backend"' || true)

if [ "$CLIENT_EXISTS" -eq "0" ]; then
    echo "Creating kagenti-backend client..."
    
    # Create the client as public (no client_secret needed for password grant)
    kubectl exec -n keycloak keycloak-0 -- \
        /opt/keycloak/bin/kcadm.sh create clients -r kagenti \
        -s clientId=kagenti-backend \
        -s enabled=true \
        -s publicClient=true \
        -s directAccessGrantsEnabled=true \
        -s serviceAccountsEnabled=false \
        -s 'redirectUris=["*"]' \
        -s 'webOrigins=["*"]' > /dev/null 2>&1
    
    echo "✓ kagenti-backend client created"
else
    echo "✓ kagenti-backend client already exists"
fi

# Get the client's internal ID
CLIENT_ID=$(kubectl exec -n keycloak keycloak-0 -- \
    /opt/keycloak/bin/kcadm.sh get clients -r kagenti --fields id,clientId 2>/dev/null | \
    grep -B1 '"clientId" : "kagenti-backend"' | grep '"id"' | sed 's/.*"id" : "\([^"]*\)".*/\1/')

if [ -n "$CLIENT_ID" ]; then
    echo "Configuring audience mapper for client..."
    
    # Check if audience mapper already exists
    MAPPER_EXISTS=$(kubectl exec -n keycloak keycloak-0 -- \
        /opt/keycloak/bin/kcadm.sh get clients/$CLIENT_ID/protocol-mappers/models -r kagenti 2>/dev/null | \
        grep -c '"name" : "audience-mapper"' || true)
    
    if [ "$MAPPER_EXISTS" -eq "0" ]; then
        # Add audience mapper to include the git-issue-agent client ID as audience
        # This must match what the backend requests in the 'audience' parameter
        # and what AuthBridge expects in the 'aud' claim
        kubectl exec -n keycloak keycloak-0 -- \
            /opt/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/protocol-mappers/models -r kagenti \
            -s name=audience-mapper \
            -s protocol=openid-connect \
            -s protocolMapper=oidc-audience-mapper \
            -s 'config."included.client.audience"=git-issue-agent' \
            -s 'config."access.token.claim"=true' \
            -s 'config."id.token.claim"=false' \
            -s 'config."introspection.token.claim"=true' > /dev/null 2>&1
        
        echo "✓ Audience mapper configured"
    else
        echo "✓ Audience mapper already exists"
    fi
    
    echo "✓ Using Keycloak's standard jti claim as session_key (no custom mapper needed)"
    echo "✓ Using Keycloak's standard preferred_username claim as user_id (no custom mapper needed)"
else
    echo "⚠ Could not find client ID, skipping audience mapper configuration"
fi

echo "✓ Keycloak client configuration complete"

# Made with Bob
