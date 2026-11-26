"""Penguin Store native Model Context Protocol (MCP) commerce layer.

Stateless JSON-RPC 2.0 over HTTP (`POST /mcp`) implementing MCP 2026-07-28
with full 2025-11-25 backwards compatibility, backed by the live Supabase catalog.
"""

from app.mcp.protocol import LATEST_VERSION, LEGACY_VERSION, SUPPORTED_VERSIONS

PROTOCOL_VERSION_2026_07_28 = LATEST_VERSION
PROTOCOL_VERSION_2025_11_25 = LEGACY_VERSION

__all__ = [
    "LATEST_VERSION",
    "LEGACY_VERSION",
    "SUPPORTED_VERSIONS",
    "PROTOCOL_VERSION_2026_07_28",
    "PROTOCOL_VERSION_2025_11_25",
]
