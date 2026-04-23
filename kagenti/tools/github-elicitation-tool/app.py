import logging
import os

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.background import BackgroundTask

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
UPSTREAM_BASE_URL = os.getenv(
    "UPSTREAM_MCP_URL",
    "http://mcp-server.team1.svc.cluster.local:8184",
).rstrip("/")
LISTEN_PORT = int(os.getenv("PORT", "8000"))
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "300"))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("github-elicitation-tool")

_http_client = httpx.AsyncClient(
    timeout=httpx.Timeout(REQUEST_TIMEOUT),
    follow_redirects=True,
)


def _build_upstream_url(path: str, query: str) -> str:
    normalized_path = path if path.startswith("/") else f"/{path}"
    url = f"{UPSTREAM_BASE_URL}{normalized_path}"
    if query:
        url = f"{url}?{query}"
    return url


def _filtered_headers(request: Request) -> dict[str, str]:
    excluded = {"host", "content-length", "connection"}
    headers: dict[str, str] = {}
    for key, value in request.headers.items():
        if key.lower() not in excluded:
            headers[key] = value
    return headers


async def _close_response(response: httpx.Response) -> None:
    await response.aclose()


app = FastAPI(title="github-elicitation-tool")


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok", "upstream": UPSTREAM_BASE_URL}


@app.api_route(
    "/mcp",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
)
@app.api_route(
    "/mcp/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
)
async def proxy_mcp(request: Request, path: str = "") -> Response:
    upstream_path = "/mcp" if not path else f"/mcp/{path}"
    upstream_url = _build_upstream_url(upstream_path, request.url.query)
    body = await request.body()
    headers = _filtered_headers(request)

    logger.info(
        "Proxying %s %s to %s",
        request.method,
        request.url.path,
        upstream_url,
    )

    try:
        upstream_response = await _http_client.send(
            _http_client.build_request(
                method=request.method,
                url=upstream_url,
                headers=headers,
                content=body,
            ),
            stream=True,
        )
    except httpx.HTTPError as exc:
        logger.exception("Upstream MCP request failed: %s", exc)
        return JSONResponse(
            status_code=502,
            content={
                "error": "upstream_mcp_unavailable",
                "message": str(exc),
                "upstream": UPSTREAM_BASE_URL,
            },
        )

    response_headers = {
        key: value
        for key, value in upstream_response.headers.items()
        if key.lower() not in {"content-length", "connection", "transfer-encoding"}
    }

    return Response(
        content=await upstream_response.aread(),
        status_code=upstream_response.status_code,
        headers=response_headers,
        media_type=upstream_response.headers.get("content-type"),
        background=BackgroundTask(_close_response, upstream_response),
    )


@app.api_route(
    "/",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
)
async def root() -> Response:
    return PlainTextResponse(
        "github-elicitation-tool proxy is running. Use /mcp for MCP traffic."
    )

# Made with Bob
