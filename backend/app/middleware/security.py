"""Security headers, CORS configuration, and memory-bounded sliding-window rate limiting."""

from __future__ import annotations

import logging
import math
import time
from collections import deque
from threading import Lock

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.core.config import settings

logger = logging.getLogger(__name__)

_RATE_LOCK = Lock()
_RATE_BUCKETS: dict[str, deque[float]] = {}
MAX_RATE_BUCKETS = 4096

# (allowed_methods, exact_paths, prefix_paths, window_seconds, max_requests, group_name)
_RATE_RULES: tuple[tuple[frozenset[str], tuple[str, ...], tuple[str, ...], float, int, str], ...] = (
    (
        frozenset({"POST"}),
        ("/login", "/signup", "/api/v1/auth/login", "/api/v1/auth/register"),
        ("/api/v1/auth/",),
        60.0,
        15,
        "auth",
    ),
    (
        frozenset({"POST"}),
        (
            "/api/v1/ai/transcribe",
            "/api/v1/ai/speak",
            "/api/agent/chat",
            "/api/agent/approve",
            "/api/v1/search/multimodal",
            "/api/search/multimodal",
            "/api/search/visual",
        ),
        (),
        60.0,
        25,
        "ai_compute",
    ),
    (
        frozenset({"POST", "GET"}),
        (
            "/api/orders/checkout",
            "/api/v1/orders/",
            "/create-checkout-session",
            "/api/v1/stripe/create-checkout-session",
            "/api/premium-subscriptions/checkout",
            "/api/payments/checkout-status",
        ),
        ("/api/v1/stripe/verify-session/",),
        60.0,
        20,
        "checkout_stripe",
    ),
)


def reset_rate_limiter_for_tests() -> None:
    """Clear in-memory rate-limit sliding windows (used by automated test suites)."""
    with _RATE_LOCK:
        _RATE_BUCKETS.clear()


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
            "Idempotency-Key",
            "MCP-Protocol-Version",
            "Mcp-Method",
            "Mcp-Name",
        ],
    )


def _match_rate_rule(method: str, path: str) -> tuple[float, int, str] | None:
    upper_method = method.upper()
    for methods, exact_paths, prefix_paths, window, limit, group in _RATE_RULES:
        if upper_method not in methods:
            continue
        if path in exact_paths or any(path.startswith(pref) for pref in prefix_paths):
            return window, limit, group
    return None


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    if forwarded:
        return forwarded[:64]
    return request.client.host if request.client else "unknown"


def _evict_stale_buckets_locked(now: float, max_window: float = 60.0) -> None:
    expired_keys = [
        k for k, q in _RATE_BUCKETS.items() if not q or (now - q[-1]) > max_window
    ]
    for k in expired_keys:
        _RATE_BUCKETS.pop(k, None)
    if len(_RATE_BUCKETS) >= MAX_RATE_BUCKETS:
        # Evict oldest 25% keys to guarantee O(1) bounded memory on Render 512 MB RAM
        victim_count = max(1, MAX_RATE_BUCKETS // 4)
        for k in list(_RATE_BUCKETS.keys())[:victim_count]:
            _RATE_BUCKETS.pop(k, None)


async def security_and_rate_limit_middleware(request: Request, call_next):
    path = request.url.path
    rule = _match_rate_rule(request.method, path)
    if rule is not None:
        window, limit, group = rule
        ip = _client_ip(request)
        bucket_key = f"{ip}:{group}:{path}"
        now = time.monotonic()

        with _RATE_LOCK:
            if len(_RATE_BUCKETS) >= MAX_RATE_BUCKETS and bucket_key not in _RATE_BUCKETS:
                _evict_stale_buckets_locked(now, window)

            q = _RATE_BUCKETS.get(bucket_key)
            if q is None:
                q = deque()
                _RATE_BUCKETS[bucket_key] = q

            while q and (now - q[0]) > window:
                q.popleft()

            if len(q) >= limit:
                retry_after = max(1, int(math.ceil(window - (now - q[0]))))
                return JSONResponse(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    headers={
                        "Retry-After": str(retry_after),
                        "X-Content-Type-Options": "nosniff",
                        "X-Frame-Options": "DENY",
                    },
                    content={
                        "detail": "Too many requests. Please wait a moment and try again.",
                        "retry_after_seconds": retry_after,
                    },
                )
            q.append(now)

    response = await call_next(request)
    if (
        request.method == "GET"
        and response.status_code == 200
        and "Cache-Control" not in response.headers
        and (
            path in ("/products/", "/products/search", "/api/v1/products/", "/api/v1/products/search", "/api/premium-3d/catalog", "/api/premium-3d/showcase")
            or path.startswith("/api/v1/products/") and not path.endswith(("/reviews", "/review-insights"))
        )
    ):
        response.headers["Cache-Control"] = "public, max-age=15, stale-while-revalidate=45"
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault(
        "Referrer-Policy",
        "strict-origin-when-cross-origin",
    )
    # Allow self-origin microphone & camera so WebRTC Voice Concierge & Visual Search work on HTTPS
    response.headers.setdefault(
        "Permissions-Policy",
        "camera=(self), microphone=(self), geolocation=()",
    )
    forwarded_proto = request.headers.get("x-forwarded-proto", "").lower()
    if settings.IS_PRODUCTION or forwarded_proto == "https":
        response.headers.setdefault(
            "Strict-Transport-Security",
            "max-age=31536000; includeSubDomains",
        )
    return response
