"""Enterprise security, JWT verification, password hashing, and centralized RBAC."""

from __future__ import annotations

import hmac
import secrets
from datetime import datetime, timedelta, timezone
from typing import Iterable

import bcrypt
from fastapi import Depends, HTTPException, Security, status
from fastapi.security import (
    APIKeyHeader,
    HTTPAuthorizationCredentials,
    HTTPBearer,
)
from jose import JWTError, jwt
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.database import get_db
from app.models import User

ALGORITHM = "HS256"
JWT_ISSUER = "penguin-store"
JWT_AUDIENCE = "penguin-store-users"

SECRET_KEY = settings.SECRET_KEY
AGENT_API_KEY = settings.AGENT_API_KEY
ACCESS_TOKEN_EXPIRE_MINUTES = settings.ACCESS_TOKEN_EXPIRE_MINUTES

if len(SECRET_KEY) < 32:
    raise RuntimeError(
        "SECRET_KEY must be configured with a secure random value (>= 32 chars)."
    )

if len(AGENT_API_KEY) < 32:
    raise RuntimeError(
        "AGENT_API_KEY must be configured with a secure random value (>= 32 chars)."
    )

if not 1 <= ACCESS_TOKEN_EXPIRE_MINUTES <= 10080:
    raise RuntimeError(
        "ACCESS_TOKEN_EXPIRE_MINUTES must be between 1 and 10080."
    )

api_key_header = APIKeyHeader(
    name="X-Agent-Key",
    auto_error=False,
)

bearer_scheme = HTTPBearer(
    scheme_name="PenguinStoreJWT",
    auto_error=False,
)


def resolve_user_role(user: User) -> str:
    """Resolve canonical role name from DB user (preserving legacy is_admin)."""
    if getattr(user, "is_admin", False):
        return "admin"
    raw_role = str(getattr(user, "role", "customer") or "customer").strip().lower()
    return raw_role or "customer"


def verify_password(plain_password: str, hashed_password: str) -> bool:
    if not plain_password or not hashed_password:
        return False

    password_bytes = plain_password.encode("utf-8")
    if len(password_bytes) > 72:
        return False

    try:
        return bcrypt.checkpw(password_bytes, hashed_password.encode("utf-8"))
    except (ValueError, TypeError):
        return False


def get_password_hash(password: str) -> str:
    if not isinstance(password, str) or not password:
        raise ValueError("Password cannot be empty.")

    password_bytes = password.encode("utf-8")
    if len(password_bytes) > 72:
        raise ValueError("Password must not exceed 72 UTF-8 bytes.")

    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(password_bytes, salt).decode("utf-8")


def create_access_token(
    data: dict,
    expires_delta: timedelta | None = None,
) -> str:
    payload = data.copy()
    subject = payload.get("sub")

    if not isinstance(subject, str) or not subject.strip():
        raise ValueError("JWT subject is required.")

    now = datetime.now(timezone.utc)
    expiry = now + (
        expires_delta
        if expires_delta is not None
        else timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    )

    payload.update({
        "sub": subject.strip(),
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "iat": int(now.timestamp()),
        "nbf": int(now.timestamp()),
        "exp": int(expiry.timestamp()),
        "jti": secrets.token_urlsafe(24),
        "token_type": "access",
    })

    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def _auth_error() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired authentication token.",
        headers={"WWW-Authenticate": "Bearer"},
    )


def decode_access_token(token: str) -> dict:
    if not token:
        raise _auth_error()

    try:
        payload = jwt.decode(
            token,
            SECRET_KEY,
            algorithms=[ALGORITHM],
            audience=JWT_AUDIENCE,
            issuer=JWT_ISSUER,
            options={
                "require_exp": True,
                "require_iat": True,
                "require_nbf": True,
                "require_sub": True,
            },
        )

        if payload.get("token_type") != "access":
            raise _auth_error()

        subject = payload.get("sub")
        if not isinstance(subject, str) or not subject.strip():
            raise _auth_error()

        return payload
    except JWTError:
        raise _auth_error()


def _lookup_active_user(db: Session, email: str) -> User | None:
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_user_by_email_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    clean_email = email.strip().lower()
    user = None
    if is_pg_tcp_reachable():
        try:
            user = (
                db.query(User)
                .filter(func.lower(User.email) == clean_email)
                .first()
            )
        except OperationalError:
            db.rollback()
            mark_pg_tcp_unreachable()

    if user is None and not is_pg_tcp_reachable():
        user = fetch_user_by_email_https(clean_email)

    if user is None:
        return None
    if not getattr(user, "is_active", True):
        return None
    return user


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Security(bearer_scheme),
    db: Session = Depends(get_db),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _auth_error()

    payload = decode_access_token(credentials.credentials)
    user = _lookup_active_user(db, payload["sub"])

    if user is None:
        raise _auth_error()

    return user


def get_optional_current_user(
    credentials: HTTPAuthorizationCredentials | None = Security(bearer_scheme),
    db: Session = Depends(get_db),
) -> User | None:
    if credentials is None or not credentials.credentials:
        return None

    if credentials.scheme.lower() != "bearer":
        raise _auth_error()

    payload = decode_access_token(credentials.credentials)
    user = _lookup_active_user(db, payload["sub"])

    if user is None:
        raise _auth_error()

    return user


def require_role(allowed_roles: Iterable[str]):
    """Centralized FastAPI RBAC dependency enforcing server-side role checks."""
    normalized_roles = {str(r).strip().lower() for r in allowed_roles if r}

    def _role_checker(current_user: User = Depends(get_current_user)) -> User:
        role = resolve_user_role(current_user)
        if role not in normalized_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Insufficient permissions for this operation.",
            )
        return current_user

    return _role_checker


def get_current_admin_user(
    current_user: User = Depends(require_role(["admin"])),
) -> User:
    return current_user


async def verify_agent(
    api_key: str | None = Security(api_key_header),
) -> str:
    if not api_key or not hmac.compare_digest(api_key, AGENT_API_KEY):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid CTRL-X agent credentials.",
        )
    return api_key


async def verify_admin_or_agent(
    api_key: str | None = Security(api_key_header),
    credentials: HTTPAuthorizationCredentials | None = Security(bearer_scheme),
    db: Session = Depends(get_db),
) -> str:
    if api_key and hmac.compare_digest(api_key, AGENT_API_KEY):
        return "agent"

    if credentials is not None and credentials.scheme.lower() == "bearer":
        payload = decode_access_token(credentials.credentials)
        user = _lookup_active_user(db, payload["sub"])
        if user is not None and resolve_user_role(user) in ("admin", "supplier"):
            return f"{resolve_user_role(user)}:{user.email}"
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Administrator or supplier access required.",
        )

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Administrator or CTRL-X agent credentials required.",
    )
