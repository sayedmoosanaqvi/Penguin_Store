"""Security headers, CORS configuration, and route-level sliding-window rate limiting."""

from __future__ import annotations

import logging
import time
from collections import defaultdict, deque
from threading import Lock

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.core.config import settings

logger = logging.getLogger(__name__)

_RATE_LOCK = Lock()
_RATE_BUCKETS: dict[str, deque[float]] = defaultdict(deque)

# (path_prefix, window_seconds, max_requests)
_RATE_RULES: tuple[tuple[tuple[str, ...], float, int], ...] = (
    (("/login", "/signup", "/api/v1/auth/login", "/api/v1/auth/register"), 60.0, 20),
    (("/api/agent/chat", "/api/search/visual"), 60.0, 30),
    (("/api/orders/checkout", "/api/v1/orders/"), 60.0, 15),
)


def configure_cors(app: FastAPI) -> None:
    local_origin_regex = (
        r"^http://(localhost|127\.0\.0\.1)(:\d+)?$"
        if not settings.IS_PRODUCTION
        else None
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_origin_regex=local_origin_regex,
        allow_credentials=True,
        allow_methods=[
            "GET",
            "POST",
            "PUT",
            "PATCH",
            "DELETE",
            "OPTIONS",
        ],
        allow_headers=[
            "Authorization",
            "Content-Type",
            "Accept",
            "X-Agent-Key",
            "X-Requested-With",
        ],
    )


def _match_rate_rule(method: str, path: str) -> tuple[float, int] | None:
    if method != "POST":
        return None
    for paths, window, limit in _RATE_RULES:
        if path in paths:
            return window, limit
    return None


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    if forwarded:
        return forwarded
    return request.client.host if request.client else "unknown"


async def security_and_rate_limit_middleware(request: Request, call_next):
    path = request.url.path
    rule = _match_rate_rule(request.method, path)
    if rule is not None:
        window, limit = rule
        ip = _client_ip(request)
        bucket_key = f"{ip}:{path}"
        now = time.monotonic()

        with _RATE_LOCK:
            q = _RATE_BUCKETS[bucket_key]
            while q and (now - q[0]) > window:
                q.popleft()
            if len(q) >= limit:
                return JSONResponse(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    content={
                        "detail": "Rate limit exceeded. Please wait a moment and try again."
                    },
                )
            q.append(now)

    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault(
        "Referrer-Policy",
        "strict-origin-when-cross-origin",
    )
    response.headers.setdefault(
        "Permissions-Policy",
        "camera=(self), microphone=(), geolocation=()",
    )
    if settings.IS_PRODUCTION:
        response.headers.setdefault(
            "Strict-Transport-Security",
            "max-age=31536000; includeSubDomains",
        )
    return response
