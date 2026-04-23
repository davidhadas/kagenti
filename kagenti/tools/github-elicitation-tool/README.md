# github-elicitation-tool

Small image-backed MCP proxy used by the MCP elicitation demo.

## Purpose

This tool is a lightweight wrapper that:

- exposes MCP over HTTP on port `8000`
- serves the standard tool endpoint at `/mcp`
- forwards incoming requests to the demo MCP server
- keeps the tool deployment simple, similar to the existing `github-tool` pattern

The tool itself does not manage OAuth client secrets. Authentication is expected to be handled by the calling agent/AuthBridge path and by the upstream demo MCP flow.

## Runtime configuration

Environment variables:

- `UPSTREAM_MCP_URL`
  Default: `http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184`

- `PORT`  
  Default: `8000`

- `REQUEST_TIMEOUT_SECONDS`  
  Default: `300`

- `LOG_LEVEL`  
  Default: `INFO`

## Build

From the repository root:

```bash
docker build -t localhost/kagenti/github-elicitation-tool:latest -f kagenti/tools/github-elicitation-tool/Dockerfile .
```

## Local run

```bash
docker run --rm -p 8000:8000 \
  -e UPSTREAM_MCP_URL=http://host.docker.internal:8184 \
  localhost/kagenti/github-elicitation-tool:latest
```

## Kagenti UI import

Use Kagenti **Import Tool** with:

- Namespace: `team1`
- Tool name: `github-elicitation-tool`
- Deployment method: `Deploy from existing image`
- Image: `localhost/kagenti/github-elicitation-tool:latest`
- Workload type: `Deployment`
- Protocol: `streamable_http`

The service created by Kagenti should be:

- `github-elicitation-tool-mcp.team1.svc.cluster.local`

Agents can then call:

```bash
MCP_URL=http://github-elicitation-tool-mcp.team1.svc.cluster.local:8000/mcp