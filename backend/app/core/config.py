"""Centralized environment & configuration management for Penguin Store."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlsplit

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parents[2]
load_dotenv(BACKEND_DIR / ".env")
load_dotenv()


class Settings:
    """Validated runtime settings loaded from environment variables."""

    def __init__(self) -> None:
        self.ENVIRONMENT: str = os.getenv("ENVIRONMENT", "development").strip().lower()
        self.IS_PRODUCTION: bool = self.ENVIRONMENT == "production"

        self.FRONTEND_URL: str = os.getenv("FRONTEND_URL", "").strip().rstrip("/")
        self.SECRET_KEY: str = os.getenv("SECRET_KEY", "").strip()
        self.AGENT_API_KEY: str = os.getenv("AGENT_API_KEY", "").strip()
        self.ACCESS_TOKEN_EXPIRE_MINUTES: int = int(
            os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "10080")
        )

        self.SUPABASE_URL: str = os.getenv("SUPABASE_URL", "").strip().rstrip("/")
        self.SUPABASE_SERVICE_KEY: str = (
            os.getenv("SUPABASE_SERVICE_KEY") or os.getenv("SUPABASE_KEY") or ""
        ).strip()
        self.SUPABASE_DATABASE_URL: str = (
            os.getenv("SUPABASE_DATABASE_URL") or os.getenv("DATABASE_URL") or ""
        ).strip()

        self.PUBLIC_ASSET_BUCKET: str = "penguin-store-assets"
        self.PRIVATE_3D_BUCKET: str = "penguin-store-3d"
        self.MAX_UPLOAD_BYTES: int = 10 * 1024 * 1024

        self.ENABLE_PUBLIC_3D_SHOWCASE: bool = (
            os.getenv("ENABLE_PUBLIC_3D_SHOWCASE", "true").strip().lower()
            not in ("false", "0", "no")
        )

    @property
    def allowed_origins(self) -> list[str]:
        origins: set[str] = set()

        if self.FRONTEND_URL:
            parsed = urlsplit(self.FRONTEND_URL)
            if parsed.scheme in ("http", "https") and parsed.netloc:
                origins.add(f"{parsed.scheme}://{parsed.netloc}")

        # Always permit the GitHub Pages deployment origin safely
        origins.add("https://penguin-store.github.io")
        raw_env_origins = os.getenv("ALLOWED_ORIGINS", "")
        for item in raw_env_origins.split(","):
            origin = item.strip().rstrip("/")
            if not origin or origin == "*":
                # Never allow wildcard '*' in CORS origins
                continue
            parsed = urlsplit(origin)
            if (
                parsed.scheme in ("http", "https")
                and parsed.netloc
                and not parsed.path
                and not parsed.query
                and not parsed.fragment
            ):
                origins.add(origin)

        return sorted(origins)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
