"""Strict JSON-RPC 2.0 + MCP (2026-07-28 / 2025-11-25) protocol primitives."""

from __future__ import annotations

from typing import Any, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field

LATEST_VERSION = "2026-07-28"
LEGACY_VERSION = "2025-11-25"
SUPPORTED_VERSIONS: tuple[str, ...] = (LATEST_VERSION, LEGACY_VERSION)

JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"

META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"

# Standard JSON-RPC 2.0 error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

# MCP / implementation-defined codes
HEADER_MISMATCH = -32001
RESOURCE_NOT_FOUND_LEGACY = -32002  # only emitted in 2025-11-25 compatibility mode
UNAUTHORIZED = -32010
FORBIDDEN = -32011
RATE_LIMITED = -32012

RequestId = Union[str, int]


class JSONRPCRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    jsonrpc: Literal["2.0"] = "2.0"
    id: Optional[RequestId] = None
    method: str = Field(..., min_length=1, max_length=128)
    params: Optional[dict[str, Any]] = None

    @property
    def meta(self) -> dict[str, Any]:
        raw = (self.params or {}).get("_meta")
        return raw if isinstance(raw, dict) else {}


class JSONRPCErrorObject(BaseModel):
    code: int
    message: str
    data: Optional[Any] = None


class JSONRPCResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    jsonrpc: Literal["2.0"] = "2.0"
    id: Optional[RequestId] = None
    result: Optional[dict[str, Any]] = None
    error: Optional[JSONRPCErrorObject] = None

    def to_wire(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": self.id}
        if self.error is not None:
            payload["error"] = self.error.model_dump(exclude_none=True)
        else:
            payload["result"] = self.result if self.result is not None else {}
        return payload


class MCPError(Exception):
    """Protocol-level error mapped to a JSON-RPC error object + HTTP status."""

    def __init__(
        self,
        code: int,
        message: str,
        data: Any | None = None,
        http_status: int = 200,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data
        self.http_status = http_status
        self.headers = headers or {}


class ToolExecutionError(Exception):
    """Business-level tool failure surfaced as `isError: true` (not a protocol error)."""


def error_response(
    request_id: Optional[RequestId],
    code: int,
    message: str,
    data: Any | None = None,
) -> dict[str, Any]:
    return JSONRPCResponse(
        id=request_id,
        error=JSONRPCErrorObject(code=code, message=message, data=data),
    ).to_wire()


def success_response(request_id: Optional[RequestId], result: dict[str, Any]) -> dict[str, Any]:
    return JSONRPCResponse(id=request_id, result=result).to_wire()


def parse_request(raw: Any) -> tuple[Optional[JSONRPCRequest], bool]:
    """Validate a decoded JSON body as a single JSON-RPC 2.0 request/notification.

    Returns (request, is_notification). Raises MCPError(-32600) when invalid.
    Batching is rejected (removed from MCP as of 2025-06-18).
    """
    if isinstance(raw, list):
        raise MCPError(
            INVALID_REQUEST,
            "JSON-RPC batching is not supported by MCP. Send one request per POST.",
            http_status=400,
        )
    if not isinstance(raw, dict):
        raise MCPError(INVALID_REQUEST, "Request body must be a JSON object.", http_status=400)

    if raw.get("jsonrpc") != "2.0":
        raise MCPError(INVALID_REQUEST, 'Field "jsonrpc" must be exactly "2.0".', http_status=400)

    is_notification = "id" not in raw
    if not is_notification:
        rid = raw.get("id")
        # MCP forbids null ids and non-(string|integer) ids.
        if rid is None or isinstance(rid, bool) or not isinstance(rid, (str, int)):
            raise MCPError(
                INVALID_REQUEST,
                'Field "id" must be a non-null string or integer.',
                http_status=400,
            )

    if not isinstance(raw.get("method"), str) or not raw["method"].strip():
        raise MCPError(INVALID_REQUEST, 'Field "method" must be a non-empty string.', http_status=400)

    if "params" in raw and raw["params"] is not None and not isinstance(raw["params"], dict):
        raise MCPError(INVALID_PARAMS, 'Field "params" must be an object.', http_status=400)

    try:
        req = JSONRPCRequest.model_validate(raw)
    except Exception as exc:  # pydantic ValidationError
        raise MCPError(INVALID_REQUEST, f"Malformed JSON-RPC request: {exc}", http_status=400)
    return req, is_notification


def resolve_protocol_version(
    method: str,
    request: JSONRPCRequest,
    header_version: Optional[str],
) -> str:
    """Resolve the effective protocol version for a request (stateless-first).

    * `initialize` (2025-11-25 handshake): negotiate the client's requested version.
    * Everything else: `_meta["io.modelcontextprotocol/protocolVersion"]`, falling back to the
      `MCP-Protocol-Version` header, then to the legacy default.
    """
    meta_version = request.meta.get(META_PROTOCOL_VERSION)
    if meta_version is not None and not isinstance(meta_version, str):
        raise MCPError(INVALID_PARAMS, "_meta protocolVersion must be a string.", http_status=400)

    if method == "initialize":
        requested = (request.params or {}).get("protocolVersion")
        if isinstance(requested, str) and requested in SUPPORTED_VERSIONS:
            return requested
        # Spec: respond with a version the server supports (latest legacy handshake).
        return LEGACY_VERSION

    if meta_version and header_version and meta_version != header_version:
        raise MCPError(
            HEADER_MISMATCH,
            "MCP-Protocol-Version header does not match _meta protocolVersion.",
            data={"header": header_version, "meta": meta_version},
            http_status=400,
        )

    effective = meta_version or header_version or LEGACY_VERSION
    if effective not in SUPPORTED_VERSIONS:
        raise MCPError(
            INVALID_PARAMS,
            f"Unsupported protocol version: {effective}",
            data={"supported": list(SUPPORTED_VERSIONS), "requested": effective},
            http_status=400,
        )
    return effective


def validate_routing_headers(
    request: JSONRPCRequest,
    header_method: Optional[str],
    header_name: Optional[str],
) -> None:
    """Enforce `Mcp-Method` / `Mcp-Name` header-based routing consistency."""
    if header_method and header_method != request.method:
        raise MCPError(
            HEADER_MISMATCH,
            "Mcp-Method header does not match the JSON-RPC method.",
            data={"header": header_method, "body": request.method},
            http_status=400,
        )
    if header_name:
        params = request.params or {}
        body_name = params.get("name") or params.get("uri")
        if body_name is not None and str(body_name) != header_name:
            raise MCPError(
                HEADER_MISMATCH,
                "Mcp-Name header does not match params name/uri.",
                data={"header": header_name, "body": str(body_name)},
                http_status=400,
            )


# ---------------------------------------------------------------------------
# Minimal JSON Schema (2020-12 subset) argument validation for tool inputs.
# ---------------------------------------------------------------------------

_TYPE_CHECKS = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
}


def validate_arguments(schema: dict[str, Any], arguments: dict[str, Any]) -> list[str]:
    """Return a list of human-readable validation problems (empty == valid)."""
    problems: list[str] = []
    props: dict[str, Any] = schema.get("properties", {})

    for name in schema.get("required", []):
        if name not in arguments or arguments[name] is None:
            problems.append(f'Missing required argument "{name}".')

    if schema.get("additionalProperties") is False:
        for name in arguments:
            if name not in props:
                problems.append(f'Unexpected argument "{name}".')

    for name, value in arguments.items():
        spec = props.get(name)
        if spec is None or value is None:
            continue
        expected = spec.get("type")
        if expected and not _TYPE_CHECKS.get(expected, lambda _v: True)(value):
            problems.append(f'Argument "{name}" must be of type {expected}.')
            continue
        if "enum" in spec and value not in spec["enum"]:
            problems.append(f'Argument "{name}" must be one of {spec["enum"]}.')
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in spec and value < spec["minimum"]:
                problems.append(f'Argument "{name}" must be >= {spec["minimum"]}.')
            if "maximum" in spec and value > spec["maximum"]:
                problems.append(f'Argument "{name}" must be <= {spec["maximum"]}.')
        if isinstance(value, str):
            if "maxLength" in spec and len(value) > spec["maxLength"]:
                problems.append(f'Argument "{name}" exceeds maxLength {spec["maxLength"]}.')
            if "minLength" in spec and len(value) < spec["minLength"]:
                problems.append(f'Argument "{name}" is shorter than minLength {spec["minLength"]}.')
        if isinstance(value, list):
            if "maxItems" in spec and len(value) > spec["maxItems"]:
                problems.append(f'Argument "{name}" exceeds maxItems {spec["maxItems"]}.')
            if "minItems" in spec and len(value) < spec["minItems"]:
                problems.append(f'Argument "{name}" requires at least {spec["minItems"]} items.')
            item_spec = spec.get("items") or {}
            item_type = item_spec.get("type")
            if item_type:
                for idx, item in enumerate(value):
                    if not _TYPE_CHECKS.get(item_type, lambda _v: True)(item):
                        problems.append(f'Argument "{name}[{idx}]" must be of type {item_type}.')
    return problems
