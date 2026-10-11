
import os
import hmac
import secrets
from datetime import datetime, timedelta, timezone

import bcrypt
from dotenv import load_dotenv
from jose import JWTError, jwt
from fastapi import Depends, HTTPException, Security, status
from fastapi.security import (
    APIKeyHeader,
    HTTPAuthorizationCredentials,
    HTTPBearer,
)
from sqlalchemy.orm import Session

from .database import get_db
from .models import User

load_dotenv()

ALGORITHM = "HS256"
JWT_ISSUER = "penguin-store"
JWT_AUDIENCE = "penguin-store-users"

SECRET_KEY = os.getenv("SECRET_KEY", "").strip()
AGENT_API_KEY = os.getenv("AGENT_API_KEY", "").strip()

ACCESS_TOKEN_EXPIRE_MINUTES = int(
    os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "10080")
)

if len(SECRET_KEY) < 32:
    raise RuntimeError(
        "SECRET_KEY must be configured with a secure random value."
    )

if len(AGENT_API_KEY) < 32:
    raise RuntimeError(
        "AGENT_API_KEY must be configured with a secure random value."
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


def verify_password(
    plain_password: str,
    hashed_password: str,
) -> bool:
    if not plain_password or not hashed_password:
        return False

    password_bytes = plain_password.encode("utf-8")

    if len(password_bytes) > 72:
        return False

    try:
        return bcrypt.checkpw(
            password_bytes,
            hashed_password.encode("utf-8"),
        )
    except (ValueError, TypeError):
        return False


def get_password_hash(password: str) -> str:
    if not isinstance(password, str) or not password:
        raise ValueError("Password cannot be empty.")

    password_bytes = password.encode("utf-8")

    if len(password_bytes) > 72:
        raise ValueError(
            "Password must not exceed 72 UTF-8 bytes."
        )

    salt = bcrypt.gensalt(rounds=12)

    hashed_password = bcrypt.hashpw(
        password_bytes,
        salt,
    )

    return hashed_password.decode("utf-8")


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

    return jwt.encode(
        payload,
        SECRET_KEY,
        algorithm=ALGORITHM,
    )


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


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Security(
        bearer_scheme
    ),
    db: Session = Depends(get_db),
) -> User:
    if credentials is None:
        raise _auth_error()

    if credentials.scheme.lower() != "bearer":
        raise _auth_error()

    payload = decode_access_token(credentials.credentials)

    user = db.query(User).filter(
        User.email == payload["sub"]
    ).first()

    if user is None:
        raise _auth_error()

    return user


def get_current_admin_user(
    current_user: User = Depends(get_current_user),
) -> User:
    if not current_user.is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Administrator access required.",
        )

    return current_user


async def verify_agent(
    api_key: str | None = Security(api_key_header),
) -> str:
    if not api_key or not hmac.compare_digest(
        api_key,
        AGENT_API_KEY,
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid CTRL-X agent credentials.",
        )

    return api_key
