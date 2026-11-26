"""Native FastAPI MCP server: stateless JSON-RPC 2.0 over HTTP (2026-07-28 + 2025-11-25)."""

from __future__ import annotations

import hashlib
import json
import logging
import time
from typing import Any, Optional
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool

from app.core.config import settings
from app.core.database import get_db
from app.core.security import get_current_user, get_optional_current_user, resolve_user_role
from app.mcp import audit, registry
from app.mcp import auth as mcp_auth
from app.mcp.protocol import (
    INTERNAL_ERROR,
    INVALID_PARAMS,
    LATEST_VERSION,
    LEGACY_VERSION,
    META_CLIENT_INFO,
    META_PROTOCOL_VERSION,
    META_SERVER_INFO,
    METHOD_NOT_FOUND,
    PARSE_ERROR,
    SUPPORTED_VERSIONS,
    JSONRPCRequest,
    MCPError,
    error_response,
    parse_request,
    resolve_protocol_version,
    success_response,
    validate_routing_headers,
)
from app.models import User

logger = logging.getLogger(__name__)
router = APIRouter(tags=["MCP"])

MAX_BODY_BYTES = 256 * 1024
CACHEABLE_METHODS = {
    "server/discover",
    "tools/list",
    "resources/list",
    "resources/templates/list",
    "prompts/list",
}


def server_info() -> dict[str, Any]:
    return {
        "name": registry.SERVER_NAME,
        "title": registry.SERVER_TITLE,
        "version": registry.SERVER_VERSION,
        "description": (
            "Database-grounded commerce tools for Penguin Store: live catalog search, trust-verified "
            "comparison, authoritative pricing, cart, favorites, B2B RFQ and order tracking."
        ),
        "websiteUrl": "https://penguinstore.co",
    }


def capabilities() -> dict[str, Any]:
    return {
        "tools": {"listChanged": False},
        "resources": {"subscribe": False, "listChanged": False},
        "prompts": {"listChanged": False},
        "logging": {},
    }


def discovery_document() -> dict[str, Any]:
    return {
        "protocolVersion": SUPPORTED_VERSIONS[0],
        "supportedVersions": list(SUPPORTED_VERSIONS),
        "capabilities": capabilities(),
        "serverInfo": server_info(),
        "instructions": (
            "Stateless MCP over HTTP POST /mcp. Anonymous callers may use read-only catalog tools, "
            "resources and prompts. Send 'Authorization: Bearer <JWT or ps_mcp_ API key>' for cart, "
            "favorites, B2B RFQ and order tools."
        ),
        "authentication": {
            "schemes": ["bearer-jwt", "bearer-api-key"],
            "apiKeyPrefix": mcp_auth.KEY_PREFIX,
            "scopes": list(mcp_auth.ALL_SCOPES),
        },
        "counts": {
            "tools": len(registry.TOOLS),
            "resources": len(registry.RESOURCES) + len(registry.RESOURCE_TEMPLATES),
            "prompts": len(registry.PROMPTS),
        },
        "endpoints": {"mcp": "/mcp", "wellKnown": "/.well-known/mcp.json"},
    }


def _origin_allowed(origin: Optional[str]) -> bool:
    """DNS-rebinding protection: reject browser Origins outside the CORS allowlist."""
    if not origin:
        return True
    clean = origin.rstrip("/")
    if clean in settings.allowed_origins:
        return True
    if not settings.IS_PRODUCTION:
        host = urlsplit(clean).hostname
        return host in {"localhost", "127.0.0.1", "::1"}
    return False


def _json_response(
    payload: dict[str, Any],
    status_code: int = 200,
    headers: Optional[dict[str, str]] = None,
    audit_entry: Optional[dict[str, Any]] = None,
) -> JSONResponse:
    resp = JSONResponse(payload, status_code=status_code, headers=headers)
    if audit_entry is not None:
        resp.background = BackgroundTask(audit.log_call, audit_entry)
    return resp


def _wants_sse(accept: str) -> bool:
    lowered = accept.lower()
    if "text/event-stream" not in lowered:
        return False
    sse_at = lowered.index("text/event-stream")
    json_at = lowered.find("application/json")
    return json_at == -1 or sse_at < json_at


def _sse_response(
    payload: dict[str, Any],
    headers: dict[str, str],
    audit_entry: dict[str, Any],
    progress_token: Any = None,
) -> StreamingResponse:
    def _events():
        if progress_token is not None:
            note = {
                "jsonrpc": "2.0",
                "method": "notifications/progress",
                "params": {"progressToken": progress_token, "progress": 1, "total": 1},
            }
            yield f"event: message\ndata: {json.dumps(note)}\n\n"
        yield f"event: message\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"

    resp = StreamingResponse(
        _events(),
        media_type="text/event-stream",
        headers={**headers, "Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )
    resp.background = BackgroundTask(audit.log_call, audit_entry)
    return resp


def _dispatch(
    req: JSONRPCRequest,
    version: str,
    principal: Optional[mcp_auth.Principal],
) -> dict[str, Any]:
    method = req.method
    params = req.params or {}
    stateless = version == LATEST_VERSION

    if method == "server/discover":
        result = discovery_document()
    elif method == "initialize":
        result = {
            "protocolVersion": version,
            "capabilities": capabilities(),
            "serverInfo": server_info(),
            "instructions": discovery_document()["instructions"],
        }
    elif method == "ping":
        result = {}
    elif method == "logging/setLevel":
        result = {}
    elif method == "tools/list":
        result = {"tools": registry.list_tools()}
    elif method == "tools/call":
        name = params.get("name")
        if not isinstance(name, str) or not name:
            raise MCPError(INVALID_PARAMS, 'tools/call requires a string "name".')
        result = registry.call_tool(name, params.get("arguments"), principal)
    elif method == "resources/list":
        result = {"resources": registry.RESOURCES}
    elif method == "resources/templates/list":
        result = {"resourceTemplates": registry.RESOURCE_TEMPLATES}
    elif method == "resources/read":
        uri = params.get("uri")
        if not isinstance(uri, str) or not uri:
            raise MCPError(INVALID_PARAMS, 'resources/read requires a string "uri".')
        result = registry.read_resource(uri, version)
    elif method == "prompts/list":
        result = {"prompts": registry.list_prompts()}
    elif method == "prompts/get":
        name = params.get("name")
        if not isinstance(name, str) or not name:
            raise MCPError(INVALID_PARAMS, 'prompts/get requires a string "name".')
        result = registry.get_prompt(name, params.get("arguments"))
    else:
        raise MCPError(METHOD_NOT_FOUND, f"Method not found: {method}")

    if stateless:
        meta = dict(result.get("_meta") or {})
        meta[META_SERVER_INFO] = server_info()
        meta[META_PROTOCOL_VERSION] = version
        result["_meta"] = meta
    return result


@router.post("/mcp")
async def mcp_endpoint(request: Request, db: Session = Depends(get_db)):
    started = time.perf_counter()
    headers_in = request.headers
    source = (headers_in.get("x-mcp-source") or "http").strip().lower()[:24]
    if source not in {"http", "simulator", "hub-inspector", "stdio-bridge", "ctrl-x", "voice"}:
        source = "http"

    audit_entry: dict[str, Any] = {
        "source": source,
        "method": "",
        "protocol_version": "",
        "principal_type": "anonymous",
        "success": False,
    }

    def _fail(err: MCPError, rid: Any = None) -> JSONResponse:
        audit_entry.update(
            latency_ms=(time.perf_counter() - started) * 1000.0,
            success=False,
            error_code=err.code,
            http_status=err.http_status,
        )
        hdrs = dict(err.headers)
        if audit_entry.get("protocol_version"):
            hdrs["MCP-Protocol-Version"] = audit_entry["protocol_version"]
        return _json_response(
            error_response(rid, err.code, err.message, err.data),
            status_code=err.http_status,
            headers=hdrs,
            audit_entry=audit_entry,
        )

    if not _origin_allowed(headers_in.get("origin")):
        return _fail(MCPError(-32600, "Origin not allowed.", http_status=403))

    raw_body = await request.body()
    if len(raw_body) > MAX_BODY_BYTES:
        return _fail(MCPError(-32600, "Request body too large.", http_status=413))
    try:
        decoded = json.loads(raw_body or b"")
    except (ValueError, UnicodeDecodeError):
        return _fail(MCPError(PARSE_ERROR, "Parse error: body is not valid JSON.", http_status=400))

    rid = decoded.get("id") if isinstance(decoded, dict) else None
    try:
        req, is_notification = parse_request(decoded)
        assert req is not None
        audit_entry["method"] = req.method
        if req.method == "tools/call":
            audit_entry["tool_name"] = (req.params or {}).get("name")
        client = req.meta.get(META_CLIENT_INFO) or (req.params or {}).get("clientInfo") or {}
        if isinstance(client, dict):
            audit_entry["client_name"] = client.get("name")

        validate_routing_headers(
            req,
            headers_in.get("mcp-method"),
            headers_in.get("mcp-name"),
        )

        if is_notification:
            audit_entry.update(
                protocol_version=headers_in.get("mcp-protocol-version") or LEGACY_VERSION,
                latency_ms=(time.perf_counter() - started) * 1000.0,
                success=True,
                http_status=202,
            )
            resp = Response(status_code=202)
            resp.background = BackgroundTask(audit.log_call, audit_entry)
            return resp

        version = resolve_protocol_version(req.method, req, headers_in.get("mcp-protocol-version"))
        audit_entry["protocol_version"] = version

        principal = await run_in_threadpool(
            mcp_auth.resolve_principal, headers_in.get("authorization"), db
        )
        if principal is not None:
            audit_entry.update(
                principal_type=principal.auth_type,
                user_id=principal.user_id,
                key_id=principal.key_id,
            )

        result = await run_in_threadpool(_dispatch, req, version, principal)
        payload = success_response(req.id, result)

        resp_headers = {"MCP-Protocol-Version": version, "Vary": "Authorization, Accept"}
        if req.method in CACHEABLE_METHODS:
            etag = '"' + hashlib.sha1(
                json.dumps(result, sort_keys=True, default=str).encode()
            ).hexdigest()[:16] + '"'
            resp_headers["ETag"] = etag
            resp_headers["Cache-Control"] = "public, max-age=60"
            if headers_in.get("if-none-match") == etag:
                audit_entry.update(
                    latency_ms=(time.perf_counter() - started) * 1000.0,
                    success=True,
                    http_status=304,
                )
                r304 = Response(status_code=304, headers=resp_headers)
                r304.background = BackgroundTask(audit.log_call, audit_entry)
                return r304
        else:
            resp_headers["Cache-Control"] = "no-store"

        is_tool_error = bool(result.get("isError")) if req.method == "tools/call" else False
        elapsed = (time.perf_counter() - started) * 1000.0
        audit_entry.update(
            latency_ms=elapsed,
            success=not is_tool_error,
            http_status=200,
        )
        resp_headers["Server-Timing"] = f"mcp;dur={elapsed:.1f}"

        if _wants_sse(headers_in.get("accept", "")):
            progress = req.meta.get("progressToken") or (req.params or {}).get("_meta", {}).get(
                "progressToken"
            )
            return _sse_response(payload, resp_headers, audit_entry, progress)
        return _json_response(payload, headers=resp_headers, audit_entry=audit_entry)

    except MCPError as exc:
        return _fail(exc, rid if isinstance(rid, (str, int)) and not isinstance(rid, bool) else None)
    except mcp_auth.MCPKeyStoreError:
        return _fail(MCPError(INTERNAL_ERROR, "Authentication backend unavailable.", http_status=503), rid)
    except Exception:
        logger.exception("Unhandled MCP error")
        return _fail(
            MCPError(INTERNAL_ERROR, "Internal server error.", http_status=500),
            rid if isinstance(rid, (str, int)) and not isinstance(rid, bool) else None,
        )


@router.get("/mcp")
async def mcp_discovery(request: Request):
    accept = request.headers.get("accept", "").lower()
    if "text/event-stream" in accept and "application/json" not in accept and "*/*" not in accept:
        # Spec: servers that do not offer a server->client SSE stream answer GET with 405.
        return Response(status_code=405, headers={"Allow": "POST"})
    return JSONResponse(
        discovery_document(),
        headers={"Cache-Control": "public, max-age=60", "MCP-Protocol-Version": LATEST_VERSION},
    )


@router.get("/.well-known/mcp.json")
async def mcp_well_known():
    doc = discovery_document()
    doc["name"] = registry.SERVER_NAME
    doc["transport"] = {"type": "streamable-http", "url": "/mcp", "stateless": True}
    return JSONResponse(doc, headers={"Cache-Control": "public, max-age=300"})


# ---------------------------------------------------------------------------
# Scoped personal API keys
# ---------------------------------------------------------------------------


class MCPKeyCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=80)
    scopes: list[str] = Field(default_factory=lambda: sorted(mcp_auth.CUSTOMER_SCOPES))
    expires_in_days: Optional[int] = Field(default=90, ge=1, le=365)


def _key_store_unavailable() -> HTTPException:
    return HTTPException(
        status_code=503,
        detail="MCP key storage is not ready. Run supabase_migrations.sql section 19.",
    )


@router.post("/api/v1/mcp/keys", status_code=status.HTTP_201_CREATED)
def create_mcp_key(payload: MCPKeyCreate, current_user: User = Depends(get_current_user)):
    role = resolve_user_role(current_user)
    scopes = list(dict.fromkeys(payload.scopes))
    invalid = [s for s in scopes if s not in mcp_auth.ALL_SCOPES]
    if invalid or not scopes:
        raise HTTPException(status_code=422, detail=f"Unknown or empty scopes: {invalid or scopes}")
    if mcp_auth.SCOPE_ADMIN_READ in scopes and role != "admin":
        raise HTTPException(status_code=403, detail="Only administrators can mint admin:read keys.")
    try:
        plaintext, row = mcp_auth.create_key(
            current_user.id, current_user.email, payload.name, scopes, payload.expires_in_days
        )
    except mcp_auth.MCPKeyStoreError:
        raise _key_store_unavailable()
    return {
        "key": plaintext,
        "id": row.get("id"),
        "name": row.get("name"),
        "prefix": row.get("key_prefix"),
        "scopes": row.get("scopes"),
        "expires_at": row.get("expires_at"),
        "created_at": row.get("created_at"),
        "warning": "Store this key now. It is stored only as a SHA-256 hash and cannot be shown again.",
    }


@router.get("/api/v1/mcp/keys")
def list_mcp_keys(current_user: User = Depends(get_current_user)):
    try:
        keys = mcp_auth.list_keys(current_user.id)
    except mcp_auth.MCPKeyStoreError:
        raise _key_store_unavailable()
    return {"count": len(keys), "keys": keys}


@router.delete("/api/v1/mcp/keys/{key_id}")
def revoke_mcp_key(key_id: int, current_user: User = Depends(get_current_user)):
    try:
        revoked = mcp_auth.revoke_key(current_user.id, key_id)
    except mcp_auth.MCPKeyStoreError:
        raise _key_store_unavailable()
    if not revoked:
        raise HTTPException(status_code=404, detail="Key not found.")
    return {"id": key_id, "revoked": True}


# ---------------------------------------------------------------------------
# Telemetry + Autonomous External Buyer Agent
# ---------------------------------------------------------------------------


@router.get("/api/v1/mcp/telemetry")
async def mcp_telemetry(current_user: Optional[User] = Depends(get_optional_current_user)):
    is_admin = current_user is not None and resolve_user_role(current_user) == "admin"
    return await run_in_threadpool(audit.summarize, is_admin)


class SimulateAgentRequest(BaseModel):
    goal: str = Field(..., min_length=3, max_length=400)
    max_steps: Optional[int] = Field(default=None, ge=1, le=8)
    max_hops: Optional[int] = Field(default=None, ge=1, le=8)


@router.post("/api/v1/mcp/simulate-agent")
async def simulate_agent(payload: SimulateAgentRequest, request: Request):
    from app.mcp.simulator import run_agent

    hops = payload.max_hops or payload.max_steps or 4
    return await run_agent(request.app, payload.goal.strip(), hops)
