# MCP Elicitation Demo

## Overview

This demo showcases a dedicated MCP tool named `github-elicitation-tool`.

Goals:

- keep it separate from the existing `github-tool`
- demonstrate MCP URL-based elicitation against the demo MCP server
- avoid PAT-based tool-import complexity
- keep the tool easy to explain in a live demo
- integrate cleanly with the existing Kagenti agent, AuthBridge, and backend flow

The tool implementation lives at:

- `kagenti/tools/github-elicitation-tool/`

It is a small wrapper that exposes MCP on `/mcp` on port `8000` and forwards
requests to the upstream MCP server in the `kagenti-mcp-elicitation` namespace.

## Architecture Flow

```text
User → Backend / Kagenti UI → Agent in team1 (with AuthBridge) → github-elicitation-tool-mcp → demo MCP server
                                                ↓
                                        Token Broker / Auth flow
```

## Components

- **MCP Server**
  - namespace: `kagenti-mcp-elicitation`
  - image: `ghcr.io/davidhadas/kagenti-mcp-server:latest`
  - purpose: upstream MCP server used by this demo

- **github-elicitation-tool**
  - lightweight wrapper tool
  - imported via Kagenti UI into namespace `team1`
  - built by Kagenti from source via Shipwright
  - exposed in-cluster as:
    - `github-elicitation-tool-mcp.team1.svc.cluster.local`

- **Token Broker**
  - namespace: `kagenti-mcp-elicitation`
  - image: `ghcr.io/davidhadas/kagenti-token-broker:latest`
  - purpose: supports the demo auth flow

- **Backend**
  - namespace: `kagenti-mcp-elicitation`
  - image: `ghcr.io/davidhadas/kagenti-backend:latest`
  - purpose: demo backend and UI support

## Important Behavior

- the tool stays simple
- the tool does not carry PAT-based GitHub credentials
- the tool does not require AuthBridge sidecar injection
- agents call it as a normal MCP tool
- auth remains on the agent/AuthBridge/demo infrastructure side
- the wrapper only forwards MCP traffic to the upstream demo MCP server

## Prerequisites

- Kubernetes cluster with Kagenti installed
- Kagenti UI available
- `kubectl` and `helm` configured
- GitHub OAuth app credentials for the demo MCP server
- Shipwright/source-build support available in Kagenti
- this repository pushed to a Git-accessible location for Kagenti source import

## Required Images for Kind

If using Kind, preload the demo infrastructure images:

- `ghcr.io/davidhadas/kagenti-mcp-server:latest`
- `ghcr.io/davidhadas/kagenti-token-broker:latest`
- `ghcr.io/davidhadas/kagenti-backend:latest`
- `ghcr.io/davidhadas/kagenti-extensions/authbridge:latest`

No separate local tool-image build is required for the primary demo flow,
because `github-elicitation-tool` is imported from source.

## Deployment Steps

### Step 1: Deploy demo infrastructure

```bash
./scripts/deploy.sh
```

This deploys:

- namespace
- OAuth secret
- token broker
- MCP server
- backend

It does **not** create `github-elicitation-tool` automatically.

### Step 2: Import `github-elicitation-tool` via Kagenti UI from source

Open:

- `http://kagenti-ui.localtest.me:8080/tools/import`

Use **Import Tool** with these values:

- **Namespace**: `team1`
- **Tool Name**: `github-elicitation-tool`
- **Deployment Method**: `Build from source`
- **Git URL**: your Git URL for this repository
- **Git Revision**: your working branch, for example `main`
- **Context Directory**: `.`
- **Workload Type**: `Deployment`
- **MCP Transport Protocol**: `streamable_http`
- **Enable external access to the tool endpoint**: `false`
- **Enable AuthBridge sidecar injection**: `false`
- **Enable SPIRE identity**: `false`

Why `Context Directory` is `.`:
- the Dockerfile copies files using repo-root-relative paths:
  - `kagenti/tools/github-elicitation-tool/pyproject.toml`
  - `kagenti/tools/github-elicitation-tool/app.py`

After creation, Kagenti should start a Shipwright build for the tool.

### Step 3: Monitor the build

After import, the build can be monitored from the tool build page in Kagenti UI.

You can also inspect it with `kubectl`:

```bash
kubectl get builds,buildruns -n team1
kubectl describe build github-elicitation-tool -n team1
kubectl describe buildrun -n team1
```

When the build finishes, the tool should appear in:

- `http://kagenti-ui.localtest.me:8080/tools`

under namespace `team1`.

### Step 4: Verify the Tool in Tool Catalog

1. Open **Tool Catalog**
2. Ensure namespace is `team1`
3. Locate `github-elicitation-tool`
4. Open the details page
5. Use **Connect & List Tools**

### Step 5: Configure upstream MCP URL if needed

The wrapper must forward to:

```bash
http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184
```

If the source import form allows environment variables, set:

```bash
UPSTREAM_MCP_URL=http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184
```

If you do not set it in the UI, ensure the deployed workload is patched or built
with that environment value before testing.

### Step 6: Import an Agent

Import the agent through Kagenti UI in namespace `team1`.

Recommended agent-side settings:

- AuthBridge enabled
- SPIRE enabled
- outbound route host: `github-elicitation-tool-mcp`
- target audience: `github-elicitation-tool`
- token scopes: `openid`

### Step 7: Configure the Agent MCP URL

Set:

```bash
MCP_URL=http://github-elicitation-tool-mcp.team1.svc.cluster.local:8000/mcp
```

If your agent supports multiple tool URLs, use `MCP_URLS`.

### Step 8: Test the Integration

Suggested checks:

```bash
# Infrastructure logs
kubectl logs -n kagenti-mcp-elicitation -l app.kubernetes.io/name=token-broker
kubectl logs -n kagenti-mcp-elicitation -l app.kubernetes.io/name=mcp-server
kubectl logs -n kagenti-mcp-elicitation -l app.kubernetes.io/name=backend

# Tool logs
kubectl logs -n team1 deployment/github-elicitation-tool
```

## Reference Manifest

A reference manifest for the wrapper tool is kept at:

- `docs/demos/mcp-elicitation/k8s/05-github-elicitation-tool.yaml`

It documents the expected runtime shape, but the preferred demo flow is to
import the tool through Kagenti UI from source.

## Wrapper Source

Implementation files:

- `kagenti/tools/github-elicitation-tool/app.py`
- `kagenti/tools/github-elicitation-tool/pyproject.toml`
- `kagenti/tools/github-elicitation-tool/Dockerfile`
- `kagenti/tools/github-elicitation-tool/README.md`

## Troubleshooting

- If the tool does not appear in Tool Catalog, confirm namespace `team1`.
- If the build does not start, check Shipwright/registry configuration in Kagenti.
- If the build fails, inspect the `Build` and `BuildRun` resources in `team1`.
- If the tool pod starts but does not answer, check that the service is
  `github-elicitation-tool-mcp`.
- If the tool cannot reach upstream MCP, inspect the wrapper logs and verify
  `UPSTREAM_MCP_URL`.
- If agents cannot call the tool, verify outbound route host and audience.

## Summary

This demo uses a dedicated, separate `github-elicitation-tool` that:

- is simple
- is imported through Kagenti UI
- is built from source by Kagenti
- behaves like a normal MCP tool for agents
- forwards to the demo MCP server
- avoids PAT-centric demo complexity