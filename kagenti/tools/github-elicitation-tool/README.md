# github-elicitation-tool

Small MCP proxy used by the MCP elicitation demo.

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

For local manual testing from the repository root:

```bash
docker build -t localhost/kagenti/github-elicitation-tool:latest -f kagenti/tools/github-elicitation-tool/Dockerfile kagenti/tools/github-elicitation-tool
```

## Local run

```bash
docker run --rm -p 8000:8000 \
  -e UPSTREAM_MCP_URL=http://host.docker.internal:8184 \
  localhost/kagenti/github-elicitation-tool:latest
```

## Kagenti UI import

Primary demo flow: import from source.

Use Kagenti **Import Tool** with:

- Namespace: `team1`
- Tool name: `github-elicitation-tool`
- Git Repository URL: `https://github.com/davidhadas/kagenti.git`
- Git Branch or Tag: `mcp_elicitation`
- Select Tool: leave as `Select an example...`
- Source Subfolder: `kagenti/tools/github-elicitation-tool`
- Workload type: `Deployment`
- Protocol: `streamable_http`

Set this environment variable during import if the UI allows it:

```bash
UPSTREAM_MCP_URL=http://mcp-server.kagenti-mcp-elicitation.svc.cluster.local:8184
```

The service created by Kagenti should be:

- `github-elicitation-tool-mcp.team1.svc.cluster.local`

Agents can then call:

```bash
MCP_URL=http://github-elicitation-tool-mcp.team1.svc.cluster.local:8000/mcp