# MCP Elicitation Demo Architecture

## Overview

This demo introduces a dedicated MCP tool named `github-elicitation-tool`,
separate from the existing `github-tool`.

Target behavior:

- agents use it like a normal MCP tool
- the tool is imported into `team1`
- the tool is built from source via Kagenti UI
- the tool itself stays simple
- the tool forwards MCP traffic to the demo MCP server
- PAT-based demo complexity is avoided in the tool import path

The wrapper implementation lives at:

- `kagenti/tools/github-elicitation-tool/`

## Architecture Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                             Demo Infrastructure                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  User ──► Backend / UI ──► Agent Pod in team1 ──► github-elicitation-tool  │
│                            (with AuthBridge)      service:                  │
│                                                        github-elicitation-  │
│                                                        tool-mcp:8000        │
│                                                                             │
│                                        │                                    │
│                                        ▼                                    │
│                 mcp-server.kagenti-mcp-elicitation.svc.cluster.local        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Main Components

### Agent

- imported through Kagenti UI
- deployed in namespace `team1`
- uses AuthBridge sidecar injection
- calls the tool using:
  - `http://github-elicitation-tool-mcp.team1.svc.cluster.local:8000/mcp`

### github-elicitation-tool

- separate tool identity from `github-tool`
- lightweight wrapper built from source by Kagenti
- imported through Kagenti UI
- no AuthBridge injection
- no PAT-based tool credential wiring
- listens on port `8000`
- forwards `/mcp` requests to the upstream demo MCP server

### Upstream MCP Server

- namespace: `kagenti-mcp-elicitation`
- image: `ghcr.io/davidhadas/kagenti-mcp-server:latest`
- receives forwarded requests from `github-elicitation-tool`

### Token Broker / Demo Auth Infrastructure

- supports the demo authentication flow
- remains outside the simple tool wrapper
- keeps auth concerns out of the tool implementation itself

### Backend

- user-facing demo frontend/backend
- helps exercise the end-to-end demo flow

## Request Flow

1. User interacts with the demo backend or an imported agent
2. Agent runs in `team1` with AuthBridge sidecar
3. Agent sends MCP traffic to:
   - `github-elicitation-tool-mcp.team1.svc.cluster.local:8000/mcp`
4. `github-elicitation-tool` receives the request
5. The wrapper forwards the MCP request to:
   - `http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184`
6. The upstream MCP server processes the request
7. Response returns back through the wrapper to the agent

## Why This Design

This design keeps the demo simple and clear:

- the tool is visible as its own resource in Kagenti
- the tool behaves like the existing `github-tool` from the agent perspective
- the tool import path matches the existing github demo: source import through UI
- the wrapper is small and easy to explain
- auth and upstream complexity stay outside the wrapper implementation

## Deployment Model

### Infrastructure deployed by script

`./scripts/deploy.sh` deploys:

1. namespace and infrastructure manifests
2. token broker
3. MCP server
4. backend
5. port-forwarding support

It does **not** apply a live `github-elicitation-tool` workload.

### Tool deployment model

Preferred flow:

1. import the tool through Kagenti UI into `team1`
2. choose source-based deployment
3. point to this repository
4. use `contextDir: .`
5. let Kagenti build the wrapper image through Shipwright

Reference manifest:

- `docs/demos/mcp-elicitation/k8s/05-github-elicitation-tool.yaml`

That manifest documents the expected runtime shape but is no longer the primary
deployment path.

## Source Build Expectations

The wrapper Dockerfile currently uses repo-root-relative `COPY` instructions:

- `COPY kagenti/tools/github-elicitation-tool/pyproject.toml ./pyproject.toml`
- `COPY kagenti/tools/github-elicitation-tool/app.py ./app.py`

Because of that, the expected Kagenti source import values are:

- `gitUrl`: repository URL
- `gitRevision`: desired branch/tag
- `contextDir`: `.`

## Tool Runtime Shape

Expected characteristics of `github-elicitation-tool`:

- `Deployment`
- namespace: `team1`
- service: `github-elicitation-tool-mcp`
- transport: `streamable_http`
- protocol label: MCP
- service port: `8000`
- MCP endpoint: `/mcp`
- environment:
  - `UPSTREAM_MCP_URL=http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184`

## Agent Configuration

Recommended outbound route:

- host pattern: `github-elicitation-tool-mcp`
- target audience: `github-elicitation-tool`
- token scopes: `openid`

Recommended environment variable:

```bash
MCP_URL=http://github-elicitation-tool-mcp.team1.svc.cluster.local:8000/mcp
```

## Files

Key files for this implementation:

- `kagenti/tools/github-elicitation-tool/app.py`
- `kagenti/tools/github-elicitation-tool/pyproject.toml`
- `kagenti/tools/github-elicitation-tool/Dockerfile`
- `kagenti/tools/github-elicitation-tool/README.md`
- `docs/demos/mcp-elicitation/k8s/05-github-elicitation-tool.yaml`
- `docs/demos/mcp-elicitation/scripts/deploy.sh`
- `docs/demos/mcp-elicitation/README.md`

## Remaining Alignment Work

Operational validation now centers on confirming the source-import flow and the
required `UPSTREAM_MCP_URL` configuration in the UI-created tool workload.