#!/usr/bin/env python3
"""Standard I/O (stdio) MCP JSON-RPC 2.0 Bridge for Penguin Store.

Allows external hosts (Claude Desktop, Cursor, VS Code, Zed, Windsurf, LangChain)
to interact with the Penguin Store MCP commerce server via local stdio.

Usage in Claude Desktop / VS Code configuration:
{
  "mcpServers": {
    "penguin-store": {
      "command": "python",
      "args": ["d:/Penguin_Store/backend/mcp_stdio_bridge.py"],
      "env": {
        "PENGUIN_MCP_URL": "http://127.0.0.1:8000/mcp",
        "PENGUIN_MCP_KEY": "ps_mcp_your_api_key_here"
      }
    }
  }
}
"""

import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = os.environ.get("PENGUIN_MCP_URL", "http://127.0.0.1:8000/mcp")
API_KEY = os.environ.get("PENGUIN_MCP_KEY", "").strip()
DEFAULT_PROTOCOL_VERSION = "2026-07-28"


def log(msg: str) -> None:
    sys.stderr.write(f"[mcp-stdio-bridge] {msg}\n")
    sys.stderr.flush()


def forward_request(url: str, payload_bytes: bytes, api_key: str = "") -> bytes:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "MCP-Protocol-Version": DEFAULT_PROTOCOL_VERSION,
        "User-Agent": "PenguinStore-StdioBridge/1.0",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    req = urllib.request.Request(url, data=payload_bytes, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30.0) as resp:
            return resp.read()
    except urllib.error.HTTPError as err:
        body = err.read()
        if body:
            return body
        return json.dumps({
            "jsonrpc": "2.0",
            "error": {"code": -32603, "message": f"HTTP {err.code}: {err.reason}"},
            "id": None,
        }).encode("utf-8")
    except Exception as exc:
        return json.dumps({
            "jsonrpc": "2.0",
            "error": {"code": -32603, "message": f"Bridge error: {str(exc)}"},
            "id": None,
        }).encode("utf-8")


def main() -> None:
    log(f"Starting Penguin Store stdio bridge -> {DEFAULT_URL}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req_data = line.encode("utf-8")
            resp_bytes = forward_request(DEFAULT_URL, req_data, API_KEY)
            sys.stdout.write(resp_bytes.decode("utf-8") + "\n")
            sys.stdout.flush()
        except Exception as exc:
            log(f"Unexpected bridge failure: {exc}")


if __name__ == "__main__":
    main()
