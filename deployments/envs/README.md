# Environment Values Files

This directory contains environment-specific configuration files for the Kagenti Ansible installer.

## File Architecture

The installer uses a **three-layer merge system**:

```
1. deployments/ansible/default_values.yaml  (Baseline - infrastructure config)
2. deployments/envs/<env>_values.yaml       (Environment - base configuration)
3. deployments/envs/<overlay>_values.yaml   (Optional - feature-specific overrides)
   └─→ Final merged configuration passed to Helm
```

## Available Environment Files

### Base Environments (Standalone)

| File | Target | Description |
|------|--------|-------------|
| `dev_values.yaml` | Kind (local) | Full development setup with all components enabled |
| `dev_values_minimal.yaml` | Kind (local) | Minimal setup, authentication disabled |
| `dev_values_minimal_auth.yaml` | Kind (local) | Minimal setup with authentication enabled |
| `ocp_values.yaml` | OpenShift | Production OpenShift deployment (requires OCP 4.19+ for SPIRE) |

### Overlay Files (Used WITH a base environment)

| File | Merges With | Description |
|------|-------------|-------------|
| `dev_values_federated-jwt.yaml` | `dev_values.yaml` | Adds JWT-SVID authentication (production-ready) |
| `dev_values_local_images.yaml` | Any base | Overrides images to use :local tags (testing-only) |

## Usage

### Standalone Environment

Use `--env <name>` to load a base environment:

```bash
# Full dev environment on Kind
deployments/ansible/run-install.sh --env dev

# Minimal dev environment
deployments/ansible/run-install.sh --env minimal

# OpenShift production
deployments/ansible/run-install.sh --env ocp
```

### Base + Overlay(s)

Use `--env <name>` plus one or more `--env-file <path>` to merge overlays:

```bash
# Dev environment + JWT-SVID authentication (production-ready)
deployments/ansible/run-install.sh --env dev \
  --env-file deployments/envs/dev_values_federated-jwt.yaml

# Dev environment + JWT-SVID + local images (for testing)
deployments/ansible/run-install.sh --env dev \
  --env-file deployments/envs/dev_values_federated-jwt.yaml \
  --env-file deployments/envs/dev_values_local_images.yaml
```

**Important:** Overlay files should ONLY contain overrides specific to their feature. They should NOT duplicate configuration from the base environment.

**Multiple overlays:** Files are merged in order from left to right. Later files override earlier ones.

## Key Configuration Differences

### Kind vs OpenShift

| Setting | Kind (`dev_values.yaml`) | OpenShift (`ocp_values.yaml`) |
|---------|-------------------------|-------------------------------|
| `openshift` | `false` | `true` |
| `create_kind_cluster` | `true` | `false` |
| SPIRE deployment | Helm chart | ZTWIM operator |
| Ingress | HTTPRoute (Gateway API) | Route (OpenShift native) |
| Version requirement | Kubernetes 1.25+ | OpenShift 4.19+ (for SPIRE) |

### Base Dev vs JWT-SVID vs Local Images

| Setting | `dev_values.yaml` | `dev_values_federated-jwt.yaml` | `dev_values_local_images.yaml` |
|---------|-------------------|---------------------------------|-------------------------------|
| Base components | ✅ Defined | ❌ Inherits | ❌ Inherits |
| `openshift: false` | ✅ Defined | ❌ Inherits | ❌ Inherits |
| `agentNamespaces` list | ❌ Uses chart default | ❌ Inherits | ❌ Inherits |
| SPIRE `set_key_use` | ✅ `true` | ❌ Inherits | ❌ Inherits |
| SPIRE `jwtTTL` | ✅ `5m` | ❌ Inherits | ❌ Inherits |
| `authBridge.clientAuthType` | ❌ Chart default | ✅ `federated-jwt` | ❌ Inherits |
| Image tags | ❌ Chart defaults | ❌ Inherits | ✅ `local` |
| Image pullPolicy | ❌ Chart defaults | ❌ Inherits | ✅ `Never` |
| `create_kind_cluster` | ✅ `true` | ❌ Inherits | ✅ `false` (manual) |

## Creating New Overlay Files

When creating a new overlay file (e.g., `dev_values_<feature>.yaml`):

1. **Only include feature-specific overrides** - don't duplicate base config
2. **Document which base file it requires** - in the file header
3. **Use the `charts.<chart-name>.values` structure** - for Helm value overrides
4. **Add clear comments** - explain what each override does and why
5. **Mark temporary settings** - use `LOCAL TESTING ONLY` comments for dev-only config

### Example: Good Overlay Structure

```yaml
# ============================================================================
# dev_values_feature-x.yaml
# ============================================================================
# Feature X overlay for dev_values.yaml
#
# USAGE: run-install.sh --env dev --env-file deployments/envs/dev_values_feature-x.yaml
#
# This file is a PATCH/OVERLAY - it only specifies Feature X configuration.
# ============================================================================

charts:
  kagenti:
    values:
      featureX:
        enabled: true
        setting1: "value1"
```

### Example: Bad Overlay (Don't Do This)

```yaml
# ❌ Don't duplicate base configuration
openshift: false  # Already in dev_values.yaml

keycloak:  # Already in dev_values.yaml
  enabled: true

agentNamespaces:  # Should inherit from chart default
  - team1

featureX:  # ✅ This is the only thing that should be here
  enabled: true
```

## Environment Variables vs Helm Values

The installer supports two levels of configuration:

### Ansible Variables (Top-level)

Control the **installer behavior** (how charts are deployed):

```yaml
create_kind_cluster: false
kind_cluster_name: kagenti-dev
container_engine: podman
```

### Helm Chart Values (Under `charts.<name>.values`)

Control the **chart configuration** (what gets deployed):

```yaml
charts:
  kagenti:
    values:
      openshift: false
      authBridge:
        clientAuthType: "federated-jwt"
```

## Secrets

Secrets should NEVER be committed to this directory. Use a separate secrets file:

```bash
# Create secrets file (gitignored)
cp .secret_values.yaml.example .secret_values.yaml
# Edit with your secrets
vim .secret_values.yaml

# Use with installer
deployments/ansible/run-install.sh --env dev --secret ../envs/.secret_values.yaml
```

## Troubleshooting

### "Why is my overlay not taking effect?"

1. Check merge order - overlays must come AFTER the base file
2. Verify the structure uses `charts.<name>.values` for Helm overrides
3. Ensure you're using `--env-file` not `--env` for overlay files

### "Why do I get OpenShift Route errors on Kind?"

You're missing `openshift: false`. This should be:
- ✅ In `dev_values.yaml` (base file)
- ❌ NOT needed in overlay files (they inherit it)

### "Why are my namespaces not being created?"

The `agentNamespaces` list is defined in:
1. Chart default: `charts/kagenti/values.yaml` → `[team1, team2]`
2. Can be overridden in base environment file if needed
3. Should NOT be in overlay files (unless changing the list)

To disable namespace creation entirely:
```yaml
charts:
  kagenti:
    values:
      components:
        agentNamespaces:
          enabled: false
```

## Related Documentation

- [Ansible Installer README](../ansible/README.md) - How the installer works
- [LOCAL_TESTING_GUIDE.md](../../kagenti-extensions/LOCAL_TESTING_GUIDE.md) - Local development workflow
- [Kagenti Chart Values](../../charts/kagenti/values.yaml) - Chart defaults
