"""MCP authentication & authorization: user/admin JWT + scoped SHA-256 API keys."""

from __future__ import annotations

import hashlib
import logging
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Optional

from fastapi import HTTPException

from app.core.supabase_rest import get_supabase_client
from app.mcp.protocol import FORBIDDEN, UNAUTHORIZED, MCPError

logger = logging.getLogger(__name__)

KEY_PREFIX = "ps_mcp_"
SCOPE_CATALOG_READ = "catalog:read"
SCOPE_COMMERCE_WRITE = "commerce:write"
SCOPE_B2B_WRITE = "b2b:write"
SCOPE_ADMIN_READ = "admin:read"
ALL_SCOPES: tuple[str, ...] = (
    SCOPE_CATALOG_READ,
    SCOPE_COMMERCE_WRITE,
    SCOPE_B2B_WRITE,
    SCOPE_ADMIN_READ,
)
CUSTOMER_SCOPES: frozenset[str] = frozenset(
    {SCOPE_CATALOG_READ, SCOPE_COMMERCE_WRITE, SCOPE_B2B_WRITE}
)
MAX_KEYS_PER_USER = 10
KEY_TABLE = "mcp_api_keys"


class MCPKeyStoreError(RuntimeError):
    """Raised when the Supabase `mcp_api_keys` table is unavailable (migration missing)."""


@dataclass(frozen=True)
class Principal:
    auth_type: str  # "jwt" | "api_key"
    user_id: int
    email: str
    role: str
    scopes: frozenset[str] = field(default_factory=frozenset)
    key_id: Optional[int] = None
    key_prefix: Optional[str] = None

    @property
    def is_admin(self) -> bool:
        return self.role == "admin"

    def as_user_proxy(self):
        """Lightweight stand-in for a `User` row used by existing router helpers."""
        from types import SimpleNamespace

        return SimpleNamespace(
            id=self.user_id,
            email=self.email,
            role=self.role,
            is_admin=self.is_admin,
            is_active=True,
            full_name=None,
        )


def scopes_for_role(role: str) -> frozenset[str]:
    scopes = set(CUSTOMER_SCOPES)
    if role == "admin":
        scopes.add(SCOPE_ADMIN_READ)
    return frozenset(scopes)


def hash_key(plaintext: str) -> str:
    return hashlib.sha256(plaintext.encode("utf-8")).hexdigest()


def generate_key() -> tuple[str, str, str]:
    """Return (plaintext, display_prefix, sha256_hash). Plaintext is shown only once."""
    plaintext = f"{KEY_PREFIX}{secrets.token_urlsafe(32)}"
    return plaintext, plaintext[:14], hash_key(plaintext)


def _parse_ts(value: Any) -> Optional[datetime]:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _normalize_scopes(raw: Any) -> list[str]:
    if isinstance(raw, str):
        raw = [s.strip() for s in raw.strip("{}").split(",") if s.strip()]
    return [s for s in (raw or []) if s in ALL_SCOPES]


# --------------------------------------------------------------------------- data access


def lookup_user(db: Any, email: str):
    """Resolve an active user by e-mail (indirection so tests can patch it)."""
    from app.core.security import _lookup_active_user

    return _lookup_active_user(db, email)


def fetch_key_by_hash(key_hash: str) -> Optional[dict[str, Any]]:
    try:
        res = (
            get_supabase_client()
            .table(KEY_TABLE)
            .select("*")
            .eq("key_hash", key_hash)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        logger.warning("mcp_api_keys lookup failed: %s", exc)
        raise MCPKeyStoreError("MCP key storage is unavailable.") from exc
    rows = res.data or []
    return rows[0] if rows else None


def touch_key_last_used(key_id: int) -> None:
    try:
        get_supabase_client().table(KEY_TABLE).update(
            {"last_used_at": datetime.now(timezone.utc).isoformat()}
        ).eq("id", key_id).execute()
    except Exception:  # best effort
        pass


def create_key(
    user_id: int,
    email: str,
    name: str,
    scopes: Iterable[str],
    expires_in_days: Optional[int],
) -> tuple[str, dict[str, Any]]:
    plaintext, prefix, key_hash = generate_key()
    expires_at = (
        (datetime.now(timezone.utc) + timedelta(days=expires_in_days)).isoformat()
        if expires_in_days
        else None
    )
    row = {
        "user_id": user_id,
        "user_email": email.strip().lower(),
        "name": name.strip()[:80] or "MCP key",
        "key_prefix": prefix,
        "key_hash": key_hash,
        "scopes": list(scopes),
        "expires_at": expires_at,
    }
    client = get_supabase_client()
    try:
        existing = (
            client.table(KEY_TABLE)
            .select("id")
            .eq("user_id", user_id)
            .is_("revoked_at", "null")
            .execute()
        )
        if len(existing.data or []) >= MAX_KEYS_PER_USER:
            raise HTTPException(
                status_code=409,
                detail=f"Key limit reached ({MAX_KEYS_PER_USER}). Revoke an old key first.",
            )
        res = client.table(KEY_TABLE).insert(row).execute()
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("mcp_api_keys insert failed: %s", exc)
        raise MCPKeyStoreError("MCP key storage is unavailable.") from exc
    created = (res.data or [row])[0]
    created.pop("key_hash", None)
    return plaintext, created


def list_keys(user_id: int) -> list[dict[str, Any]]:
    try:
        res = (
            get_supabase_client()
            .table(KEY_TABLE)
            .select("id,name,key_prefix,scopes,expires_at,revoked_at,last_used_at,created_at")
            .eq("user_id", user_id)
            .order("id", desc=True)
            .execute()
        )
    except Exception as exc:
        raise MCPKeyStoreError("MCP key storage is unavailable.") from exc
    return list(res.data or [])


def revoke_key(user_id: int, key_id: int) -> bool:
    """Revoke a key owned by `user_id`. Returns False if not found (anti-IDOR)."""
    try:
        res = (
            get_supabase_client()
            .table(KEY_TABLE)
            .update({"revoked_at": datetime.now(timezone.utc).isoformat()})
            .eq("id", key_id)
            .eq("user_id", user_id)
            .execute()
        )
    except Exception as exc:
        raise MCPKeyStoreError("MCP key storage is unavailable.") from exc
    return bool(res.data)


# --------------------------------------------------------------------------- resolution


def _unauthorized(message: str) -> MCPError:
    return MCPError(
        UNAUTHORIZED,
        message,
        http_status=401,
        headers={"WWW-Authenticate": 'Bearer realm="penguin-store-mcp"'},
    )


def resolve_principal(authorization: Optional[str], db: Any) -> Optional[Principal]:
    """Resolve the caller. Returns None for anonymous; raises MCPError(401) for bad credentials."""
    if not authorization or not authorization.strip():
        return None

    scheme, _, token = authorization.strip().partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise _unauthorized("Authorization header must be 'Bearer <token>'.")

    if token.startswith(KEY_PREFIX):
        return _principal_from_api_key(token, db)
    return _principal_from_jwt(token, db)


def _principal_from_api_key(token: str, db: Any) -> Principal:
    try:
        row = fetch_key_by_hash(hash_key(token))
    except MCPKeyStoreError:
        raise MCPError(
            UNAUTHORIZED,
            "API key verification is temporarily unavailable.",
            http_status=503,
        )
    if row is None:
        raise _unauthorized("Invalid MCP API key.")
    if row.get("revoked_at"):
        raise _unauthorized("This MCP API key has been revoked.")
    expires = _parse_ts(row.get("expires_at"))
    if expires is not None and expires <= datetime.now(timezone.utc):
        raise _unauthorized("This MCP API key has expired.")

    user = lookup_user(db, str(row.get("user_email") or ""))
    if user is None:
        raise _unauthorized("The account that owns this MCP API key is inactive.")

    from app.core.security import resolve_user_role

    role = resolve_user_role(user)
    scopes = set(_normalize_scopes(row.get("scopes")))
    if role != "admin":
        scopes.discard(SCOPE_ADMIN_READ)

    if row.get("id") is not None:
        touch_key_last_used(int(row["id"]))

    return Principal(
        auth_type="api_key",
        user_id=int(getattr(user, "id", row.get("user_id") or 0)),
        email=str(getattr(user, "email", row.get("user_email") or "")).lower(),
        role=role,
        scopes=frozenset(scopes),
        key_id=int(row["id"]) if row.get("id") is not None else None,
        key_prefix=str(row.get("key_prefix") or ""),
    )


def _principal_from_jwt(token: str, db: Any) -> Principal:
    from app.core.security import decode_access_token, resolve_user_role

    try:
        payload = decode_access_token(token)
    except HTTPException:
        raise _unauthorized("Invalid or expired access token.")

    user = lookup_user(db, str(payload.get("sub") or ""))
    if user is None:
        raise _unauthorized("Invalid or expired access token.")

    role = resolve_user_role(user)
    return Principal(
        auth_type="jwt",
        user_id=int(getattr(user, "id", 0) or 0),
        email=str(user.email).lower(),
        role=role,
        scopes=scopes_for_role(role),
    )


def enforce_scope(principal: Optional[Principal], scope: str, read_only: bool) -> None:
    """Anonymous callers may only use read-only `catalog:read` tools."""
    if principal is None:
        if read_only and scope == SCOPE_CATALOG_READ:
            return
        raise _unauthorized(
            f"Authentication required: this tool needs the '{scope}' scope. "
            "Send 'Authorization: Bearer <jwt | ps_mcp_ key>'."
        )
    if scope not in principal.scopes:
        raise MCPError(
            FORBIDDEN,
            f"Insufficient scope: '{scope}' is required.",
            data={"required": scope, "granted": sorted(principal.scopes)},
            http_status=403,
        )
