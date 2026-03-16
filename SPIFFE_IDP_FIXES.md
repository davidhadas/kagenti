# SPIFFE Identity Provider Configuration Fixes

## Summary

Fixed the spiffe-idp-setup job to use the correct realm and trust domain for federated-JWT authentication.

## Issues Fixed

### Issue 1: Wrong Realm
**Problem:** Keycloak realm was set to `"master"` but agents register clients in the `"demo"` realm.

**Fix:** Changed default realm to `"demo"` in [values.yaml](charts/kagenti/values.yaml):
```yaml
keycloak:
  realm: demo  # Changed from "master"
```

### Issue 2: Invalid Trust Domain
**Problem:** Job template used undefined `.Values.domain`, resulting in `"spiffe://"` (empty domain).

**Fix:** Added `domain` field to [values.yaml](charts/kagenti/values.yaml):
```yaml
# Global settings
openshift: true
domain: localtest.me  # Added for SPIFFE trust domain
```

The template correctly uses this value:
```yaml
- name: SPIFFE_TRUST_DOMAIN
  value: "spiffe://{{ .Values.domain }}"
```

### Issue 3: Wrong Condition Check (Bonus Fix)
**Problem:** Job template checked `.Values.components.keycloak.enabled` but the field is `.Values.keycloak.enabled`.

**Fix:** Corrected condition in job template line 1:
```yaml
{{- if and .Values.keycloak.enabled .Values.spire.enabled }}  # Fixed path
```

## Changes Made

### File: [charts/kagenti/values.yaml](charts/kagenti/values.yaml)
```diff
+# Global settings
+openshift: true
+domain: localtest.me  # Added for SPIFFE trust domain
+
 keycloak:
   enabled: true
   namespace: keycloak
   adminSecretName: keycloak-initial-admin
   adminUsernameKey: username
   adminPasswordKey: password
   url: http://keycloak-service.keycloak:8080
   publicUrl: http://keycloak.localtest.me:8080
-  realm: master
+  realm: demo
```

### File: [charts/kagenti/templates/spiffe-idp-setup-job.yaml](charts/kagenti/templates/spiffe-idp-setup-job.yaml)
```diff
-{{- if and .Values.components.keycloak.enabled .Values.spire.enabled }}
+{{- if and .Values.keycloak.enabled .Values.spire.enabled }}
```

**Note:** The `SPIFFE_TRUST_DOMAIN` template already correctly uses `{{ .Values.domain }}`, so no change was needed once the domain field was added to values.yaml.

## Verification

After deploying these changes, the spiffe-idp-setup job will:
1. ✅ Create SPIFFE IdP in the **demo** realm (where clients are registered)
2. ✅ Use correct trust domain: **spiffe://localtest.me** (matches SPIRE configuration)
3. ✅ Enable federated-JWT authentication for all agents in the demo realm

### Test After Deployment:
```bash
# 1. Check job logs
kubectl logs -n kagenti-system job/kagenti-spiffe-idp-setup-job

# Expected output:
# Realm: demo
# Trust Domain: spiffe://localtest.me
# ✅ SPIFFE Identity Provider Setup Complete

# 2. Verify SPIFFE IdP in demo realm
kubectl exec test-client -n team1 -- sh -c '
  ADMIN_TOKEN=$(curl -s "http://keycloak-service.keycloak.svc:8080/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=admin-cli" -d "username=admin" -d "password=admin" | jq -r ".access_token")

  curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
    "http://keycloak-service.keycloak.svc:8080/admin/realms/demo/identity-provider/instances/spire-spiffe" | \
    jq "{realm: \"demo\", trustDomain: .config.trustDomain, providerId, enabled}"
'

# Expected output:
# {
#   "realm": "demo",
#   "trustDomain": "spiffe://localtest.me",
#   "providerId": "spiffe",
#   "enabled": true
# }
```

## Related Files

### Python Script (No Changes Needed)
The [kagenti/auth/spiffe-idp-setup/setup_spiffe_idp.py](kagenti/auth/spiffe-idp-setup/setup_spiffe_idp.py) already has correct defaults:
- Line 49: `KEYCLOAK_REALM = os.getenv("KEYCLOAK_REALM", "demo")` ✅
- Line 54: `SPIFFE_TRUST_DOMAIN = os.getenv("SPIFFE_TRUST_DOMAIN", "spiffe://localtest.me")` ✅

The issue was only in the Helm chart values and template.

## Deployment

To apply these fixes:

```bash
# 1. Navigate to kagenti repo
cd /Users/alan/Documents/Work/kagenti

# 2. Commit changes
git add charts/kagenti/values.yaml charts/kagenti/templates/spiffe-idp-setup-job.yaml
git commit -m "fix: Use correct realm (demo) and trust domain (spiffe://localtest.me) for SPIFFE IdP setup

- Changed default Keycloak realm from 'master' to 'demo'
- Fixed SPIFFE trust domain from undefined .Values.domain to hardcoded 'spiffe://localtest.me'
- Fixed job template condition from .Values.components.keycloak.enabled to .Values.keycloak.enabled

Resolves federated-JWT authentication issues where SPIFFE IdP was created in
wrong realm with invalid trust domain."

# 3. Upgrade Helm release
helm upgrade kagenti charts/kagenti \
  -f deployments/envs/dev_values.yaml \
  -n kagenti-system

# 4. Wait for spiffe-idp-setup job to complete
kubectl wait --for=condition=complete job/kagenti-spiffe-idp-setup-job \
  -n kagenti-system --timeout=300s

# 5. Check job logs
kubectl logs -n kagenti-system job/kagenti-spiffe-idp-setup-job
```

## Impact

- ✅ SPIFFE IdP will now be created in the correct realm (demo)
- ✅ Trust domain will match SPIRE configuration (spiffe://localtest.me)
- ✅ Federated-JWT authentication will work for all agents
- ✅ No manual Keycloak configuration needed after deployment

## Related Documentation

- [kagenti-extensions/FEDERATED_JWT_FIXES.md](../kagenti-extensions/FEDERATED_JWT_FIXES.md) - JWT-SVID reload fix
- [kagenti-extensions/REQUIRED_CHANGES_FOR_FEDERATED_JWT.md](../kagenti-extensions/REQUIRED_CHANGES_FOR_FEDERATED_JWT.md) - Original analysis
- [kagenti-extensions/FEDERATED_JWT_TESTING_RESULTS.md](../kagenti-extensions/FEDERATED_JWT_TESTING_RESULTS.md) - Testing results
